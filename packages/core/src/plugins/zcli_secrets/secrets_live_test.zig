//! Live round-trip test for the host OS's native `zcli_secrets` backend.
//!
//! This actually writes to, reads from, and deletes from the real OS keychain,
//! so it is **not** part of the default `test` step (it would mutate a
//! developer's login keychain and, on Linux, needs a running Secret Service).
//! It is wired into the dedicated `test-secrets-live` build step, which CI runs
//! on each platform after preparing the environment (see `.github/workflows`).
//!
//! It deliberately drives the plugin's **public API** (`ContextData` +
//! `context.plugins.zcli_secrets.<op>(context, ...)`) through a mock context,
//! not the backend module directly — so this is the one place the generic API
//! surface is actually instantiated and compiled, on every platform in CI.
//!
//! Run locally with, from `packages/core`: `zig build test-secrets-live`.

const std = @import("std");
const builtin = @import("builtin");
const plugin = @import("plugin.zig");

/// Minimal stand-in for the framework Context — the plugin's storage methods
/// read `allocator`, `app_name`, and (for the Linux shell-out backend) `io` and
/// `environ` off it.
const MockContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    app_name: []const u8,
    err_writer: *std.Io.Writer,

    /// The plugin surfaces backend diagnostics via `context.stderr()`; the
    /// live test discards them (they only fire on error paths).
    pub fn stderr(self: *const MockContext) *std.Io.Writer {
        return self.err_writer;
    }
};

// A throwaway service name that will not collide with real credentials, cleaned
// up at both ends of the test.
const service = "zcli-secrets-ci-roundtrip";
const name = "token";

/// True when the active Linux backend is the Secret Service — either forced by
/// CI via `ZCLI_SECRETS_BACKEND=secret-service` (how the two Linux live steps are
/// made deterministic) or autodetected. The large-value assertion branches on
/// this because the Secret Service caps a stored value at ~6 KiB while `pass` and
/// the macOS Keychain do not. On non-Linux this is always false (Windows is
/// handled by its own branch; macOS has no cap).
fn isSecretServiceBackend(env: *const std.process.Environ.Map) bool {
    if (builtin.os.tag != .linux) return false;
    // CI forces the backend per step, so the override is the reliable signal.
    if (env.get("ZCLI_SECRETS_BACKEND")) |choice|
        return std.mem.eql(u8, choice, "secret-service");
    // No override: a live session bus means the Secret Service is the autodetected
    // choice. (Local ad-hoc runs; CI always sets the override.)
    return env.get("DBUS_SESSION_BUS_ADDRESS") != null;
}

test "public API round-trips set / get / overwrite / delete via ContextData" {
    const a = std.testing.allocator;

    // The Linux backend shells out to secret-tool / pass / gpg, which need the
    // real process environment (session bus, HOME, gpg-agent) that CI set up.
    // 0.16 exposes the environment only via `std.process.Init` (unavailable in a
    // test) or the libc `std.c.environ`, so this CI-only test links libc to read
    // it (see build.zig). On macOS/Windows the keychain backends ignore
    // `environ`, so an empty map on Windows is fine.
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    if (builtin.os.tag != .windows) {
        var i: usize = 0;
        while (std.c.environ[i]) |entry| : (i += 1) {
            const pair = std.mem.span(entry); // "KEY=VALUE"
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (eq == 0) continue;
            try env.put(pair[0..eq], pair[eq + 1 ..]);
        }
    }

    var discard: std.Io.Writer.Discarding = .init(&.{});
    var ctx = MockContext{ .allocator = a, .io = std.testing.io, .environ = &env, .app_name = service, .err_writer = &discard.writer };
    var data: plugin.ContextData = .{};

    // Start from a clean slate even if a prior aborted run left an entry.
    try data.delete(&ctx, name);
    try std.testing.expect((try data.get(&ctx, name)) == null);

    // Store and read back.
    try data.set(&ctx, name, "first-value");
    {
        const v = (try data.get(&ctx, name)).?;
        defer a.free(v);
        try std.testing.expectEqualStrings("first-value", v);
    }

    // Overwrite an existing entry.
    try data.set(&ctx, name, "second-value");
    {
        const v = (try data.get(&ctx, name)).?;
        defer a.free(v);
        try std.testing.expectEqualStrings("second-value", v);
    }

    // A value with an embedded NUL and a high byte — the reason the shell-out
    // backends base64-wrap values; must round-trip byte-for-byte everywhere.
    const binary = [_]u8{ 'a', 0x00, 'b', 0xff, 0x0a };
    try data.set(&ctx, name, &binary);
    {
        const v = (try data.get(&ctx, name)).?;
        defer a.free(v);
        try std.testing.expectEqualSlices(u8, &binary, v);
    }

    // An empty value must round-trip (a distinct edge from "key absent" → null).
    try data.set(&ctx, name, "");
    {
        const v = (try data.get(&ctx, name)).?;
        defer a.free(v);
        try std.testing.expectEqualStrings("", v);
    }

    // Large-value behavior is backend-specific, so assert per backend:
    //
    //  - Windows Credential Manager caps a blob at 2560 bytes → SecretTooLarge.
    //  - The Linux Secret Service backend caps a stored value at ~6 KiB
    //    (`secret-tool` reads the secret into a fixed 8192-byte stdin buffer and
    //    silently truncates the rest); we reject/verify that as SecretTooLarge
    //    rather than store a corrupt value. A value comfortably under the cap must
    //    still round-trip exactly.
    //  - macOS Keychain and the Linux `pass` backend have no such cap, so a large
    //    value must round-trip intact — this also exercises the shell-out
    //    subprocess past the ~64 KiB OS pipe buffer (the size that used to
    //    deadlock the stdin write against an undrained stdout).
    {
        const big = try a.alloc(u8, 200 * 1024);
        defer a.free(big);
        for (big, 0..) |*b, i| b.* = @intCast('A' + (i % 26));

        if (builtin.os.tag == .windows) {
            try std.testing.expectError(plugin.Error.SecretTooLarge, data.set(&ctx, name, big));
        } else if (isSecretServiceBackend(&env)) {
            // 200 KiB is far past the ~6 KiB cap → must fail cleanly, never store
            // a truncated secret.
            try std.testing.expectError(plugin.Error.SecretTooLarge, data.set(&ctx, name, big));

            // A value comfortably under the cap (4 KiB raw → ~5.5 KiB base64,
            // within the 8192 stdin buffer) must round-trip exactly.
            const under = try a.alloc(u8, 4 * 1024);
            defer a.free(under);
            for (under, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
            try data.set(&ctx, name, under);
            const v = (try data.get(&ctx, name)).?;
            defer a.free(v);
            try std.testing.expectEqualSlices(u8, under, v);
        } else {
            // macOS Keychain / Linux `pass`: no cap, round-trips the large value.
            try data.set(&ctx, name, big);
            const v = (try data.get(&ctx, name)).?;
            defer a.free(v);
            try std.testing.expectEqualSlices(u8, big, v);
        }
    }

    // Delete, confirm gone, and confirm a second delete is a no-op.
    try data.delete(&ctx, name);
    try std.testing.expect((try data.get(&ctx, name)) == null);
    try data.delete(&ctx, name);

    // A NUL in the *name* is rejected before any backend call.
    try std.testing.expectError(plugin.Error.InvalidSecretName, data.get(&ctx, "bad\x00name"));
}
