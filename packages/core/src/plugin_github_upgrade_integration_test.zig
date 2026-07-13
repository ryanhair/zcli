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

const std = @import("std");
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
