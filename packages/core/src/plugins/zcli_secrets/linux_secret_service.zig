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
    /// The Secret Service itself is unreachable — no daemon owns
    /// `org.freedesktop.secrets` on the session bus (a minimal session that sets
    /// `DBUS_SESSION_BUS_ADDRESS` but runs no keyring). Distinct from
    /// `SecretBackendFailure` so the Linux dispatcher can fall through to `pass`
    /// instead of surfacing an opaque failure. This is NOT returned for an
    /// unlocked/denied keyring or any operation-level error — only for
    /// "there is no service here".
    ServiceUnavailable,
};

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
    // `encoded` is base64 of the secret — wipe it before the allocator reclaims
    // the pages, not just free it.
    defer {
        std.crypto.secureZero(u8, encoded);
        allocator.free(encoded);
    }
    const label = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ service, name });
    defer allocator.free(label);

    // `secret-tool store` reads the secret from stdin; we feed it the base64.
    var out = subprocess.run(allocator, io, environ, &.{
        "secret-tool", "store", "--label", label, "service", service, "account", name,
    }, encoded) catch |e| return mapError(e);
    defer out.deinit();

    if (!out.ok()) {
        if (noServiceSignal(out.stderr)) return Error.ServiceUnavailable;
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
    if (noServiceSignal(out.stderr)) return Error.ServiceUnavailable;
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
