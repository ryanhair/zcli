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

    var out = subprocess.run(allocator, io, environ, &showArgv(path), null) catch |e|
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
    // `encoded` is base64 of the secret — wipe it before the allocator reclaims
    // the pages, not just free it.
    defer {
        std.crypto.secureZero(u8, encoded);
        allocator.free(encoded);
    }

    // `insert --multiline` reads the entry body from stdin until EOF; `--force`
    // overwrites an existing entry without an interactive prompt.
    //
    // Under a concurrent `pass rm` of the same key, `pass insert` can lose a race:
    // it mkdir's the entry's parent (`zcli/<app>/`), then invokes `gpg` to write
    // `<name>.gpg` into it — but a racing `rm` prunes that now-"empty" directory in
    // the window between, so `gpg` fails with "No such file or directory". That is
    // transient, not a real store error: re-running `insert` re-creates the
    // directory and succeeds. `set` must actually leave the value stored, so this
    // signature is retried a bounded number of times rather than surfaced.
    //
    // Bound derivation (not a guess): the per-attempt loss probability measured
    // under a deliberately adversarial two-deleter tight-loop is p ≈ 0.13–0.16, and
    // retries are independent (each redoes the full mkdir→gpg), so K attempts leave
    // ~p^K residual. K=8 gives < 1e-6 even at p=0.16 — negligible next to any real
    // backend fault. Empirically the depth-to-success never exceeded 1 across 800
    // adversarial trials, so 8 is pure headroom; retries only fire on the ENOENT
    // signature, and the overwhelmingly common case still succeeds on attempt 0.
    const store_attempts = 8;
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        var out = subprocess.run(allocator, io, environ, &insertArgv(path), encoded) catch |e| return mapError(e);
        defer out.deinit();

        if (out.ok()) return;
        if (isRaceLostDirVanished(out.stderr) and attempt + 1 < store_attempts) continue;
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

    var out = subprocess.run(allocator, io, environ, &rmArgv(path), null) catch |e|
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

// argv builders. `--` terminates `pass`'s option parsing so the entry path is
// always taken as a positional, never as a flag — belt-and-suspenders alongside
// the plugin boundary already rejecting a leading-dash name, and the path being
// prefixed `zcli/`. `pass` is a bash script that passes its args through
// `getopt`, which honours `--`. Isolating the argv here keeps the terminator's
// placement (immediately before `path`) unit-testable without spawning `pass`.
fn showArgv(path: []const u8) [4][]const u8 {
    return .{ "pass", "show", "--", path };
}
fn insertArgv(path: []const u8) [6][]const u8 {
    return .{ "pass", "insert", "--multiline", "--force", "--", path };
}
fn rmArgv(path: []const u8) [5][]const u8 {
    return .{ "pass", "rm", "--force", "--", path };
}

/// `pass` reports a missing entry as "Error: <path> is not in the password
/// store." on stderr with a nonzero exit — the signal for get/delete no-ops.
fn isNotFound(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "not in the password store") != null;
}

/// True when `pass insert` failed only because a concurrent `pass rm` pruned the
/// entry's parent directory mid-write, so `gpg` could not create the `.gpg` file.
/// The signature is gpg's "No such file or directory" — a transient the caller
/// retries, never a permanent store error. Kept narrow: it requires gpg's
/// can't-create phrasing, so an unrelated failure is not mistaken for the race.
fn isRaceLostDirVanished(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "No such file or directory") != null and
        (std.mem.indexOf(u8, stderr, "can't create") != null or
            std.mem.indexOf(u8, stderr, "encryption failed") != null);
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

test "pass argv places `--` immediately before the entry path" {
    const path = "zcli/app/token";
    // Each `pass` subcommand must terminate options with `--` right before the
    // path, so a path is never re-interpreted as a flag.
    inline for (.{ showArgv(path), insertArgv(path), rmArgv(path) }) |argv| {
        const last = argv.len - 1;
        try std.testing.expectEqualStrings("--", argv[last - 1]);
        try std.testing.expectEqualStrings(path, argv[last]);
        try std.testing.expectEqualStrings("pass", argv[0]);
    }
    // Full spellings, so an accidental flag reorder is caught.
    try std.testing.expectEqualSlices([]const u8, &.{ "pass", "show", "--", path }, &showArgv(path));
    try std.testing.expectEqualSlices([]const u8, &.{ "pass", "insert", "--multiline", "--force", "--", path }, &insertArgv(path));
    try std.testing.expectEqualSlices([]const u8, &.{ "pass", "rm", "--force", "--", path }, &rmArgv(path));
}

test "isNotFound matches pass's missing-entry message" {
    try std.testing.expect(isNotFound("Error: zcli/myapp/token is not in the password store."));
    try std.testing.expect(!isNotFound("gpg: decryption failed: No secret key"));
}

test "isRaceLostDirVanished matches the concurrent-rm insert failure only" {
    // The exact stderr observed when a racing `pass rm` prunes the parent dir mid
    // `pass insert` — gpg can't create the target file.
    try std.testing.expect(isRaceLostDirVanished(
        "gpg: can't create '/tmp/x/zcli/app/race-token.gpg': No such file or directory\n" ++
            "gpg: [stdin]: encryption failed: No such file or directory\n" ++
            "Password encryption aborted.",
    ));
    // A different failure that merely mentions "No such file or directory" without
    // gpg's can't-create / encryption-failed context is NOT this race.
    try std.testing.expect(!isRaceLostDirVanished("bash: pass: No such file or directory"));
    try std.testing.expect(!isRaceLostDirVanished("gpg: decryption failed: No secret key"));
    try std.testing.expect(!isRaceLostDirVanished(""));
}
