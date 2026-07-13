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
    /// The value is too large for the Secret Service backend. `secret-tool store`
    /// reads the secret from stdin into a fixed 8192-byte buffer and silently
    /// drops the overflow (it prints "password is too long" but still exits 0 and
    /// stores the truncated value), so anything whose base64 encoding exceeds that
    /// cap cannot be stored intact here. Callers should use the `pass` backend
    /// (`ZCLI_SECRETS_BACKEND=pass`) for large secrets. Maps to the shared
    /// `SecretTooLarge`, the same clean-failure contract Windows uses for its
    /// 2560-byte blob cap.
    SecretTooLarge,
};

/// The largest base64-encoded payload `secret-tool store` will read from stdin
/// intact. libsecret's `read_password_stdin()` (tool/secret-tool.c) allocates a
/// fixed `remaining = 8192` buffer and reads into it in a loop; once `remaining`
/// reaches 0 the next `read(0, at, 0)` returns 0 (read as EOF), so bytes past
/// 8192 are silently discarded. We base64 the secret before storing it, so this
/// is a limit on the *encoded* length, not the raw value: a raw value up to
/// `8192 * 3 / 4` = 6144 bytes encodes within the cap. This is an upper bound
/// used for a cheap pre-flight reject; the authoritative check is the
/// verify-after-store read-back in `set`, which catches truncation regardless of
/// where the exact boundary lands.
const max_encoded_len: usize = 8192;

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
///
/// `secret-tool store` silently truncates a stdin secret past 8192 bytes (see
/// `max_encoded_len`), so this guards against that two ways: a cheap up-front
/// reject when the encoded length already exceeds the cap, and — the
/// authoritative check — a verify-after-store read-back that fails
/// `SecretTooLarge` if what came back differs from what we wrote. A truncated
/// entry is best-effort deleted so we never leave a corrupt value in the store.
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

    // Cheap pre-flight: anything past the fixed stdin buffer would be truncated,
    // so reject before spawning rather than store a value we know is corrupt.
    if (encoded.len > max_encoded_len) return Error.SecretTooLarge;

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

    // Verify-after-store: read the value back and confirm it survived intact.
    // `secret-tool store` exits 0 even when it truncated the secret to the 8192
    // stdin cap, so a zero exit is not proof the store is correct — this read-back
    // is. Store operations are rare and user-triggered, so the extra roundtrip is
    // cheap insurance against a silent corrupt write.
    if (!try verifyStored(allocator, io, environ, service, name, value)) {
        // Best-effort remove the truncated entry so a later `get` can't hand back
        // a corrupt secret; ignore its outcome (the truncation is the real error).
        delete(allocator, io, environ, service, name) catch {};
        return Error.SecretTooLarge;
    }
}

/// Read the just-stored secret back and compare it byte-for-byte against `want`.
/// Returns `true` when they match, `false` when the store returned something
/// different (i.e. the value was truncated) or nothing at all. Split out so the
/// truncation-detection compare is unit-testable via `verifyAgainst`.
///
/// A truncated base64 read-back often no longer decodes, so `get` can fail with
/// `SecretBackendFailure` on exactly the corrupt-store case we are checking for;
/// that counts as a failed verification (`false`), NOT a propagated error. Only a
/// genuinely different problem — the service going away between the store and the
/// read-back — is surfaced, so a real infra fault is never masked as "too large".
fn verifyStored(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    service: []const u8,
    name: []const u8,
    want: []const u8,
) !bool {
    const maybe = get(allocator, io, environ, service, name) catch |e| switch (e) {
        Error.ServiceUnavailable => return e,
        else => return false, // corrupt/undecodable read-back ⇒ verification failed
    };
    const got = maybe orelse return false;
    defer {
        // `got` holds the (decoded) secret read back from the store — wipe it
        // before the allocator reclaims the pages, not just free it. It is
        // allocator-owned and about to be discarded, so the const cast is sound.
        std.crypto.secureZero(u8, @constCast(got));
        allocator.free(got);
    }
    return verifyAgainst(got, want);
}

/// The core truncation-detection compare, factored out so it can be unit-tested
/// without a live Secret Service. `true` iff the read-back exactly equals what we
/// asked to store.
fn verifyAgainst(got: []const u8, want: []const u8) bool {
    return std.mem.eql(u8, got, want);
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

test "verifyAgainst detects a truncated read-back" {
    // Exact match — the store round-tripped intact.
    try std.testing.expect(verifyAgainst("hello", "hello"));
    try std.testing.expect(verifyAgainst("", ""));

    // A prefix is exactly what `secret-tool`'s 8192-byte truncation produces:
    // the first N bytes match, the tail is missing → must be rejected.
    try std.testing.expect(!verifyAgainst("hell", "hello"));
    // Any mismatch, including a longer read-back, is a failure.
    try std.testing.expect(!verifyAgainst("hello!", "hello"));
    try std.testing.expect(!verifyAgainst("", "hello"));
}

test "max_encoded_len matches secret-tool's fixed stdin buffer" {
    // Guards against a silent drift of the documented cap; 8192 is libsecret's
    // `read_password_stdin` buffer size (tool/secret-tool.c).
    try std.testing.expectEqual(@as(usize, 8192), max_encoded_len);

    // The encoded-length pre-flight rejects a raw value whose base64 exceeds the
    // cap, and accepts one that fits. base64 encodes 3 raw bytes to 4, so the
    // largest raw value that fits is 8192 * 3 / 4 = 6144 bytes.
    const b64 = std.base64.standard;
    try std.testing.expect(b64.Encoder.calcSize(6144) <= max_encoded_len);
    try std.testing.expect(b64.Encoder.calcSize(6145) > max_encoded_len);
}
