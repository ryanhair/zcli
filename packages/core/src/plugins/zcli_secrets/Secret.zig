//! A retrieved credential, scoped so its plaintext is **wiped** on release
//! rather than merely freed.
//!
//! Every backend in this package is meticulous about not leaving decrypted bytes
//! behind: `subprocess.zig` zeroes its stdin buffer, its drain buffer and both
//! error paths; `credential_manager_windows.zig` zeroes the OS-heap plaintext
//! before `CredFree`; `linux_secret_service.zig` zeroes its verify-read-back. The
//! one hop that used to escape that discipline was the last one — the value
//! handed to the command author. `get` returned a bare `[]const u8` owned by the
//! per-command arena, and an arena is *released*, not scrubbed, so a decrypted
//! token stayed legible in reclaimable pages for the rest of the process.
//!
//! Returning this wrapper instead makes the wipe the obvious thing to write:
//!
//! ```zig
//! var token = (try context.plugins.zcli_secrets.get("token")) orelse
//!     return context.fail("not logged in", .{});
//! defer token.deinit();
//! // ... use token.bytes ...
//! ```
//!
//! `deinit` takes a `*Secret`, so the value has to be bound to a `var` — the
//! type makes its own scope visible instead of relying on a doc comment nobody
//! reads. Note the scrub is the point and the free is incidental: under the
//! per-command arena `free` is very nearly a no-op, but the `secureZero` still
//! clears the bytes before those pages are reused.
//!
//! Worth knowing which build mode this actually buys you something in. In Debug
//! and ReleaseSafe, `std.mem.Allocator.free` already `@memset`s the released
//! bytes to `undefined` (0xAA), so the plaintext is destroyed either way. In
//! **ReleaseFast and ReleaseSmall — how a CLI ships — that memset compiles away
//! to nothing**, and `secureZero`'s volatile writes are the only thing standing
//! between a decrypted token and whatever reuses the page. That asymmetry is
//! also why the wipe is tested through the private `wipe` step rather than
//! through `deinit`: after the free the two cases are indistinguishable.
//!
//! ## The wipe covers this buffer and nothing else
//!
//! `bytes` is a plain public slice, so the scrub is scoped to the one allocation
//! this type owns. **Every copy you make escapes it.** An `allocator.dupe` of
//! `bytes`, an `Authorization` header built with `allocPrint`, a JSON request
//! body, the buffer of a `Writer` you printed it through, a struct field you
//! stashed it in — each is a second plaintext copy `deinit` knows nothing about
//! and will never touch. If a copy outlives its use, scrub it yourself:
//!
//! ```zig
//! const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{token.bytes});
//! defer std.crypto.secureZero(u8, auth);
//! ```
//!
//! That limit is deliberate, not a gap left to close. No type can follow bytes a
//! caller copies out, and pretending otherwise — an opaque handle, an accessor
//! handing out a temporary view — would buy the *appearance* of a guarantee that
//! the first `{s}` in a format string still defeats. What this type does
//! guarantee is that the copy *it* handed you is not the one left legible.

const Secret = @This();

const std = @import("std");

/// The decrypted credential. Valid until `deinit`.
bytes: []const u8,

/// The allocator `bytes` came from — the per-command arena in framework use.
allocator: std.mem.Allocator,

/// Zero the plaintext in place, without releasing it.
///
/// Split out of `deinit` because it is the security-critical half and it is the
/// half that cannot be observed through `deinit`: `std.mem.Allocator.free`
/// does `@memset(bytes, undefined)` before dispatching to the allocator
/// (`std/mem/Allocator.zig:448`), so in a safe build the zeros written here are
/// immediately painted over with `undefined`'s 0xAA fill. After `deinit` a
/// working wipe and a missing one are byte-for-byte identical, and only a test
/// that looks *before* the free can tell them apart.
///
/// `secureZero` writes through a `[]volatile u8`, so the compiler cannot elide
/// it as a dead store to about-to-be-freed memory — which is what makes it
/// load-bearing in ReleaseFast/ReleaseSmall, where the allocator's own
/// `undefined` memset compiles away to nothing and this is the *only* thing
/// that clears the plaintext. `bytes` is allocator-owned and being discarded,
/// so the const cast is sound.
fn wipe(self: Secret) void {
    std.crypto.secureZero(u8, @constCast(self.bytes));
}

/// Wipe the plaintext, then release it.
///
/// Self is invalidated afterwards (`undefined`), so a use-after-`deinit` trips
/// in a safe build instead of quietly reading a stale slice.
pub fn deinit(self: *Secret) void {
    self.wipe();
    self.allocator.free(self.bytes);
    self.* = undefined;
}

test "the wipe zeroes the plaintext, and only the plaintext" {
    // This is the assertion that pins `secureZero`: it fails if the call is
    // removed, or if the wipe is ever sized by anything but the slice. It has to
    // observe *before* the free — see `wipe`'s doc comment for why after is
    // indistinguishable.
    //
    // A FixedBufferAllocator hands out its backing store front-to-back with no
    // padding for a u8 allocation, and does not scribble on free, so the array is
    // a direct window onto the secret's bytes.
    var backing = [_]u8{0xAA} ** 16;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    const a = fba.allocator();

    const secret: Secret = .{ .bytes = try a.dupe(u8, "hunter2"), .allocator = a };
    // Load-bearing: establishes that the plaintext really is at offset 0, so the
    // assertions below are reading the bytes they think they are.
    try std.testing.expectEqualStrings("hunter2", backing[0..7]);

    secret.wipe();

    const zeroed = [_]u8{0} ** 7;
    try std.testing.expectEqualSlices(u8, &zeroed, backing[0..7]);
    // The tail is the over-run guard: a wipe that rounded up, or used a fixed
    // length, would have taken these sentinels with it.
    const untouched = [_]u8{0xAA} ** 9;
    try std.testing.expectEqualSlices(u8, &untouched, backing[7..]);
}

test "deinit destroys the plaintext and releases the allocation" {
    var backing = [_]u8{0xAA} ** 16;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    const a = fba.allocator();

    var secret: Secret = .{ .bytes = try a.dupe(u8, "hunter2"), .allocator = a };
    try std.testing.expectEqualStrings("hunter2", backing[0..7]);
    try std.testing.expectEqual(@as(usize, 7), fba.end_index);

    secret.deinit();

    // Deliberately NOT an assertion that these bytes are zero, and it must not be
    // "strengthened" into one: `Allocator.free` memsets the released bytes to
    // `undefined` on the way out, so in a safe build they read 0xAA whether or not
    // the wipe ran. (An earlier version of this test asserted zeros and CI failed
    // it on both Linux and macOS — with the wipe present and working.) What is
    // assertable here is the property that matters to a caller: the plaintext is
    // gone. The wipe itself is pinned by the test above.
    try std.testing.expect(std.mem.indexOf(u8, &backing, "hunter2") == null);

    // And the release really happened — the wipe did not quietly replace the free.
    try std.testing.expectEqual(@as(usize, 0), fba.end_index);
}

test "an empty secret wipes and releases without touching anything" {
    // A zero-length secret is a real stored value, distinct from "key absent".
    // Both steps must be sized by the slice: a fixed-length wipe would clobber
    // memory the allocator is free to hand out next.
    //
    // Note this says nothing about a *non-empty* wipe — `Allocator.free`
    // early-returns for a zero-length slice, so neither the wipe nor the free
    // writes anything here. It is an out-of-bounds check, not a wipe check.
    var backing = [_]u8{0xAA} ** 8;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    const a = fba.allocator();

    var secret: Secret = .{ .bytes = try a.dupe(u8, ""), .allocator = a };
    try std.testing.expectEqual(@as(usize, 0), secret.bytes.len);
    secret.deinit();

    const untouched = [_]u8{0xAA} ** 8;
    try std.testing.expectEqualSlices(u8, &untouched, &backing);
}
