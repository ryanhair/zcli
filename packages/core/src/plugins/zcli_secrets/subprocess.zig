//! Shared subprocess runner for the Linux `zcli_secrets` backends.
//!
//! Both Linux stores are reached by *executing a helper binary* (`secret-tool`
//! or `pass`) rather than linking a library — that is what keeps a zcli binary
//! static and musl-clean (see `docs/adr/0010-linux-secrets-shell-out-and-pass.md`).
//! This wraps the shape both backends need: spawn a command, optionally feed it
//! the secret on stdin, capture stdout/stderr, and wait.
//!
//! The child inherits `environ` — threaded from the context, never read via C
//! `getenv` — so `secret-tool` / `pass` / `gpg` see `HOME`,
//! `DBUS_SESSION_BUS_ADDRESS`, `GNUPGHOME`, `PASSWORD_STORE_DIR`, `GPG_TTY`, and
//! the rest of the ambient environment they rely on.

const std = @import("std");

pub const Output = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Output) void {
        // stdout can hold decrypted secret material (a `pass show` / `secret-tool
        // lookup` reads the stored value back on stdout), so wipe it before the
        // allocator reclaims the pages. stderr is diagnostic text, but wiping it
        // too is cheap and avoids depending on that always being true.
        std.crypto.secureZero(u8, self.stdout);
        std.crypto.secureZero(u8, self.stderr);
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }

    /// The child ran to completion with a zero exit code.
    pub fn ok(self: Output) bool {
        return self.term == .exited and self.term.exited == 0;
    }
};

pub const Error = error{
    /// The helper binary could not be executed at all — typically it is not
    /// installed / not on `PATH`. Deliberately distinct from "the command ran
    /// and exited nonzero", which surfaces as a non-`ok` `Output`.
    SpawnFailed,
};

/// A single output stream to drain, plus where the drained bytes land. Passed to
/// `drain` (run concurrently) so stdout and stderr are read *while* stdin is
/// written — otherwise a large secret whose stdin write exceeds the OS pipe
/// buffer would deadlock: parent blocked in `writeAll`, child blocked writing an
/// undrained stdout.
const Drainer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    /// Result slot. Set to the captured bytes on success, left `null` on error.
    out: *?[]u8,
    err: *?anyerror,
};

/// Read `d.file` to EOF into an allocation, storing the result (or the failure)
/// through the drainer's slots. Runs as a concurrent task so the read overlaps
/// the stdin write.
fn drain(d: Drainer) void {
    var buf: [4096]u8 = undefined;
    var reader = d.file.reader(d.io, &buf);
    if (reader.interface.allocRemaining(d.allocator, .limited(1 << 20))) |bytes| {
        d.out.* = bytes;
    } else |e| {
        d.err.* = e;
    }
}

/// Run `argv`, optionally writing `stdin_bytes` (then EOF) to the child's
/// stdin, and capture stdout+stderr. The caller owns the returned `Output`
/// (call `deinit`).
///
/// stdout and stderr are drained *concurrently* with the stdin write, so a
/// payload larger than the OS pipe buffer (~64 KiB) cannot deadlock the parent
/// against the child.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    argv: []const []const u8,
    stdin_bytes: ?[]const u8,
) !Output {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = if (stdin_bytes != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = environ,
    }) catch return Error.SpawnFailed;

    // Kick off the two readers before touching stdin, so the child can never
    // block on a full stdout/stderr pipe while we are still feeding stdin.
    var out_bytes: ?[]u8 = null;
    var out_err: ?anyerror = null;
    var out_future = try io.concurrent(drain, .{Drainer{
        .allocator = allocator,
        .io = io,
        .file = child.stdout.?,
        .out = &out_bytes,
        .err = &out_err,
    }});

    var err_bytes: ?[]u8 = null;
    var err_err: ?anyerror = null;
    var err_future = try io.concurrent(drain, .{Drainer{
        .allocator = allocator,
        .io = io,
        .file = child.stderr.?,
        .out = &err_bytes,
        .err = &err_err,
    }});

    if (stdin_bytes) |bytes| {
        var in_buf: [4096]u8 = undefined;
        var in = child.stdin.?.writer(io, &in_buf);
        // A write failure here just means the child closed stdin early; the exit
        // status read below is the authoritative signal, so it is ignored.
        in.interface.writeAll(bytes) catch {};
        in.interface.flush() catch {};
        child.stdin.?.close(io);
        child.stdin = null;
    }

    // Join both readers before reaping the child (they hold the pipe read ends).
    out_future.await(io);
    err_future.await(io);

    // If either drainer failed, wait for the child (avoid a zombie) and surface
    // the error after freeing whatever the other one captured.
    const drain_err: ?anyerror = out_err orelse err_err;
    if (drain_err) |e| {
        child.kill(io);
        if (out_bytes) |b| allocator.free(b);
        if (err_bytes) |b| allocator.free(b);
        return e;
    }

    const term = try child.wait(io);
    return .{
        .term = term,
        .stdout = out_bytes.?,
        .stderr = err_bytes.?,
        .allocator = allocator,
    };
}

// ---------------------------------------------------------------------------
// Value encoding
// ---------------------------------------------------------------------------
//
// `secret-tool` transports the secret as a stdin line and `pass` as file text,
// so neither round-trips arbitrary bytes (an embedded NUL truncates the line; a
// stray newline is ambiguous). Both backends therefore base64-encode on write
// and decode on read, preserving the plugin's opaque-bytes contract uniformly
// (ADR-0010). A value inspected via `secret-tool` / `pass show` reads as base64.

const b64 = std.base64.standard;

/// base64-encode a secret value. Caller owns the result.
pub fn encodeValue(allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]u8 {
    const dst = try allocator.alloc(u8, b64.Encoder.calcSize(value.len));
    _ = b64.Encoder.encode(dst, value);
    return dst;
}

/// Reverse `encodeValue`. Returns `error.InvalidBase64` if the stored text is
/// not what we wrote. Caller owns the result (and must not be zeroed here — it
/// is the plaintext the caller asked for); the error path *is* wiped, since a
/// partially-decoded buffer holds secret bytes we are about to discard.
pub fn decodeValue(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const n = b64.Decoder.calcSizeForSlice(encoded) catch return error.InvalidBase64;
    const dst = try allocator.alloc(u8, n);
    errdefer {
        std.crypto.secureZero(u8, dst);
        allocator.free(dst);
    }
    b64.Decoder.decode(dst, encoded) catch return error.InvalidBase64;
    return dst;
}

test "value survives base64 round-trip including NUL and high bytes" {
    const a = std.testing.allocator;
    const raw = [_]u8{ 'a', 0x00, 'b', 0xff, '\n' };
    const enc = try encodeValue(a, &raw);
    defer a.free(enc);
    const dec = try decodeValue(a, enc);
    defer a.free(dec);
    try std.testing.expectEqualSlices(u8, &raw, dec);
}

// The large-payload round-trip proves the stdin write and stdout drain overlap
// (defect: a pre-fix `run` deadlocked once the base64 stdin exceeded the pipe
// buffer). It shells out to a POSIX filter; skipped where unavailable.
test "run round-trips a payload larger than the pipe buffer without deadlock" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    // 256 KiB — comfortably past the ~64 KiB pipe buffer that triggers the
    // deadlock. `cat` echoes stdin to stdout verbatim.
    const payload = try a.alloc(u8, 256 * 1024);
    defer a.free(payload);
    for (payload, 0..) |*b, i| b.* = @intCast('A' + (i % 26));

    var out = run(a, std.testing.io, &env, &.{"cat"}, payload) catch |e| switch (e) {
        // `cat` not on PATH in this environment — nothing to prove here.
        Error.SpawnFailed => return error.SkipZigTest,
        else => return e,
    };
    defer out.deinit();

    try std.testing.expect(out.ok());
    try std.testing.expectEqualSlices(u8, payload, out.stdout);
}

test "run round-trips an empty stdin payload" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    var out = run(a, std.testing.io, &env, &.{"cat"}, "") catch |e| switch (e) {
        Error.SpawnFailed => return error.SkipZigTest,
        else => return e,
    };
    defer out.deinit();

    try std.testing.expect(out.ok());
    try std.testing.expectEqualStrings("", out.stdout);
}
