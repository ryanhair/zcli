//! Linux Secret Service backend for `zcli_secrets`, via the **`secret-tool`**
//! CLI (from `libsecret-tools`).
//!
//! Stores each secret through the freedesktop.org Secret Service — the same
//! daemon-encrypted keyring gnome-keyring / KWallet expose over D-Bus — keyed by
//! the attributes `(service = app_name, account = name)`. Unlike the original
//! backend, this *executes `secret-tool`* rather than linking `libsecret`, so a
//! zcli binary stays static and musl-clean (see ADR-0010). The value is
//! base64-encoded (see `subprocess.encodeValue`).

const std = @import("std");
const subprocess = @import("subprocess.zig");

const log = std.log.scoped(.zcli_secrets);

pub const Error = error{
    /// A `secret-tool` invocation failed for a reason other than "not found".
    SecretBackendFailure,
};

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
    const encoded = try subprocess.encodeValue(allocator, value);
    defer allocator.free(encoded);
    const label = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ service, name });
    defer allocator.free(label);

    // `secret-tool store` reads the secret from stdin; we feed it the base64.
    var out = subprocess.run(allocator, io, environ, &.{
        "secret-tool", "store", "--label", label, "service", service, "account", name,
    }, encoded) catch |e| return mapError(e);
    defer out.deinit();

    if (!out.ok()) {
        logStderr(out.stderr);
        return Error.SecretBackendFailure;
    }
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
