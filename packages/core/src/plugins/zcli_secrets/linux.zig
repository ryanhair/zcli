//! Linux backend for `zcli_secrets` — a runtime-selected dispatcher over two
//! stores, neither of which is linked into the binary (both are reached by
//! shelling out, keeping a zcli binary static and musl-clean). See
//! `docs/adr/0010-linux-secrets-shell-out-and-pass.md`.
//!
//! Backend resolution, per operation (there is no state to cache, and these ops
//! are rare and user-triggered):
//!
//!   1. `ZCLI_SECRETS_BACKEND` — an explicit `secret-service` / `pass` override.
//!   2. Secret Service — when `secret-tool` is present *and* a session bus is
//!      reachable (`DBUS_SESSION_BUS_ADDRESS`); the bus check is what lets a
//!      headless box fall through instead of blocking on a dead daemon.
//!   3. `pass` — when the `pass` binary is present *and* the store is
//!      initialized (a `.gpg-id` exists).
//!   4. Neither — an actionable error naming both options and the override.

const std = @import("std");
const subprocess = @import("subprocess.zig");
const secret_service = @import("linux_secret_service.zig");
const pass = @import("linux_pass.zig");

const log = std.log.scoped(.zcli_secrets);

pub const Error = error{
    /// No usable secret store on this Linux system, and none was forced.
    SecretBackendUnavailable,
    /// `ZCLI_SECRETS_BACKEND` named something other than `secret-service`/`pass`.
    InvalidBackendOverride,
};

const Backend = enum { secret_service, pass };

/// Retrieve a secret. Returns `null` if it was never stored. The returned bytes
/// are owned by `allocator`.
pub fn get(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    service: []const u8,
    name: []const u8,
) !?[]const u8 {
    return switch (try resolve(allocator, io, environ)) {
        .secret_service => secret_service.get(allocator, io, environ, service, name),
        .pass => pass.get(allocator, io, environ, service, name),
    };
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
    return switch (try resolve(allocator, io, environ)) {
        .secret_service => secret_service.set(allocator, io, environ, service, name, value),
        .pass => pass.set(allocator, io, environ, service, name, value),
    };
}

/// Remove a secret. A no-op (success) if it does not exist.
pub fn delete(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    service: []const u8,
    name: []const u8,
) !void {
    return switch (try resolve(allocator, io, environ)) {
        .secret_service => secret_service.delete(allocator, io, environ, service, name),
        .pass => pass.delete(allocator, io, environ, service, name),
    };
}

/// Parse a `ZCLI_SECRETS_BACKEND` override value, or `null` if unrecognized.
fn parseOverride(choice: []const u8) ?Backend {
    if (std.mem.eql(u8, choice, "secret-service")) return .secret_service;
    if (std.mem.eql(u8, choice, "pass")) return .pass;
    return null;
}

fn resolve(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) Error!Backend {
    if (environ.get("ZCLI_SECRETS_BACKEND")) |choice| {
        // An explicit override is honored as-is (even if the store turns out to
        // be unusable — the operation then fails with the store's own error,
        // which is clearer than silently picking a different one).
        return parseOverride(choice) orelse {
            log.err("ZCLI_SECRETS_BACKEND='{s}' is not recognized; use 'secret-service' or 'pass'.", .{choice});
            return Error.InvalidBackendOverride;
        };
    }
    if (secretServiceAvailable(allocator, io, environ)) return .secret_service;
    if (passAvailable(allocator, io, environ)) return .pass;
    log.err(
        "no secret backend available. zcli_secrets needs either a running freedesktop " ++
            "Secret Service (a desktop keyring such as gnome-keyring or KWallet on the " ++
            "session D-Bus, with `secret-tool` installed) or `pass` with an initialized " ++
            "store (`pass init <gpg-id>`). Force one with ZCLI_SECRETS_BACKEND=secret-service|pass.",
        .{},
    );
    return Error.SecretBackendUnavailable;
}

fn secretServiceAvailable(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) bool {
    // Without a session bus the Secret Service daemon is unreachable — the
    // common headless / SSH case — so skip it and let `pass` be tried.
    if (environ.get("DBUS_SESSION_BUS_ADDRESS") == null) return false;
    return toolPresent(allocator, io, environ, &.{ "secret-tool", "--version" });
}

fn passAvailable(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) bool {
    if (!toolPresent(allocator, io, environ, &.{ "pass", "version" })) return false;
    return passStoreInitialized(io, environ);
}

/// True when the helper binary can be executed at all — regardless of its exit
/// code. (`secret-tool` has no `--version` subcommand, but attempting it still
/// proves the binary resolves on PATH; only a spawn failure means "absent".)
fn toolPresent(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, argv: []const []const u8) bool {
    var out = subprocess.run(allocator, io, environ, argv, null) catch return false;
    out.deinit();
    return true;
}

/// True when `pass` has an initialized store: a `.gpg-id` under
/// `PASSWORD_STORE_DIR` (or `~/.password-store`).
fn passStoreInitialized(io: std.Io, environ: *const std.process.Environ.Map) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const gpg_id_path = if (environ.get("PASSWORD_STORE_DIR")) |dir|
        std.fmt.bufPrint(&buf, "{s}/.gpg-id", .{dir}) catch return false
    else if (environ.get("HOME")) |home|
        std.fmt.bufPrint(&buf, "{s}/.password-store/.gpg-id", .{home}) catch return false
    else
        return false;

    const f = std.Io.Dir.cwd().openFile(io, gpg_id_path, .{}) catch return false;
    f.close(io);
    return true;
}

// Pull the sibling files' tests into this backend's test binary, so a single
// `zig build test-secrets` on Linux runs the whole backend's units.
test {
    _ = @import("subprocess.zig");
    _ = @import("linux_secret_service.zig");
    _ = @import("linux_pass.zig");
}

test "backend override parsing" {
    try std.testing.expectEqual(Backend.secret_service, parseOverride("secret-service").?);
    try std.testing.expectEqual(Backend.pass, parseOverride("pass").?);
    try std.testing.expect(parseOverride("nonsense") == null);
}

test "resolve honors an explicit override without probing" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    try env.put("ZCLI_SECRETS_BACKEND", "pass");
    try std.testing.expectEqual(Backend.pass, try resolve(a, std.testing.io, &env));

    try env.put("ZCLI_SECRETS_BACKEND", "secret-service");
    try std.testing.expectEqual(Backend.secret_service, try resolve(a, std.testing.io, &env));
}
