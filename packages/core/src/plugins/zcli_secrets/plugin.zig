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
//! The backend is chosen at compile time from the target OS. Registering the
//! plugin is what pulls in that platform's native-library linking; a CLI that
//! never registers it stays static.
//!
//! - **macOS** → the OS Keychain (`keychain_macos.zig`; `Security` +
//!   `CoreFoundation`).
//! - **Linux** → the Secret Service via libsecret (`secret_service_linux.zig`;
//!   `libsecret-1` + glib, over D-Bus).
//! - **Windows** → the Credential Manager (`credential_manager_windows.zig`;
//!   `advapi32`).
//! - **any other target** → the documented file-backed fallback
//!   (`file_store.zig`): pure Zig, no dynamic linking, so the app stays static.
//!   Secrets are stored `0600` in the app's XDG data dir, in plaintext (perms
//!   are the only protection — see `file_store.zig`).
//!
//! The file backend's tests run on every platform, so the fallback stays
//! covered even where it is not the default.
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

const file_store = @import("file_store.zig");

pub const plugin_id = "zcli_secrets";

/// Which backend the target OS uses. `.file` is the portable pure-Zig fallback;
/// the others are native OS keychains that require dynamic linking.
const Backend = enum { keychain, secret_service, credential_manager, file };

const active_backend: Backend = switch (builtin.os.tag) {
    .macos => .keychain,
    .linux => .secret_service,
    .windows => .credential_manager,
    else => .file,
};

/// The native backend module for this target (unused when `active_backend` is
/// `.file`). Only the selected switch prong is evaluated at compile time, so a
/// non-native target never imports — or links — a keychain backend.
const native = switch (active_backend) {
    .keychain => @import("keychain_macos.zig"),
    .secret_service => @import("secret_service_linux.zig"),
    .credential_manager => @import("credential_manager_windows.zig"),
    .file => struct {},
};

/// Per-context data. Holds no state today, but exists so the plugin's storage
/// API is reachable as `context.plugins.zcli_secrets.<op>(...)` without the
/// command having to import this module.
pub const ContextData = struct {
    /// Retrieve a secret by name. Returns `null` if it was never stored. The
    /// returned bytes are owned by `context.allocator` (the per-command arena),
    /// so they are freed when the command returns; free earlier if desired.
    pub fn get(_: *ContextData, context: anytype, name: []const u8) !?[]const u8 {
        if (active_backend == .file) {
            var dir = try openStoreDir(context);
            defer dir.close(context.io.io);
            return file_store.get(context.io.io, context.allocator, dir, name);
        }
        return native.get(context.allocator, context.app_name, name);
    }

    /// Store (or overwrite) a secret. The value is copied; the caller retains
    /// ownership of the passed slice.
    pub fn set(_: *ContextData, context: anytype, name: []const u8, value: []const u8) !void {
        if (active_backend == .file) {
            var dir = try openStoreDir(context);
            defer dir.close(context.io.io);
            return file_store.set(context.io.io, context.allocator, dir, name, value);
        }
        return native.set(context.allocator, context.app_name, name, value);
    }

    /// Remove a secret. A no-op (success) if it does not exist.
    pub fn delete(_: *ContextData, context: anytype, name: []const u8) !void {
        if (active_backend == .file) {
            var dir = try openStoreDir(context);
            defer dir.close(context.io.io);
            return file_store.delete(context.io.io, context.allocator, dir, name);
        }
        return native.delete(context.allocator, context.app_name, name);
    }
};

/// Resolve, create (`0700`), and open the file-backed store directory for the
/// app: `$XDG_DATA_HOME/{app}` (falling back to `$HOME/.local/share/{app}`).
/// Only used by the file backend.
fn openStoreDir(context: anytype) !std.Io.Dir {
    const io = context.io.io;
    const allocator = context.allocator;

    const rel = try storeDirPath(allocator, context.environ, context.app_name);
    defer allocator.free(rel);

    const cwd = std.Io.Dir.cwd();
    _ = try cwd.createDirPathStatus(io, rel, std.Io.File.Permissions.fromMode(0o700));
    var dir = try cwd.openDir(io, rel, .{});
    errdefer dir.close(io);
    // Force 0700 even if the directory already existed loose — XDG data dirs are
    // commonly created 0755 by other tools, and createDirPathStatus leaves an
    // existing directory's mode untouched.
    try dir.setPermissions(io, std.Io.File.Permissions.fromMode(0o700));
    return dir;
}

pub const PathError = error{
    /// Neither `$XDG_DATA_HOME` nor `$HOME` is set, so no store location can be
    /// determined.
    NoHomeDirectory,
};

/// Compute the store directory path from the environment. Pure (no I/O) so it
/// can be unit-tested. Caller owns the returned path.
fn storeDirPath(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    app_name: []const u8,
) ![]u8 {
    if (environ.get("XDG_DATA_HOME")) |xdg| {
        if (xdg.len > 0) return std.fmt.allocPrint(allocator, "{s}/{s}", .{ xdg, app_name });
    }
    const home = environ.get("HOME") orelse return PathError.NoHomeDirectory;
    return std.fmt.allocPrint(allocator, "{s}/.local/share/{s}", .{ home, app_name });
}

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

test "storeDirPath prefers XDG_DATA_HOME" {
    const allocator = testing.allocator;
    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", "/data");
    try env.put("HOME", "/home/user");

    const path = try storeDirPath(allocator, &env, "myapp");
    defer allocator.free(path);
    try testing.expectEqualStrings("/data/myapp", path);
}

test "storeDirPath falls back to HOME/.local/share" {
    const allocator = testing.allocator;
    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/user");

    const path = try storeDirPath(allocator, &env, "myapp");
    defer allocator.free(path);
    try testing.expectEqualStrings("/home/user/.local/share/myapp", path);
}

test "storeDirPath errors when no home is set" {
    const allocator = testing.allocator;
    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();
    try testing.expectError(PathError.NoHomeDirectory, storeDirPath(allocator, &env, "myapp"));
}

test "storeDirPath ignores an empty XDG_DATA_HOME" {
    const allocator = testing.allocator;
    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", "");
    try env.put("HOME", "/home/user");

    const path = try storeDirPath(allocator, &env, "myapp");
    defer allocator.free(path);
    try testing.expectEqualStrings("/home/user/.local/share/myapp", path);
}

// Keep the file-backed store's tests in the compiled set even on macOS (where
// the plugin selects the keychain), so `set`/`get`/`delete` round-trips are
// always exercised.
test {
    testing.refAllDecls(file_store);
}
