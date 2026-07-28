//! Linux backend for `zcli_secrets` — a runtime-selected dispatcher over two
//! stores, neither of which is linked into the binary (both are reached by
//! shelling out, keeping a zcli binary static and musl-clean). See
//! `docs/adr/0010-linux-secrets-shell-out-and-pass.md`.
//!
//! Backend resolution, per operation (there is no state to cache, and these ops
//! are rare and user-triggered):
//!
//!   1. `ZCLI_SECRETS_BACKEND` — an explicit `secret-service` / `pass` override.
//!      Its store's readiness is never second-guessed, but its helper binary
//!      must still resolve, so a missing one is an actionable "install it"
//!      rather than an opaque failure at the first operation.
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
//!
//! "Present", throughout, means *resolvable to an absolute path in one of the
//! trusted directories* `subprocess.resolveHelper` searches — not "found on the
//! inherited PATH". The probe and the operation therefore agree on exactly which
//! binary is at stake, which is the point: the environment does not get to pick
//! the process that receives a decrypted credential on stdin.

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
    /// Autodetection: is this store usable *end to end* — helper present, and
    /// the store itself plausibly reachable (a session bus; an initialized
    /// `pass`)?
    secretServiceAvailable: *const fn (std.mem.Allocator, std.Io, *const std.process.Environ.Map) bool,
    passAvailable: *const fn (std.mem.Allocator, std.Io, *const std.process.Environ.Map) bool,
    /// Narrower: does this backend's helper *binary* resolve in a trusted
    /// directory? This alone is what the override path checks — see `resolve`.
    helperPresent: *const fn (std.Io, *const std.process.Environ.Map, []const u8) bool,
};

const real_probes = Probes{
    .secretServiceAvailable = secretServiceAvailable,
    .passAvailable = passAvailable,
    .helperPresent = toolPresent,
};

/// The helper binary a backend shells out to, spelled as
/// `subprocess.resolveHelper` expects it.
fn helperName(backend: Backend) []const u8 {
    return switch (backend) {
        .secret_service => "secret-tool",
        .pass => "pass",
    };
}

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
        const backend = parseOverride(choice) orelse return Error.InvalidBackendOverride;

        // The override says *which store*, not that its helper is installed. The
        // store's own readiness is still never second-guessed — a dead session
        // bus, a locked keyring, an uninitialized `pass` all surface as that
        // store's own error, which is clearer than silently picking another.
        // But a missing *binary* is not a store error at all; it has an exact,
        // actionable diagnostic, and pinning the helper to trusted directories
        // makes "installed, just not where we look" a real way to hit it. Left
        // unchecked it reached the caller as an opaque BackendFailure from the
        // first operation — worst on the one path where the user has told us
        // exactly what they want.
        if (!probes.helperPresent(io, environ, helperName(backend)))
            return Error.SecretBackendUnavailable;

        return .{ .backend = backend, .from_override = true };
    }
    if (probes.secretServiceAvailable(allocator, io, environ))
        return .{ .backend = .secret_service, .from_override = false };
    if (probes.passAvailable(allocator, io, environ))
        return .{ .backend = .pass, .from_override = false };
    return Error.SecretBackendUnavailable;
}

/// Render this backend's resolve failures as an actionable, user-facing line.
///
/// The diagnostic is produced here (not emitted here) so it flows through the
/// caller's context stream rather than `std.log` — output belongs on
/// `context.stderr()`, and a side-channel `log.err` both violates that contract
/// and fails Zig's test runner on the error-path unit tests. `environ` recovers
/// the offending override value for the `InvalidBackendOverride` message.
///
/// Returns `false` for any error this backend does not own a message for (and
/// writes nothing), so the caller can fall back to its generic handling.
pub fn diagnostic(w: *std.Io.Writer, e: anyerror, environ: *const std.process.Environ.Map) std.Io.Writer.Error!bool {
    switch (e) {
        Error.InvalidBackendOverride => {
            const choice = environ.get("ZCLI_SECRETS_BACKEND") orelse "";
            try w.print(
                "ZCLI_SECRETS_BACKEND='{s}' is not recognized; use 'secret-service' or 'pass'.\n",
                .{choice},
            );
            return true;
        },
        Error.SecretBackendUnavailable => {
            // A user who set the override has already answered "which store?",
            // so "force one with ZCLI_SECRETS_BACKEND" is not the advice they
            // need. Name the binary that is missing and where it is looked for.
            if (environ.get("ZCLI_SECRETS_BACKEND")) |choice| {
                if (parseOverride(choice)) |backend| {
                    try w.print(
                        "ZCLI_SECRETS_BACKEND='{s}' selects that backend, but its helper `{s}` was " ++
                            "not found in any standard location (/usr/bin, /bin, /usr/local/bin, " ++
                            "~/.nix-profile/bin, ~/.local/bin, ...). zcli_secrets resolves the helper " ++
                            "itself instead of trusting PATH, so a decrypted credential is never handed " ++
                            "to whichever binary the environment happened to name. Install it, or " ++
                            "symlink it into /usr/local/bin.\n",
                        .{ choice, helperName(backend) },
                    );
                    return true;
                }
            }
            try w.writeAll(
                "no secret backend available. zcli_secrets needs either a running freedesktop " ++
                    "Secret Service (a desktop keyring such as gnome-keyring or KWallet on the " ++
                    "session D-Bus, with `secret-tool` installed) or `pass` with an initialized " ++
                    "store (`pass init <gpg-id>`). Force one with ZCLI_SECRETS_BACKEND=secret-service|pass. " ++
                    "The helper is looked up in standard locations (/usr/bin, /bin, /usr/local/bin, " ++
                    "~/.local/bin, ...) rather than on PATH, so that a decrypted credential is never " ++
                    "handed to whichever binary the environment happened to name; if yours is installed " ++
                    "elsewhere, symlink it into /usr/local/bin.\n",
            );
            return true;
        },
        secret_service.Error.SecretTooLarge => {
            try w.writeAll(
                "secret is too large for the Secret Service backend, which caps a stored value " ++
                    "at ~6 KiB (`secret-tool` reads the secret into a fixed 8 KiB stdin buffer and " ++
                    "silently truncates the rest). Use the `pass` backend for large secrets: " ++
                    "ZCLI_SECRETS_BACKEND=pass.\n",
            );
            return true;
        },
        else => return false,
    }
}

// The two probes no longer allocate: presence is now decided by resolving the
// helper's absolute path rather than by spawning it (see `toolPresent`). The
// allocator stays in the `Probes` signature so the seam keeps one uniform shape
// for the injected test doubles.

fn secretServiceAvailable(_: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) bool {
    // Without a session bus the Secret Service daemon is unreachable — the
    // common headless / SSH case — so skip it and let `pass` be tried. Even with
    // a bus present the service may still be absent; that case is caught at
    // operation time and falls through to `pass` (see `canFallThrough`).
    if (environ.get("DBUS_SESSION_BUS_ADDRESS") == null) return false;
    return toolPresent(io, environ, "secret-tool");
}

fn passAvailable(_: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) bool {
    if (!toolPresent(io, environ, "pass")) return false;
    return passStoreInitialized(io, environ);
}

/// True when the helper binary exists, and is executable, in one of the trusted
/// directories `subprocess.resolveHelper` searches.
///
/// This used to *spawn* the tool (`secret-tool --version`, `pass version`) purely
/// to prove it could be launched. That is no longer the right question: the
/// backends do not launch whatever the inherited PATH resolves, they launch the
/// binary this resolution pins, so "is it present" and "which one would we run"
/// have to be the same lookup. It is also strictly cheaper — two `faccessat`
/// calls in the common case instead of a fork+exec.
fn toolPresent(io: std.Io, environ: *const std.process.Environ.Map, helper: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = subprocess.resolveHelper(io, environ, helper, &buf) catch return false;
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

/// Probes whose autodetect answers are fixed at comptime. `helperPresent`
/// answers `helper` for every binary, so the override path can be driven too.
fn probesReturning(comptime ss: bool, comptime ps: bool, comptime helper: bool) Probes {
    const S = struct {
        fn secretService(_: std.mem.Allocator, _: std.Io, _: *const std.process.Environ.Map) bool {
            return ss;
        }
        fn passAvail(_: std.mem.Allocator, _: std.Io, _: *const std.process.Environ.Map) bool {
            return ps;
        }
        fn helperFound(_: std.Io, _: *const std.process.Environ.Map, _: []const u8) bool {
            return helper;
        }
    };
    return .{
        .secretServiceAvailable = S.secretService,
        .passAvailable = S.passAvail,
        .helperPresent = S.helperFound,
    };
}

test "resolve: explicit override wins and is marked from_override (no store probing)" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    // Store-availability probes that would panic if consulted: an override must
    // never be talked out of its choice by autodetection. It *does* consult
    // `helperPresent`, which is the one thing it checks — see `resolve`.
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
        .helperPresent = struct {
            fn f(_: std.Io, _: *const std.process.Environ.Map, _: []const u8) bool {
                return true;
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

test "resolve: an override whose helper is missing is BackendUnavailable, not a later BackendFailure" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    // Autodetect says both stores are fine; only the helper binary is absent.
    // Before this check the override skipped resolution entirely and the caller
    // met an opaque BackendFailure at the first get/set/delete instead of the
    // actionable "install it / symlink it" line.
    const no_helper = probesReturning(true, true, false);

    for ([_][]const u8{ "pass", "secret-service" }) |choice| {
        try env.put("ZCLI_SECRETS_BACKEND", choice);
        try std.testing.expectError(
            Error.SecretBackendUnavailable,
            resolve(a, std.testing.io, &env, no_helper),
        );
    }

    // The helper check is the *only* thing gating the override: with the binary
    // present it is honored even though neither store probe says it is usable.
    const helper_only = probesReturning(false, false, true);
    try env.put("ZCLI_SECRETS_BACKEND", "pass");
    const sel = try resolve(a, std.testing.io, &env, helper_only);
    try std.testing.expectEqual(Backend.pass, sel.backend);
    try std.testing.expect(sel.from_override);
}

test "helperName maps each backend to the binary it shells out to" {
    try std.testing.expectEqualStrings("secret-tool", helperName(.secret_service));
    try std.testing.expectEqualStrings("pass", helperName(.pass));
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

test "diagnostic renders the actionable line for this backend's resolve errors" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("ZCLI_SECRETS_BACKEND", "vault");

    // Unrecognized override — names the offending value recovered from environ.
    {
        var aw = std.Io.Writer.Allocating.init(a);
        defer aw.deinit();
        try std.testing.expect(try diagnostic(&aw.writer, Error.InvalidBackendOverride, &env));
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), "'vault'") != null);
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), "not recognized") != null);
    }

    // No backend available — names both stores and the override escape hatch.
    {
        var aw = std.Io.Writer.Allocating.init(a);
        defer aw.deinit();
        try std.testing.expect(try diagnostic(&aw.writer, Error.SecretBackendUnavailable, &env));
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), "no secret backend available") != null);
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), "ZCLI_SECRETS_BACKEND=secret-service|pass") != null);
    }

    // A too-large secret on the Secret Service backend — points the user at pass.
    {
        var aw = std.Io.Writer.Allocating.init(a);
        defer aw.deinit();
        try std.testing.expect(try diagnostic(&aw.writer, secret_service.Error.SecretTooLarge, &env));
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), "too large") != null);
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), "ZCLI_SECRETS_BACKEND=pass") != null);
    }

    // An error this backend does not own: no message, returns false.
    {
        var aw = std.Io.Writer.Allocating.init(a);
        defer aw.deinit();
        try std.testing.expect(!try diagnostic(&aw.writer, error.SomethingElse, &env));
        try std.testing.expectEqualStrings("", aw.written());
    }
}

test "resolve: autodetect prefers Secret Service when available" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const sel = try resolve(a, std.testing.io, &env, probesReturning(true, true, true));
    try std.testing.expectEqual(Backend.secret_service, sel.backend);
    try std.testing.expect(!sel.from_override);
}

test "resolve: autodetect falls to pass when Secret Service is absent" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const sel = try resolve(a, std.testing.io, &env, probesReturning(false, true, true));
    try std.testing.expectEqual(Backend.pass, sel.backend);
    try std.testing.expect(!sel.from_override);
}

test "resolve: neither store available is a clear error" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try std.testing.expectError(
        Error.SecretBackendUnavailable,
        resolve(a, std.testing.io, &env, probesReturning(false, false, true)),
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
