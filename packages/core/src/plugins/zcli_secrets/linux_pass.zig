//! `pass` (passwordstore.org) backend for `zcli_secrets`.
//!
//! Stores each secret as a GPG-encrypted entry via the `pass` CLI, at the path
//! `zcli/<app_name>/<name>`. The `zcli/` prefix keeps the plugin from clobbering
//! a user's unrelated `pass` entries and makes ownership legible in `pass ls`.
//! Unlike the Secret Service, `pass` needs no desktop session — it works over
//! SSH / on a headless server — which is why it exists as a second Linux backend
//! (see ADR-0010). The value is base64-encoded (see `subprocess.encodeValue`).

const std = @import("std");
const subprocess = @import("subprocess.zig");

const log = std.log.scoped(.zcli_secrets);

pub const Error = error{
    /// A `pass` invocation failed for a reason other than "entry not in store".
    SecretBackendFailure,
};

/// Retrieve a secret. Returns `null` if the entry does not exist. The returned
/// bytes are owned by `allocator`.
pub fn get(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    service: []const u8,
    name: []const u8,
) !?[]const u8 {
    const path = try entryPath(allocator, service, name);
    defer allocator.free(path);

    var out = subprocess.run(allocator, io, environ, &.{ "pass", "show", path }, null) catch |e|
        return mapError(e);
    defer out.deinit();

    if (out.ok()) {
        // `pass show` prints the stored text; `insert --multiline` stored the
        // base64 verbatim, but trim a trailing newline defensively.
        const encoded = std.mem.trimEnd(u8, out.stdout, "\r\n");
        return subprocess.decodeValue(allocator, encoded) catch |e| return mapError(e);
    }
    if (isNotFound(out.stderr)) return null;
    logStderr(out.stderr);
    return Error.SecretBackendFailure;
}

/// Store (or overwrite) a secret.
pub fn set(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    service: []const u8,
    name: []const u8,
    value: []const u8,
) !void {
    const path = try entryPath(allocator, service, name);
    defer allocator.free(path);
    const encoded = try subprocess.encodeValue(allocator, value);
    defer allocator.free(encoded);

    // `insert --multiline` reads the entry body from stdin until EOF; `--force`
    // overwrites an existing entry without an interactive prompt.
    var out = subprocess.run(allocator, io, environ, &.{
        "pass", "insert", "--multiline", "--force", path,
    }, encoded) catch |e| return mapError(e);
    defer out.deinit();

    if (!out.ok()) {
        logStderr(out.stderr);
        return Error.SecretBackendFailure;
    }
}

/// Remove a secret. Succeeds (no-op) if the entry does not exist.
pub fn delete(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    service: []const u8,
    name: []const u8,
) !void {
    const path = try entryPath(allocator, service, name);
    defer allocator.free(path);

    var out = subprocess.run(allocator, io, environ, &.{ "pass", "rm", "--force", path }, null) catch |e|
        return mapError(e);
    defer out.deinit();

    if (out.ok()) return;
    if (isNotFound(out.stderr)) return; // deleting a missing entry is a no-op
    logStderr(out.stderr);
    return Error.SecretBackendFailure;
}

/// The `pass` entry path for a secret: `zcli/<app>/<name>`.
fn entryPath(allocator: std.mem.Allocator, service: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "zcli/{s}/{s}", .{ service, name });
}

/// `pass` reports a missing entry as "Error: <path> is not in the password
/// store." on stderr with a nonzero exit — the signal for get/delete no-ops.
fn isNotFound(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "not in the password store") != null;
}

fn logStderr(stderr: []const u8) void {
    log.debug("pass: {s}", .{std.mem.trim(u8, stderr, " \t\r\n")});
}

/// Collapse a launch failure (`pass` uninstalled) or a corrupt-value decode into
/// a backend failure — but never swallow `OutOfMemory`.
fn mapError(e: anyerror) anyerror {
    return if (e == error.OutOfMemory) error.OutOfMemory else Error.SecretBackendFailure;
}

test "entry path is namespaced under zcli/" {
    const a = std.testing.allocator;
    const p = try entryPath(a, "myapp", "token");
    defer a.free(p);
    try std.testing.expectEqualStrings("zcli/myapp/token", p);
}

test "isNotFound matches pass's missing-entry message" {
    try std.testing.expect(isNotFound("Error: zcli/myapp/token is not in the password store."));
    try std.testing.expect(!isNotFound("gpg: decryption failed: No secret key"));
}
