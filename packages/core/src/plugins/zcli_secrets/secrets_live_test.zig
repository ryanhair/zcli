//! Live round-trip test for the native `zcli_secrets` backend of the host OS.
//!
//! This actually writes to, reads from, and deletes from the real OS keychain,
//! so it is **not** part of the default `test` step (it would mutate a
//! developer's login keychain and, on Linux, needs a running Secret Service).
//! It is wired into the dedicated `test-secrets-live` build step, which CI runs
//! on each platform after preparing the environment (see `.github/workflows`).
//!
//! Run locally with, from `packages/core`: `zig build test-secrets-live`.

const std = @import("std");
const builtin = @import("builtin");

const backend = switch (builtin.os.tag) {
    .macos => @import("keychain_macos.zig"),
    .linux => @import("secret_service_linux.zig"),
    .windows => @import("credential_manager_windows.zig"),
    else => @compileError("no native secrets backend for this OS"),
};

// A throwaway service name that will not collide with real credentials, cleaned
// up at both ends of the test.
const service = "zcli-secrets-ci-roundtrip";
const name = "token";

test "native backend round-trips set / get / overwrite / delete" {
    const a = std.testing.allocator;

    // Start from a clean slate even if a prior aborted run left an entry.
    try backend.delete(a, service, name);
    try std.testing.expect((try backend.get(a, service, name)) == null);

    // Store and read back.
    try backend.set(a, service, name, "first-value");
    {
        const v = (try backend.get(a, service, name)).?;
        defer a.free(v);
        try std.testing.expectEqualStrings("first-value", v);
    }

    // Overwrite an existing entry.
    try backend.set(a, service, name, "second-value");
    {
        const v = (try backend.get(a, service, name)).?;
        defer a.free(v);
        try std.testing.expectEqualStrings("second-value", v);
    }

    // Delete, confirm gone, and confirm a second delete is a no-op.
    try backend.delete(a, service, name);
    try std.testing.expect((try backend.get(a, service, name)) == null);
    try backend.delete(a, service, name);
}
