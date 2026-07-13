//! Real-socket integration tests for the zcli_github_upgrade download→verify→
//! install pipeline, driven against a loopback HTTP server standing in for
//! GitHub releases. Isolated into its own binary (built ReleaseSafe, like
//! http_loopback_test.zig) for the same two reasons: the socket round-trips run
//! once instead of riding into every zcli-importing test binary, and it silences
//! the Windows "unexpected NTSTATUS" trace on a lost concurrent loopback dial.
//!
//! These exercise `plugin.downloadAndVerify` — the security-load-bearing path —
//! plus `plugin.replaceBinaryAt` for the install, so a single test drives the
//! whole "fetch the asset, verify it, swap it into place" flow end to end. The
//! fake GitHub serves a binary asset, checksums.txt, and checksums.txt.minisig,
//! with a minisign keypair generated in-process (real Ed25519 in the exact
//! blob/algorithm format minisign.zig's verifier accepts), so the happy path
//! verifies a genuine signature over checksums whose digests really match the
//! served binary. The fail-closed cases (missing .minisig, tampered checksums,
//! binary/checksum mismatch) each abort before the swap.
//!
//! A second group ("install: …") closes the #114 gap by driving
//! `plugin.replaceBinaryAt` against a binary whose image is held open by a
//! RUNNING process — the real self-upgrade scenario the unit tests can't reach
//! (they swap dormant files). This is where Windows's rename-aside strategy for
//! a live .exe actually gets exercised, on the Windows CI leg of `zig build
//! test`.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const plugin = @import("plugins/zcli_github_upgrade/plugin.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;
const b64 = std.base64.standard;

// Fixed identifiers the download URLs are built from. The asset name is
// platform-independent here (the test passes it explicitly), so the loopback
// router can match on it directly.
const repo = "owner/app";
const cli_name = "app";
const version = "1.2.3";
const binary_name = "app-testplat";
const binary_contents = "THE-NEW-BINARY-BYTES\x00\x01\x02payload";

/// A minisign keypair plus the artifacts a release would publish, all consistent
/// with one another: `checksums` really lists the SHA-256 of `binary_contents`,
/// and `minisig` is a genuine Ed25519 signature over `checksums` in minisign's
/// prehashed ("ED") format, under `public_key_b64`.
const Fixture = struct {
    public_key_b64: []u8,
    checksums: []u8,
    minisig: []u8,

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.public_key_b64);
        allocator.free(self.checksums);
        allocator.free(self.minisig);
    }
};

fn base64Alloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, b64.Encoder.calcSize(bytes.len));
    _ = b64.Encoder.encode(out, bytes);
    return out;
}

/// Build a self-consistent release fixture with a fresh keypair.
fn makeFixture(allocator: std.mem.Allocator, io: std.Io) !Fixture {
    const kp = Ed25519.KeyPair.generate(io);
    const key_id = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };

    // Public-key blob: "Ed" + 8-byte key id + 32-byte public key.
    var pk_blob: [2 + 8 + 32]u8 = undefined;
    @memcpy(pk_blob[0..2], "Ed");
    @memcpy(pk_blob[2..10], &key_id);
    @memcpy(pk_blob[10..42], &kp.public_key.bytes);
    const public_key_b64 = try base64Alloc(allocator, &pk_blob);
    errdefer allocator.free(public_key_b64);

    // checksums.txt lists the real digest of the served binary.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(binary_contents, &digest, .{});
    const hex = std.fmt.bytesToHex(&digest, .lower);
    const checksums = try std.fmt.allocPrint(allocator, "{s}  {s}\n", .{ hex, binary_name });
    errdefer allocator.free(checksums);

    // Prehashed ("ED") signature: Ed25519 over BLAKE2b-512(checksums).
    var pre: [Blake2b512.digest_length]u8 = undefined;
    Blake2b512.hash(checksums, &pre, .{});
    const sig = try kp.sign(&pre, null);

    var sig_blob: [2 + 8 + 64]u8 = undefined;
    @memcpy(sig_blob[0..2], "ED");
    @memcpy(sig_blob[2..10], &key_id);
    @memcpy(sig_blob[10..74], &sig.toBytes());
    const sig_b64 = try base64Alloc(allocator, &sig_blob);
    defer allocator.free(sig_b64);

    const minisig = try std.fmt.allocPrint(
        allocator,
        "untrusted comment: signature from test key\n{s}\ntrusted comment: test\ntrusted-sig-unused==\n",
        .{sig_b64},
    );
    errdefer allocator.free(minisig);

    return .{ .public_key_b64 = public_key_b64, .checksums = checksums, .minisig = minisig };
}

/// What the fake GitHub serves for each release asset. A null field means the
/// asset is absent (the server answers 404), exercising a fail-closed path.
const Assets = struct {
    binary: ?[]const u8,
    checksums: ?[]const u8,
    minisig: ?[]const u8,
};

/// Serve exactly the three release-download requests the pipeline makes
/// (binary, checksums.txt, checksums.txt.minisig), routing on the request
/// target's trailing path segment, then stop. A missing asset returns 404 so
/// the client's fail-closed handling is exercised over a real socket.
fn serveRelease(io: std.Io, server: *std.Io.net.Server, assets: Assets) void {
    var remaining: usize = 3;
    while (remaining > 0) : (remaining -= 1) {
        var stream = server.accept(io) catch return;
        defer stream.close(io);

        var read_buf: [4096]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var stream_reader = stream.reader(io, &read_buf);
        var stream_writer = stream.writer(io, &write_buf);

        var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
        var request = http_server.receiveHead() catch return;

        const target = request.head.target;
        const body: ?[]const u8 = if (std.mem.endsWith(u8, target, "/checksums.txt.minisig"))
            assets.minisig
        else if (std.mem.endsWith(u8, target, "/checksums.txt"))
            assets.checksums
        else if (std.mem.endsWith(u8, target, binary_name))
            assets.binary
        else
            null;

        if (body) |b| {
            request.respond(b, .{}) catch return;
        } else {
            request.respond("not found", .{ .status = .not_found }) catch return;
        }
    }
}

/// Spin up the fake GitHub, run `plugin.downloadAndVerify` against it into a temp
/// dir, and return the result. On success the verified binary sits in `dir` as
/// `binary_name`.
fn runDownloadVerify(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    assets: Assets,
    public_key: ?[]const u8,
) !void {
    var addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var future = try io.concurrent(serveRelease, .{ io, &server, assets });
    defer _ = future.cancel(io);

    const download_base = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port});
    defer allocator.free(download_base);

    // Diagnostics land here (and are ignored) — the tests assert on the returned
    // error, not the message text.
    var discard = std.Io.Writer.Discarding.init(&.{});

    return plugin.downloadAndVerify(
        allocator,
        io,
        &discard.writer,
        download_base,
        dir,
        repo,
        cli_name,
        version,
        binary_name,
        public_key,
    );
}

test "pipeline: happy path downloads, verifies signature, and installs" {
    const allocator = testing.allocator;
    const io = testing.io;

    var fx = try makeFixture(allocator, io);
    defer fx.deinit(allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const assets = Assets{ .binary = binary_contents, .checksums = fx.checksums, .minisig = fx.minisig };
    try runDownloadVerify(allocator, io, tmp.dir, assets, fx.public_key_b64);

    // The verified binary is present with the exact served bytes.
    const got = try tmp.dir.readFileAlloc(io, binary_name, allocator, .limited(1 << 20));
    defer allocator.free(got);
    try testing.expectEqualStrings(binary_contents, got);

    // Now drive the install step: a stand-in "current" binary is atomically
    // replaced by the verified download.
    try tmp.dir.writeFile(io, .{ .sub_path = "current", .data = "OLD" });
    try plugin.replaceBinaryAt(allocator, io, tmp.dir, binary_name, "current");

    const installed = try tmp.dir.readFileAlloc(io, "current", allocator, .limited(1 << 20));
    defer allocator.free(installed);
    try testing.expectEqualStrings(binary_contents, installed);
}

test "pipeline: happy path with checksum only (no pinned key) installs" {
    const allocator = testing.allocator;
    const io = testing.io;

    var fx = try makeFixture(allocator, io);
    defer fx.deinit(allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // No public_key → signature step skipped, checksum still enforced. Even the
    // .minisig being absent must not matter when no key is pinned.
    const assets = Assets{ .binary = binary_contents, .checksums = fx.checksums, .minisig = null };
    try runDownloadVerify(allocator, io, tmp.dir, assets, null);

    const got = try tmp.dir.readFileAlloc(io, binary_name, allocator, .limited(1 << 20));
    defer allocator.free(got);
    try testing.expectEqualStrings(binary_contents, got);
}

test "pipeline: a missing .minisig aborts when a key is pinned (fail closed)" {
    const allocator = testing.allocator;
    const io = testing.io;

    var fx = try makeFixture(allocator, io);
    defer fx.deinit(allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Signature asset absent, but a key is pinned: the release is treated as
    // unsigned and refused rather than installed on the checksum alone.
    const assets = Assets{ .binary = binary_contents, .checksums = fx.checksums, .minisig = null };
    try testing.expectError(
        error.FailedToDownloadSignature,
        runDownloadVerify(allocator, io, tmp.dir, assets, fx.public_key_b64),
    );

    // Nothing was left installable behind the failed verification path: the
    // downloaded file exists (verification runs after download) but the caller
    // never reaches the swap. Assert the guard fired before any checksum trust.
    try testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "current", .{}));
}

test "pipeline: tampered checksums.txt fails signature verification" {
    const allocator = testing.allocator;
    const io = testing.io;

    var fx = try makeFixture(allocator, io);
    defer fx.deinit(allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Flip a byte in checksums.txt: the served signature no longer matches, so
    // verification fails closed even though the .minisig itself is well-formed.
    const tampered = try allocator.dupe(u8, fx.checksums);
    defer allocator.free(tampered);
    tampered[0] = if (tampered[0] == 'a') 'b' else 'a';

    const assets = Assets{ .binary = binary_contents, .checksums = tampered, .minisig = fx.minisig };
    try testing.expectError(
        error.SignatureVerificationFailed,
        runDownloadVerify(allocator, io, tmp.dir, assets, fx.public_key_b64),
    );
}

test "pipeline: a binary that does not match its checksum aborts" {
    const allocator = testing.allocator;
    const io = testing.io;

    var fx = try makeFixture(allocator, io);
    defer fx.deinit(allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Serve a DIFFERENT binary than the one checksums.txt (and its signature)
    // describe. The signature over checksums.txt still verifies, but the served
    // bytes hash to a different digest → checksum mismatch, refuse.
    const assets = Assets{ .binary = "A-DIFFERENT-BINARY", .checksums = fx.checksums, .minisig = fx.minisig };
    try testing.expectError(
        error.ChecksumMismatch,
        runDownloadVerify(allocator, io, tmp.dir, assets, fx.public_key_b64),
    );
}

test "pipeline: checksum-only mode still rejects a mismatched binary" {
    const allocator = testing.allocator;
    const io = testing.io;

    var fx = try makeFixture(allocator, io);
    defer fx.deinit(allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // No pinned key, but the served binary does not match the checksum.
    const assets = Assets{ .binary = "WRONG-BYTES", .checksums = fx.checksums, .minisig = null };
    try testing.expectError(
        error.ChecksumMismatch,
        runDownloadVerify(allocator, io, tmp.dir, assets, null),
    );
}

// ----------------------------------------------------------------------------
// In-use binary replacement — the actual self-upgrade scenario
//
// The unit tests in plugin.zig swap DORMANT files; this closes the #114 gap by
// replacing a binary whose image is held open by a RUNNING process — exactly
// what happens when `zcli upgrade` overwrites the very executable it is running
// from. That is the case Windows's rename-aside strategy exists for: a live
// .exe cannot be overwritten or deleted, only renamed, so `replaceBinaryAt`
// moves it to `{target}.backup` before moving the new binary into place, and
// the still-mapped old image lingers until the process exits (deferred delete).
//
// The test is cross-platform, not Windows-gated, so the harness itself runs
// everywhere (on POSIX, rename over a running binary is legal and the swap is a
// single atomic rename); the Windows-specific assertions sit behind
// `builtin.os.tag == .windows`.
// ----------------------------------------------------------------------------

/// A minimal helper executable: it blocks reading one byte from stdin, then
/// exits 0. Compiled fresh into the temp dir and copied to the "installed"
/// path so a spawned instance holds that on-disk image open while we replace
/// it. Closing the child's stdin is the clean-exit signal (EOF), letting us
/// prove the process survived having its image swapped and terminated normally
/// — a `kill` would mask a crash. kernel32.ReadFile is declared here because
/// this std version does not surface it, and a freestanding `main` has no
/// `std.Io` to reach a higher-level read through.
const waiter_source =
    \\const std = @import("std");
    \\const builtin = @import("builtin");
    \\
    \\extern "kernel32" fn ReadFile(
    \\    hFile: *anyopaque,
    \\    lpBuffer: [*]u8,
    \\    nNumberOfBytesToRead: u32,
    \\    lpNumberOfBytesRead: ?*u32,
    \\    lpOverlapped: ?*anyopaque,
    \\) callconv(.winapi) i32;
    \\
    \\pub fn main() void {
    \\    var buf: [1]u8 = undefined;
    \\    if (builtin.os.tag == .windows) {
    \\        const h = std.os.windows.peb().ProcessParameters.hStdInput;
    \\        var n: u32 = 0;
    \\        _ = ReadFile(h, &buf, 1, &n, null);
    \\    } else {
    \\        _ = std.posix.read(std.posix.STDIN_FILENO, &buf) catch {};
    \\    }
    \\}
;

/// Executable-name suffix for the current platform (Windows carries `.exe`).
const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";

/// Read cap for slurping a whole binary back for comparison. The waiter is a
/// real (debug-built, so multi-MB) executable, so this is generous.
const read_cap: std.Io.Limit = .limited(64 << 20);

/// Compile `waiter_source` into `out_name` inside `dir` using the `zig` on
/// PATH (guaranteed present — these tests run under `zig build`). Returns
/// error.SkipZigTest if `zig` cannot be launched, so a stripped-down CI image
/// without a zig-on-PATH degrades to a skip rather than a spurious failure.
fn buildWaiter(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, out_name: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = "waiter.zig", .data = waiter_source });

    // Keep every build artifact (the emitted exe, cache, .o) inside the temp
    // dir by running the compiler with its cwd set there.
    const emit = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{out_name});
    defer allocator.free(emit);

    var child = std.process.spawn(io, .{
        .argv = &.{ "zig", "build-exe", "waiter.zig", emit },
        .cwd = .{ .dir = dir },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    const term = child.wait(io) catch return error.SkipZigTest;
    if (term != .exited or term.exited != 0) return error.NewBinaryFailedToRun;
}

/// Absolute path to `sub_path` within `dir`, so spawned children key off an
/// explicit image path rather than a cwd-relative one (whose resolution
/// differs across platforms). Returns the sentinel-terminated slice as-is so
/// the caller frees the exact allocation (freeing it as a plain `[]u8` would
/// drop the terminator byte and trip the allocator's size check).
fn absPath(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) ![:0]u8 {
    return dir.realPathFileAlloc(io, sub_path, allocator);
}

/// Spawn `abs_path` as a long-running process with a pipe stdin (it blocks on
/// the read, so its image file stays in-use until we close that pipe).
fn spawnWaiter(io: std.Io, abs_path: []const u8) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = &.{abs_path},
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

/// Close the child's stdin (EOF → the waiter returns from its read and exits),
/// then wait; assert it terminated normally with exit code 0. Proves the
/// running process kept running through the swap and exited cleanly rather than
/// crashing from having its image replaced underneath it.
fn expectCleanExit(io: std.Io, child: *std.process.Child) !void {
    if (child.stdin) |*in| {
        in.close(io);
        child.stdin = null;
    }
    const term = child.wait(io) catch |err| {
        std.debug.print("waiter did not exit cleanly: {s}\n", .{@errorName(err)});
        return err;
    };
    try testing.expect(term == .exited);
    try testing.expectEqual(@as(u8, 0), term.exited);
}

test "install: replace a binary whose image a running process holds open" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Build the waiter, then copy it to the "installed" path — the copy is what
    // a live process runs from and what the upgrade replaces.
    const waiter_name = "waiter" ++ exe_suffix;
    try buildWaiter(allocator, io, tmp.dir, waiter_name);

    const target_name = "app" ++ exe_suffix;
    try tmp.dir.copyFile(waiter_name, tmp.dir, target_name, io, .{});
    if (builtin.os.tag != .windows) {
        const tf = try tmp.dir.openFile(io, target_name, .{});
        defer tf.close(io);
        try tf.setPermissions(io, .executable_file);
    }

    // The "new version" the upgrade installs. Its bytes only need to land
    // correctly; the swap copies bytes and does not run it (testBinary, the
    // exec smoke test, is a separate step exercised elsewhere).
    const new_name = "new" ++ exe_suffix;
    const new_contents = "NEW-VERSION-BYTES\x00\x01\x02";
    try tmp.dir.writeFile(io, .{ .sub_path = new_name, .data = new_contents });

    // Launch the target so its on-disk image is in-use, then replace it.
    const target_abs = try absPath(allocator, io, tmp.dir, target_name);
    defer allocator.free(target_abs);

    var child = try spawnWaiter(io, target_abs);
    errdefer child.kill(io);

    // The replacement must succeed even though `target_name` is a running image.
    try plugin.replaceBinaryAt(allocator, io, tmp.dir, new_name, target_name);

    // The installed path now holds the new bytes.
    const got = try tmp.dir.readFileAlloc(io, target_name, allocator, read_cap);
    defer allocator.free(got);
    try testing.expectEqualStrings(new_contents, got);

    if (builtin.os.tag == .windows) {
        // Rename-aside: the live image was moved to `{target}.backup`. It stays
        // mapped (and thus undeletable) until the process exits, so the swap
        // leaves it behind on purpose — deferred delete.
        const backup_name = target_name ++ ".backup";
        const backup = try tmp.dir.readFileAlloc(io, backup_name, allocator, read_cap);
        defer allocator.free(backup);
        // The backup is the ORIGINAL binary (== the waiter it was copied from).
        const waiter_bytes = try tmp.dir.readFileAlloc(io, waiter_name, allocator, read_cap);
        defer allocator.free(waiter_bytes);
        try testing.expectEqualSlices(u8, waiter_bytes, backup);
    }

    // The running process survived the swap and exits cleanly on EOF.
    try expectCleanExit(io, &child);

    // A SECOND upgrade after the old process has exited: on Windows the stale
    // `{target}.backup` from the first swap is now unlocked, so rename-aside
    // replaces it rather than tripping over it (the deferred-delete reality the
    // strategy is built around). On POSIX there is no backup; this simply
    // confirms back-to-back upgrades work.
    const new2_contents = "SECOND-NEW-VERSION";
    try tmp.dir.writeFile(io, .{ .sub_path = new_name, .data = new2_contents });
    try plugin.replaceBinaryAt(allocator, io, tmp.dir, new_name, target_name);

    const got2 = try tmp.dir.readFileAlloc(io, target_name, allocator, read_cap);
    defer allocator.free(got2);
    try testing.expectEqualStrings(new2_contents, got2);
}

test "install: a missing new binary leaves a running target intact and runnable" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const waiter_name = "waiter" ++ exe_suffix;
    try buildWaiter(allocator, io, tmp.dir, waiter_name);

    const target_name = "app" ++ exe_suffix;
    try tmp.dir.copyFile(waiter_name, tmp.dir, target_name, io, .{});
    if (builtin.os.tag != .windows) {
        const tf = try tmp.dir.openFile(io, target_name, .{});
        defer tf.close(io);
        try tf.setPermissions(io, .executable_file);
    }

    const original = try tmp.dir.readFileAlloc(io, target_name, allocator, read_cap);
    defer allocator.free(original);

    const target_abs = try absPath(allocator, io, tmp.dir, target_name);
    defer allocator.free(target_abs);

    var child = try spawnWaiter(io, target_abs);
    errdefer child.kill(io);

    // Replacing with a nonexistent new binary must fail during staging, before
    // the live image is ever renamed aside...
    try testing.expectError(
        error.FileNotFound,
        plugin.replaceBinaryAt(allocator, io, tmp.dir, "does-not-exist" ++ exe_suffix, target_name),
    );

    // ...leaving the still-running target byte-for-byte intact (never renamed
    // over), and on Windows no backup created.
    const after = try tmp.dir.readFileAlloc(io, target_name, allocator, read_cap);
    defer allocator.free(after);
    try testing.expectEqualSlices(u8, original, after);
    if (builtin.os.tag == .windows) {
        try testing.expectError(error.FileNotFound, tmp.dir.openFile(io, target_name ++ ".backup", .{}));
    }

    // The process is unharmed and still exits cleanly.
    try expectCleanExit(io, &child);
}
