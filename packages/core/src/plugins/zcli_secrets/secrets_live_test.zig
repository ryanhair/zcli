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
const plugin = @import("plugin.zig");

/// Minimal stand-in for the framework Context — the plugin's storage methods
/// only read `allocator` and `app_name` off it.
const MockContext = struct {
    allocator: std.mem.Allocator,
    app_name: []const u8,
};

// A throwaway service name that will not collide with real credentials, cleaned
// up at both ends of the test.
const service = "zcli-secrets-ci-roundtrip";
const name = "token";

test "public API round-trips set / get / overwrite / delete via ContextData" {
    const a = std.testing.allocator;
    var ctx = MockContext{ .allocator = a, .app_name = service };
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

    // A value with an embedded NUL and a high byte — the reason libsecret's
    // backend base64-wraps values; must round-trip byte-for-byte everywhere.
    const binary = [_]u8{ 'a', 0x00, 'b', 0xff, 0x0a };
    try data.set(&ctx, name, &binary);
    {
        const v = (try data.get(&ctx, name)).?;
        defer a.free(v);
        try std.testing.expectEqualSlices(u8, &binary, v);
    }

    // Delete, confirm gone, and confirm a second delete is a no-op.
    try data.delete(&ctx, name);
    try std.testing.expect((try data.get(&ctx, name)) == null);
    try data.delete(&ctx, name);

    // A NUL in the *name* is rejected before any backend call.
    try std.testing.expectError(plugin.Error.InvalidSecretName, data.get(&ctx, "bad\x00name"));
}
