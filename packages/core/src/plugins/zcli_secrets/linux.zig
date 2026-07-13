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
//!
//! Detecting the Secret Service reliably up front is impossible without actually
//! talking to it: `DBUS_SESSION_BUS_ADDRESS` can be set on a session that runs
//! *no* keyring (nothing owns `org.freedesktop.secrets`). So when the Secret
//! Service is chosen by autodetection (not by an explicit override) and the
//! operation comes back reporting the service is unreachable, this falls through
//! to `pass` if it is usable. The fall-through is deliberately narrow: only the
//! `ServiceUnavailable` signal (see `linux_secret_service.noServiceSignal`)
//! triggers it — a real error such as a locked or access-denied keyring is
//! surfaced, never masked by silently trying a different store.

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

/// How a backend was chosen — an explicit override must NOT fall through to a
/// different store on failure (the user asked for that one specifically), but an
/// autodetected Secret Service may fall through to `pass`.
const Selection = struct { backend: Backend, from_override: bool };

/// Probe seam. Real code uses `real_probes`; tests inject deterministic answers
/// to exercise the full resolve matrix without a live D-Bus / `pass` store.
pub const Probes = struct {
    secretServiceAvailable: *const fn (std.mem.Allocator, std.Io, *const std.process.Environ.Map) bool,
    passAvailable: *const fn (std.mem.Allocator, std.Io, *const std.process.Environ.Map) bool,
};

const real_probes = Probes{
    .secretServiceAvailable = secretServiceAvailable,
    .passAvailable = passAvailable,
};

/// Retrieve a secret. Returns `null` if it was never stored. The returned bytes
/// are owned by `allocator`.
pub fn get(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    service: []const u8,
    name: []const u8,
) !?[]const u8 {
    const sel = try resolve(allocator, io, environ, real_probes);
    return switch (sel.backend) {
        .secret_service => secret_service.get(allocator, io, environ, service, name) catch |e| {
            if (canFallThrough(sel, e, allocator, io, environ))
                return pass.get(allocator, io, environ, service, name);
            return e;
        },
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
    const sel = try resolve(allocator, io, environ, real_probes);
    return switch (sel.backend) {
        .secret_service => secret_service.set(allocator, io, environ, service, name, value) catch |e| {
            if (canFallThrough(sel, e, allocator, io, environ))
                return pass.set(allocator, io, environ, service, name, value);
            return e;
        },
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
    const sel = try resolve(allocator, io, environ, real_probes);
    return switch (sel.backend) {
        .secret_service => secret_service.delete(allocator, io, environ, service, name) catch |e| {
            if (canFallThrough(sel, e, allocator, io, environ))
                return pass.delete(allocator, io, environ, service, name);
            return e;
        },
        .pass => pass.delete(allocator, io, environ, service, name),
    };
}

/// True when an autodetected Secret Service op failed *because the service is
/// absent* and `pass` is usable — the one case a fall-through is warranted.
fn canFallThrough(
    sel: Selection,
    e: anyerror,
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) bool {
    if (sel.from_override) return false; // user pinned this store; don't second-guess
    if (e != secret_service.Error.ServiceUnavailable) return false;
    if (!passAvailable(allocator, io, environ)) return false;
    log.debug("Secret Service unreachable; falling through to pass", .{});
    return true;
}

/// Parse a `ZCLI_SECRETS_BACKEND` override value, or `null` if unrecognized.
fn parseOverride(choice: []const u8) ?Backend {
    if (std.mem.eql(u8, choice, "secret-service")) return .secret_service;
    if (std.mem.eql(u8, choice, "pass")) return .pass;
    return null;
}

fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    probes: Probes,
) Error!Selection {
    if (environ.get("ZCLI_SECRETS_BACKEND")) |choice| {
        // An explicit override is honored as-is (even if the store turns out to
        // be unusable — the operation then fails with the store's own error,
        // which is clearer than silently picking a different one).
        const backend = parseOverride(choice) orelse {
            log.err("ZCLI_SECRETS_BACKEND='{s}' is not recognized; use 'secret-service' or 'pass'.", .{choice});
            return Error.InvalidBackendOverride;
        };
        return .{ .backend = backend, .from_override = true };
    }
    if (probes.secretServiceAvailable(allocator, io, environ))
        return .{ .backend = .secret_service, .from_override = false };
    if (probes.passAvailable(allocator, io, environ))
        return .{ .backend = .pass, .from_override = false };
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
    // common headless / SSH case — so skip it and let `pass` be tried. Even with
    // a bus present the service may still be absent; that case is caught at
    // operation time and falls through to `pass` (see `canFallThrough`).
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

// ---------------------------------------------------------------------------
// resolve matrix — driven through the probe seam so no live store is needed.
// ---------------------------------------------------------------------------

fn probesReturning(comptime ss: bool, comptime ps: bool) Probes {
    const S = struct {
        fn secretService(_: std.mem.Allocator, _: std.Io, _: *const std.process.Environ.Map) bool {
            return ss;
        }
        fn passAvail(_: std.mem.Allocator, _: std.Io, _: *const std.process.Environ.Map) bool {
            return ps;
        }
    };
    return .{ .secretServiceAvailable = S.secretService, .passAvailable = S.passAvail };
}

test "resolve: explicit override wins and is marked from_override (no probing)" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    // Probes that would panic if consulted — an override must not probe.
    const trap = Probes{
        .secretServiceAvailable = struct {
            fn f(_: std.mem.Allocator, _: std.Io, _: *const std.process.Environ.Map) bool {
                unreachable;
            }
        }.f,
        .passAvailable = struct {
            fn f(_: std.mem.Allocator, _: std.Io, _: *const std.process.Environ.Map) bool {
                unreachable;
            }
        }.f,
    };

    try env.put("ZCLI_SECRETS_BACKEND", "pass");
    const p = try resolve(a, std.testing.io, &env, trap);
    try std.testing.expectEqual(Backend.pass, p.backend);
    try std.testing.expect(p.from_override);

    try env.put("ZCLI_SECRETS_BACKEND", "secret-service");
    const s = try resolve(a, std.testing.io, &env, trap);
    try std.testing.expectEqual(Backend.secret_service, s.backend);
    try std.testing.expect(s.from_override);
}

test "resolve: an unrecognized override is a hard error" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("ZCLI_SECRETS_BACKEND", "vault");
    try std.testing.expectError(
        Error.InvalidBackendOverride,
        resolve(a, std.testing.io, &env, real_probes),
    );
}

test "resolve: autodetect prefers Secret Service when available" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const sel = try resolve(a, std.testing.io, &env, probesReturning(true, true));
    try std.testing.expectEqual(Backend.secret_service, sel.backend);
    try std.testing.expect(!sel.from_override);
}

test "resolve: autodetect falls to pass when Secret Service is absent" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const sel = try resolve(a, std.testing.io, &env, probesReturning(false, true));
    try std.testing.expectEqual(Backend.pass, sel.backend);
    try std.testing.expect(!sel.from_override);
}

test "resolve: neither store available is a clear error" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try std.testing.expectError(
        Error.SecretBackendUnavailable,
        resolve(a, std.testing.io, &env, probesReturning(false, false)),
    );
}

test "canFallThrough only for autodetected ServiceUnavailable with pass present" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    // Note: passAvailable here probes the real host, which without an
    // initialized store returns false — so this asserts the guards that do NOT
    // depend on `pass` being present.
    const auto = Selection{ .backend = .secret_service, .from_override = false };
    const pinned = Selection{ .backend = .secret_service, .from_override = true };

    // An override never falls through, even on ServiceUnavailable.
    try std.testing.expect(!canFallThrough(pinned, secret_service.Error.ServiceUnavailable, a, std.testing.io, &env));
    // A real operation error never falls through.
    try std.testing.expect(!canFallThrough(auto, secret_service.Error.SecretBackendFailure, a, std.testing.io, &env));
}
