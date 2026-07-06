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

/// Run `argv`, optionally writing `stdin_bytes` (then EOF) to the child's
/// stdin, and capture stdout+stderr. The caller owns the returned `Output`
/// (call `deinit`).
///
/// `stdin_bytes` is expected to be small (a base64-encoded secret), so it is
/// written in full and stdin closed before stdout is drained — well under a
/// pipe buffer, so there is no unread-stdout deadlock.
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

    if (stdin_bytes) |bytes| {
        var in_buf: [256]u8 = undefined;
        var in = child.stdin.?.writer(io, &in_buf);
        // A write failure here just means the child closed stdin early; the exit
        // status read below is the authoritative signal, so it is ignored.
        in.interface.writeAll(bytes) catch {};
        in.interface.flush() catch {};
        child.stdin.?.close(io);
        child.stdin = null;
    }

    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out_reader = child.stdout.?.reader(io, &out_buf);
    var err_reader = child.stderr.?.reader(io, &err_buf);

    const stdout = out_reader.interface.allocRemaining(allocator, .limited(1 << 20)) catch |e| {
        child.kill(io);
        return e;
    };
    errdefer allocator.free(stdout);
    const stderr = err_reader.interface.allocRemaining(allocator, .limited(1 << 20)) catch |e| {
        child.kill(io);
        return e;
    };
    errdefer allocator.free(stderr);

    const term = try child.wait(io);
    return .{ .term = term, .stdout = stdout, .stderr = stderr, .allocator = allocator };
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
/// not what we wrote. Caller owns the result.
pub fn decodeValue(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const n = b64.Decoder.calcSizeForSlice(encoded) catch return error.InvalidBase64;
    const dst = try allocator.alloc(u8, n);
    errdefer allocator.free(dst);
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
