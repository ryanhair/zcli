//! Linux Secret Service backend for `zcli_secrets`, via the **`secret-tool`**
//! CLI (from `libsecret-tools`).
//!
//! Stores each secret through the freedesktop.org Secret Service — the same
//! daemon-encrypted keyring gnome-keyring / KWallet expose over D-Bus — keyed by
//! the attributes `(service = app_name, account = name)`. Unlike the original
//! backend, this *executes `secret-tool`* rather than linking `libsecret`, so a
//! zcli binary stays static and musl-clean (see ADR-0010). The value is
//! base64-encoded (see `subprocess.encodeValue`).
//!
//! Note on argument terminators: unlike the `pass` backend, the argv here take
//! no `--` terminator. The user-controlled `name` is passed as an attribute
//! *value* (`account <name>`), which follows a keyword token rather than sitting
//! in option position, and `secret-tool` is a GOption program whose subcommand
//! grammar (`store`/`lookup`/`clear` as the first arg) does not cleanly accept a
//! `--` before those keyword/value triples. The plugin boundary's leading-dash
//! rejection already prevents a `name` from being read as a flag, so no `--` is
//! needed — and none is added rather than one whose placement GOption may not
//! honour.

const std = @import("std");
const subprocess = @import("subprocess.zig");

const log = std.log.scoped(.zcli_secrets);

pub const Error = error{
    /// A `secret-tool` invocation failed for a reason other than "not found".
    SecretBackendFailure,
    /// The Secret Service itself is unreachable — no daemon owns
    /// `org.freedesktop.secrets` on the session bus (a minimal session that sets
    /// `DBUS_SESSION_BUS_ADDRESS` but runs no keyring). Distinct from
    /// `SecretBackendFailure` so the Linux dispatcher can fall through to `pass`
    /// instead of surfacing an opaque failure. This is NOT returned for an
    /// unlocked/denied keyring or any operation-level error — only for
    /// "there is no service here".
    ServiceUnavailable,
    /// The value is too large for the Secret Service backend. `secret-tool store`
    /// reads the secret from stdin into a fixed 8192-byte buffer and silently
    /// drops the overflow (it prints "password is too long" but still exits 0 and
    /// stores the truncated value), so anything whose base64 encoding exceeds that
    /// cap cannot be stored intact here. Callers should use the `pass` backend
    /// (`ZCLI_SECRETS_BACKEND=pass`) for large secrets. Maps to the shared
    /// `SecretTooLarge`, the same clean-failure contract Windows uses for its
    /// 2560-byte blob cap.
    SecretTooLarge,
};

/// The largest base64-encoded payload `secret-tool store` will read from stdin
/// intact. libsecret's `read_password_stdin()` (tool/secret-tool.c) allocates a
/// fixed `remaining = 8192` buffer and reads into it in a loop; once `remaining`
/// reaches 0 the next `read(0, at, 0)` returns 0 (read as EOF), so bytes past
/// 8192 are silently discarded. We base64 the secret before storing it, so this
/// is a limit on the *encoded* length, not the raw value: a raw value up to
/// `8192 * 3 / 4` = 6144 bytes encodes within the cap. This is an upper bound
/// used for a cheap pre-flight reject; the authoritative check is the
/// verify-after-store read-back in `set`, which catches truncation regardless of
/// where the exact boundary lands.
const max_encoded_len: usize = 8192;

/// True when `secret-tool`'s stderr indicates the *service* is unreachable
/// (D-Bus / keyring not present), as opposed to an operation-level failure like
/// a locked or access-denied collection. Conservative: it matches only the
/// connection/daemon-absent phrasings, so a real error (e.g. "prompt dismissed",
/// "locked") is NOT mistaken for "no service" and does not silently fall through
/// to a different store.
fn noServiceSignal(stderr: []const u8) bool {
    const needles = [_][]const u8{
        // libsecret / GLib when nothing owns org.freedesktop.secrets or the bus
        // can't be reached.
        "org.freedesktop.secrets",
        "was not provided by any .service files",
        "Cannot autolaunch D-Bus",
        "Failed to connect to the bus",
        "Failed to execute child process \"dbus-launch\"",
        "The name org.freedesktop.secrets was not provided",
    };
    for (needles) |needle| {
        if (std.mem.indexOf(u8, stderr, needle) != null) return true;
    }
    return false;
}

/// True when *every* non-blank line of `stderr` is a benign artifact of a
/// concurrent mutation of the same item — i.e. nothing here is a genuine Secret
/// Service operation error. Two kinds of line qualify:
///
///   1. **GLib assertion noise.** libsecret's async path can double-complete an
///      internal `GTask` when two operations touch the same item, so `secret-tool`
///      prints, e.g.
///
///          (secret-tool:5656): GLib-GIO-CRITICAL **: g_task_return_boolean:
///          assertion '!task->ever_returned' failed
///
///      and exits nonzero. That is a glibc-level warning, not a store error.
///
///   2. **"the item vanished" messages.** When a `clear`/`lookup` races a
///      concurrent `delete`, the item's D-Bus object is removed out from under the
///      call and `secret-tool` reports one of:
///
///          secret-tool: Object does not exist at path "/…/collection/login/134"
///          secret-tool: No such interface "org.freedesktop.Secret.Item" on object…
///
///      Both mean "the target is already gone" — exactly the no-op a `delete` is
///      documented to succeed at, and an "absent" for a `get`.
///
/// A caller whose operation is idempotent under concurrency (`delete`, `get`
/// treated as "absent", `set`'s store which then retries + verifies) must not read
/// these as `SecretBackendFailure`.
///
/// Deliberately strict: a *real* error line ("prompt dismissed", "locked", a
/// no-service phrasing, or anything not on this list) makes it return `false`, so
/// genuine failures are never swallowed. Empty stderr is not benign-race — callers
/// handle the quiet nonzero-exit case separately.
fn isBenignRace(stderr: []const u8) bool {
    var saw_line = false;
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |raw| {
        const line = trimmed(raw);
        if (line.len == 0) continue; // blank / trailing newline

        // (1) A GLib assertion warning: "(prog:pid): GLib…-CRITICAL **: …". Match on
        // "GLib" + severity marker rather than exact wording so a WARNING variant or
        // a reworded assertion is still recognized.
        const is_glib = std.mem.indexOf(u8, line, "GLib") != null and
            (std.mem.indexOf(u8, line, "CRITICAL") != null or
                std.mem.indexOf(u8, line, "WARNING") != null);
        // (2) The "item vanished mid-op" phrasings (quotes are non-ASCII in
        // secret-tool's output, so match on the stable ASCII substrings only).
        const is_vanished = std.mem.indexOf(u8, line, "Object does not exist at path") != null or
            (std.mem.indexOf(u8, line, "No such interface") != null and
                std.mem.indexOf(u8, line, "on object at path") != null);

        if (!is_glib and !is_vanished) return false; // a genuine message → not benign
        saw_line = true;
    }
    return saw_line;
}

/// Retrieve a secret. Returns `null` if no matching item exists. The returned
/// bytes are owned by `allocator`.
pub fn get(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    service: []const u8,
    name: []const u8,
) !?[]const u8 {
    var out = subprocess.run(allocator, io, environ, &.{
        "secret-tool", "lookup", "service", service, "account", name,
    }, null) catch |e| return mapError(e);
    defer out.deinit();

    if (out.ok()) {
        const encoded = std.mem.trimEnd(u8, out.stdout, "\r\n");
        return subprocess.decodeValue(allocator, encoded) catch |e| return mapError(e);
    }
    // `secret-tool lookup` exits nonzero both when the item is simply absent
    // (nothing on stderr) and when the service call itself fails (a message on
    // stderr). Treat the quiet case as "not found", the noisy case as an error.
    if (trimmed(out.stderr).len == 0) return null;
    if (noServiceSignal(out.stderr)) return Error.ServiceUnavailable;
    // A `lookup` racing a concurrent delete can exit nonzero with only benign-race
    // noise on stderr (GLib GTask warning and/or "item vanished mid-op"). The
    // item's presence is in flux, so the benign read is "absent" (null) rather than
    // an opaque backend failure — get is idempotent this way.
    if (isBenignRace(out.stderr)) return null;
    logStderr(out.stderr);
    return Error.SecretBackendFailure;
}

/// Store (or overwrite) a secret.
///
/// `secret-tool store` silently truncates a stdin secret past 8192 bytes (see
/// `max_encoded_len`), so this guards against that two ways: a cheap up-front
/// reject when the encoded length already exceeds the cap, and — the
/// authoritative check — a verify-after-store read-back that fails
/// `SecretTooLarge` if what came back differs from what we wrote. A truncated
/// entry is best-effort deleted so we never leave a corrupt value in the store.
pub fn set(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    service: []const u8,
    name: []const u8,
    value: []const u8,
) !void {
    const encoded = try subprocess.encodeValue(allocator, value);
    // `encoded` is base64 of the secret — wipe it before the allocator reclaims
    // the pages, not just free it.
    defer {
        std.crypto.secureZero(u8, encoded);
        allocator.free(encoded);
    }

    // Cheap pre-flight: anything past the fixed stdin buffer would be truncated,
    // so reject before spawning rather than store a value we know is corrupt.
    if (encoded.len > max_encoded_len) return Error.SecretTooLarge;

    const label = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ service, name });
    defer allocator.free(label);

    // `secret-tool store` reads the secret from stdin; we feed it the base64.
    // Under a concurrent mutation of the same key, libsecret can double-complete
    // an internal GTask and `store` exits nonzero printing only a GLib assertion
    // warning — a transient that clears once the racing op settles. Unlike
    // `get`/`delete` (idempotent no-ops), `set` must actually leave the value
    // stored, so a bare GLib-noise failure is *retried* rather than accepted: retry
    // re-issues the write after the contention window, and the authoritative
    // verify-after-store below still confirms the result. A non-GLib error is a
    // real failure and is surfaced immediately.
    const store_attempts = 2;
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        var out = subprocess.run(allocator, io, environ, &.{
            "secret-tool", "store", "--label", label, "service", service, "account", name,
        }, encoded) catch |e| return mapError(e);
        defer out.deinit();

        if (out.ok()) break;
        if (noServiceSignal(out.stderr)) return Error.ServiceUnavailable;
        if (isBenignRace(out.stderr) and attempt + 1 < store_attempts) continue;
        logStderr(out.stderr);
        return Error.SecretBackendFailure;
    }

    // Verify-after-store: read the value back and confirm it survived intact.
    // `secret-tool store` exits 0 even when it truncated the secret to the 8192
    // stdin cap, so a zero exit is not proof the store is correct — this read-back
    // is. Store operations are rare and user-triggered, so the extra roundtrip is
    // cheap insurance against a silent corrupt write.
    switch (try verifyStored(allocator, io, environ, service, name, value)) {
        // The read-back exactly matched — the store round-tripped intact.
        .intact => {},
        // The read-back found nothing. This is NOT truncation (truncation leaves a
        // present-but-shorter value): the item is simply gone. The only way `store`
        // can exit 0 and yet the value be absent a moment later is a concurrent
        // `delete` that landed between our write and our read-back — a legal
        // serialization of `set` then `delete`. The store itself succeeded, so this
        // is benign; treat it as success rather than misreporting `SecretTooLarge`.
        .missing => {},
        // The read-back returned a value that differs from what we wrote (or one
        // that no longer decodes) — the `secret-tool` stdin-truncation signature.
        // Best-effort remove the truncated entry so a later `get` can't hand back a
        // corrupt secret; ignore its outcome (the truncation is the real error).
        .mismatch => {
            delete(allocator, io, environ, service, name) catch {};
            return Error.SecretTooLarge;
        },
    }
}

/// The three distinguishable outcomes of the verify-after-store read-back. Kept
/// separate because they demand opposite handling: `.mismatch` is the truncation
/// bug and must fail the `set`, while `.missing` is a benign concurrent delete and
/// must NOT — conflating them (as an earlier `bool` did) turned a legal
/// set/delete race into a spurious `SecretTooLarge`.
const Verified = enum { intact, missing, mismatch };

/// Read the just-stored secret back and classify it against `want`. Split out so
/// the truncation-detection compare is unit-testable via `verifyAgainst`.
///
///   - `.intact`   — the read-back exactly equals `want`; the store round-tripped.
///   - `.missing`  — nothing came back (`get` returned `null`). Under concurrency
///                   this is a `delete` that landed between our store and our
///                   read-back — benign, NOT truncation.
///   - `.mismatch` — a value came back that differs from `want`. That is the
///                   `secret-tool` stdin-truncation signature the caller must fail.
///
/// A truncated base64 read-back often no longer decodes, so `get` can fail with
/// `SecretBackendFailure` on exactly the corrupt-store case we are checking for;
/// that counts as `.mismatch`, NOT a propagated error. Only a genuinely different
/// problem — the service going away between the store and the read-back — is
/// surfaced, so a real infra fault is never masked as "too large".
fn verifyStored(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    service: []const u8,
    name: []const u8,
    want: []const u8,
) !Verified {
    const maybe = get(allocator, io, environ, service, name) catch |e| switch (e) {
        Error.ServiceUnavailable => return e,
        // A corrupt/undecodable read-back is a value that came back but is not
        // `want` — the truncation signature, so `.mismatch` (never `.missing`,
        // which would be silently accepted as a benign delete).
        else => return .mismatch,
    };
    const got = maybe orelse return .missing;
    defer {
        // `got` holds the (decoded) secret read back from the store — wipe it
        // before the allocator reclaims the pages, not just free it. It is
        // allocator-owned and about to be discarded, so the const cast is sound.
        std.crypto.secureZero(u8, @constCast(got));
        allocator.free(got);
    }
    return if (verifyAgainst(got, want)) .intact else .mismatch;
}

/// The core truncation-detection compare, factored out so it can be unit-tested
/// without a live Secret Service. `true` iff the read-back exactly equals what we
/// asked to store.
fn verifyAgainst(got: []const u8, want: []const u8) bool {
    return std.mem.eql(u8, got, want);
}

/// Remove a secret. Succeeds (no-op) if no matching item exists.
pub fn delete(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    service: []const u8,
    name: []const u8,
) !void {
    // `secret-tool clear` exits 0 whether or not anything matched; only a
    // nonzero exit with a message on stderr is a real failure.
    var out = subprocess.run(allocator, io, environ, &.{
        "secret-tool", "clear", "service", service, "account", name,
    }, null) catch |e| return mapError(e);
    defer out.deinit();

    if (out.ok()) return;
    if (trimmed(out.stderr).len == 0) return;
    if (noServiceSignal(out.stderr)) return Error.ServiceUnavailable;
    // A `clear` racing a concurrent `clear`/`delete` of the same key can exit
    // nonzero with only benign-race stderr: a GLib GTask double-completion warning
    // and/or an "item vanished mid-op" message ("Object does not exist" / "No such
    // interface … on object at path") once the racing deleter removes the D-Bus
    // object first. `clear` is a documented no-op when nothing matches, so all of
    // those are benign — the delete's whole contract is idempotent-under-concurrency.
    if (isBenignRace(out.stderr)) return;
    logStderr(out.stderr);
    return Error.SecretBackendFailure;
}

fn trimmed(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn logStderr(stderr: []const u8) void {
    log.debug("secret-tool: {s}", .{trimmed(stderr)});
}

/// Collapse a launch failure (`secret-tool` uninstalled) or a corrupt-value
/// decode into a backend failure — but never swallow `OutOfMemory`.
fn mapError(e: anyerror) anyerror {
    return if (e == error.OutOfMemory) error.OutOfMemory else Error.SecretBackendFailure;
}

test "noServiceSignal distinguishes 'no service' from operation errors" {
    // No-service phrasings → fall through to pass is warranted.
    try std.testing.expect(noServiceSignal(
        "The name org.freedesktop.secrets was not provided by any .service files",
    ));
    try std.testing.expect(noServiceSignal("Cannot autolaunch D-Bus without X11 $DISPLAY"));
    try std.testing.expect(noServiceSignal("Failed to connect to the bus: ..."));

    // Real operation errors must NOT be treated as "no service" — falling
    // through to pass would hide a genuine problem.
    try std.testing.expect(!noServiceSignal("The prompt was dismissed."));
    try std.testing.expect(!noServiceSignal("Collection is locked."));
    try std.testing.expect(!noServiceSignal(""));
}

test "isBenignRace recognizes concurrent-mutation artifacts but not real errors" {
    // The exact libsecret GTask double-completion warning observed under a
    // concurrent set/delete race — pure noise, must be recognized.
    try std.testing.expect(isBenignRace(
        "(secret-tool:5656): GLib-GIO-CRITICAL **: 19:26:31.886: " ++
            "g_task_return_boolean: assertion '!task->ever_returned' failed",
    ));
    // A plain GLib-CRITICAL (no -GIO) and a WARNING variant are also just noise.
    try std.testing.expect(isBenignRace("(secret-tool:1): GLib-CRITICAL **: something"));
    try std.testing.expect(isBenignRace("(secret-tool:1): GLib-GObject-WARNING **: x"));

    // The "item vanished mid-op" messages a `clear`/`lookup` sees when a concurrent
    // delete removes the D-Bus object first — both benign (the target is gone).
    try std.testing.expect(isBenignRace(
        "secret-tool: Object does not exist at path \"/org/freedesktop/secrets/collection/login/134\"",
    ));
    try std.testing.expect(isBenignRace(
        "secret-tool: No such interface \"org.freedesktop.Secret.Item\" " ++
            "on object at path /org/freedesktop/secrets/collection/login/210",
    ));
    // The real observed combination: GLib warning line THEN a vanished-item line.
    try std.testing.expect(isBenignRace(
        "(secret-tool:1): GLib-GIO-CRITICAL **: assertion failed\n" ++
            "secret-tool: Object does not exist at path \"/x\"\n",
    ));

    // Empty stderr is NOT benign-race — the quiet nonzero-exit case is handled apart.
    try std.testing.expect(!isBenignRace(""));
    try std.testing.expect(!isBenignRace("   \n\n"));
    // A genuine operation error must never be mistaken for benign — even alongside
    // a GLib warning line, the real message wins and the op must still fail.
    try std.testing.expect(!isBenignRace("The prompt was dismissed."));
    try std.testing.expect(!isBenignRace("Collection is locked."));
    try std.testing.expect(!isBenignRace(
        "(secret-tool:1): GLib-GIO-CRITICAL **: noise\nThe prompt was dismissed.",
    ));
    // "No such interface" WITHOUT the object-path tail is not the vanished signature.
    try std.testing.expect(!isBenignRace("secret-tool: No such interface bar"));
}

test "verifyAgainst detects a truncated read-back" {
    // Exact match — the store round-tripped intact.
    try std.testing.expect(verifyAgainst("hello", "hello"));
    try std.testing.expect(verifyAgainst("", ""));

    // A prefix is exactly what `secret-tool`'s 8192-byte truncation produces:
    // the first N bytes match, the tail is missing → must be rejected.
    try std.testing.expect(!verifyAgainst("hell", "hello"));
    // Any mismatch, including a longer read-back, is a failure.
    try std.testing.expect(!verifyAgainst("hello!", "hello"));
    try std.testing.expect(!verifyAgainst("", "hello"));
}

test "max_encoded_len matches secret-tool's fixed stdin buffer" {
    // Guards against a silent drift of the documented cap; 8192 is libsecret's
    // `read_password_stdin` buffer size (tool/secret-tool.c).
    try std.testing.expectEqual(@as(usize, 8192), max_encoded_len);

    // The encoded-length pre-flight rejects a raw value whose base64 exceeds the
    // cap, and accepts one that fits. base64 encodes 3 raw bytes to 4, so the
    // largest raw value that fits is 8192 * 3 / 4 = 6144 bytes.
    const b64 = std.base64.standard;
    try std.testing.expect(b64.Encoder.calcSize(6144) <= max_encoded_len);
    try std.testing.expect(b64.Encoder.calcSize(6145) > max_encoded_len);
}
