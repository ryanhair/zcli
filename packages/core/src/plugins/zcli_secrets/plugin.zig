//! zcli-secrets Plugin — opt-in credential storage.
//!
//! Provides `get` / `set` / `delete` of an **opaque named credential**, scoped
//! to the application. This is deliberately *storage only*: it does not
//! implement the auth flow that produces a credential (OAuth, device-code,
//! etc.) — that is service-specific logic left to freeform command code. The
//! canonical use is a `login` command that persists a token, and later commands
//! that read it back. See `docs/adr/0003-secrets-as-opt-in-plugin.md`.
//!
//! ## Why a plugin, not core
//!
//! A real OS keychain needs dynamic linking (macOS `Security.framework`, Linux
//! Secret Service, Windows Credential Manager). Linking that into *every* CLI
//! would break zcli's static single-binary (libc-free musl) property. So this
//! ships as an opt-in plugin: the native-linking cost is paid only by apps that
//! register it. A CLI that never registers `zcli_secrets` stays fully static.
//!
//! ## Backend selection
//!
//! The backend is a real OS keychain, chosen at compile time from the target OS.
//! Registering the plugin is what pulls in that platform's native-library
//! linking.
//!
//! - **macOS** → the OS Keychain (`keychain_macos.zig`; `Security` +
//!   `CoreFoundation`).
//! - **Linux** → the Secret Service via libsecret (`secret_service_linux.zig`;
//!   `libsecret-1` + glib, over D-Bus).
//! - **Windows** → the Credential Manager (`credential_manager_windows.zig`;
//!   `advapi32`).
//!
//! There is deliberately **no fallback**. Credentials belong in an OS-encrypted
//! keychain, not a plaintext file; so registering this plugin for any other
//! target is a **compile-time error** rather than a silent, insecure store.
//!
//! ## Usage from command code
//!
//! Because the plugin is registered, its data is reachable on the context and
//! carries the API — no import needed:
//!
//! ```zig
//! // In a `login` command, after obtaining `token` however you like:
//! try context.plugins.zcli_secrets.set(context, "token", token);
//!
//! // In a later command:
//! if (try context.plugins.zcli_secrets.get(context, "token")) |token| {
//!     defer context.allocator.free(token);
//!     // ... use token ...
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");

pub const plugin_id = "zcli_secrets";

/// Which OS keychain backend this target uses.
const Backend = enum { keychain, secret_service, credential_manager };

const active_backend: Backend = switch (builtin.os.tag) {
    .macos => .keychain,
    .linux => .secret_service,
    .windows => .credential_manager,
    else => @compileError(
        "zcli_secrets has no secure keychain backend for this target OS (" ++
            @tagName(builtin.os.tag) ++
            "). Supported: macOS (Keychain), Linux (Secret Service), Windows " ++
            "(Credential Manager). Credentials are not stored in a plaintext " ++
            "file fallback — remove the plugin for this target, or add a " ++
            "keychain backend for it.",
    ),
};

/// The native backend module for this target. Only the selected switch prong is
/// evaluated at compile time, so a build never imports a backend for another OS.
const native = switch (active_backend) {
    .keychain => @import("keychain_macos.zig"),
    .secret_service => @import("secret_service_linux.zig"),
    .credential_manager => @import("credential_manager_windows.zig"),
};

comptime {
    // Force backend *selection* when the plugin is registered (i.e. compiled),
    // so an unsupported target fails at build time — not at the first
    // get/set/delete call, which is generic and would otherwise defer the error.
    // Referencing `active_backend` (the enum) rather than `native` (the backend
    // module) is deliberate: it triggers the `@compileError` without pulling the
    // backend's FFI symbols into a build that never calls the API, so a plugin
    // that is registered-but-unused still links nothing extra.
    _ = active_backend;
}

/// Per-context data. Holds no state today, but exists so the plugin's storage
/// API is reachable as `context.plugins.zcli_secrets.<op>(...)` without the
/// command having to import this module.
pub const ContextData = struct {
    /// Retrieve a secret by name. Returns `null` if it was never stored. The
    /// returned bytes are owned by `context.allocator` (the per-command arena),
    /// so they are freed when the command returns; free earlier if desired.
    pub fn get(_: *ContextData, context: anytype, name: []const u8) !?[]const u8 {
        return native.get(context.allocator, context.app_name, name);
    }

    /// Store (or overwrite) a secret. The value is copied; the caller retains
    /// ownership of the passed slice.
    pub fn set(_: *ContextData, context: anytype, name: []const u8, value: []const u8) !void {
        return native.set(context.allocator, context.app_name, name, value);
    }

    /// Remove a secret. A no-op (success) if it does not exist.
    pub fn delete(_: *ContextData, context: anytype, name: []const u8) !void {
        return native.delete(context.allocator, context.app_name, name);
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "plugin exposes the storage surface" {
    try testing.expect(@hasDecl(@This(), "plugin_id"));
    try testing.expect(@hasDecl(@This(), "ContextData"));
    try testing.expect(@hasDecl(ContextData, "get"));
    try testing.expect(@hasDecl(ContextData, "set"));
    try testing.expect(@hasDecl(ContextData, "delete"));
    try testing.expectEqualStrings("zcli_secrets", plugin_id);
}
