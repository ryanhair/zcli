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
//! A real secure store needs platform machinery that would otherwise burden
//! *every* CLI: macOS and Windows dynamically link a system library
//! (`Security.framework`, `advapi32`), and Linux shells out to a helper binary
//! at runtime. Forcing any of that on CLIs that never store a secret would
//! compromise zcli's static single-binary (libc-free musl) property. So this
//! ships as an opt-in plugin: the cost is paid only by apps that register it.
//! A CLI that never registers `zcli_secrets` stays fully static.
//!
//! ## Backend selection
//!
//! The backend is a real secure store, chosen at compile time from the target
//! OS. Registering the plugin is what pulls in that platform's machinery.
//!
//! - **macOS** → the OS Keychain (`keychain_macos.zig`; `Security` +
//!   `CoreFoundation`).
//! - **Linux** → the Secret Service (via `secret-tool`) or `pass`, selected at
//!   *runtime* (`linux.zig`). It shells out rather than linking libsecret, so
//!   Linux secrets no longer break a musl build, and `pass` covers headless
//!   environments the Secret Service can't. See ADR-0010.
//! - **Windows** → the Credential Manager (`credential_manager_windows.zig`;
//!   `advapi32`).
//!
//! There is deliberately **no fallback**. Credentials belong in an encrypted
//! store, not a plaintext file; so registering this plugin for any other target
//! is a **compile-time error** rather than a silent, insecure store.
//!
//! ## Uniform cross-platform contract
//!
//! Every backend fails through **one** shared error set (`Error`), so command
//! code writes the same handling on every OS instead of catching a per-backend
//! taxonomy (`KeychainFailure` vs `CredentialManagerFailure` vs …). The public
//! surface is:
//!
//! - `InvalidSecretName` — the `name` is not valid UTF-8, or contains a NUL.
//!   Validated up front (see below), before any backend is touched.
//! - `SecretTooLarge` — the value exceeds what the backend can store.
//! - `BackendUnavailable` — no usable secure store on this system (Linux only:
//!   no Secret Service and no initialized `pass`; or a bad `ZCLI_SECRETS_BACKEND`
//!   override).
//! - `BackendFailure` — the store rejected the operation for some other reason.
//! - `OutOfMemory` — allocation failed.
//!
//! A *missing* key is never an error: `get` returns `null`, `delete` is a no-op.
//!
//! ## Key and value constraints
//!
//! A secret `name` is validated **once, here**, before any backend call, so a
//! name either works on every OS or is rejected on every OS:
//!
//! - It must be valid UTF-8. Windows stores the target name as UTF-16, so an
//!   invalid-UTF-8 name that "works" on macOS/Linux would fail only on Windows;
//!   requiring UTF-8 up front makes the contract uniform.
//! - It must not contain a NUL byte — the macOS/Linux backends key on C strings,
//!   where an embedded NUL silently truncates the key. (A NUL is also invalid
//!   UTF-16 target material.)
//!
//! Beyond the name: on **Windows** a value is capped at
//! `CRED_MAX_CREDENTIAL_BLOB_SIZE` (2560 bytes) and fails with `SecretTooLarge`
//! above it (macOS/Linux have no such practical cap). The Windows credential is
//! keyed by an unambiguous length-prefixed encoding of `(app_name, name)`, so
//! distinct app/name pairs never collide.
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

/// Which secure store backend this target uses.
const Backend = enum { keychain, linux, credential_manager };

const active_backend: Backend = switch (builtin.os.tag) {
    .macos => .keychain,
    .linux => .linux,
    .windows => .credential_manager,
    else => @compileError(
        "zcli_secrets has no secure keychain backend for this target OS (" ++
            @tagName(builtin.os.tag) ++
            "). Supported: macOS (Keychain), Linux (Secret Service or pass), " ++
            "Windows (Credential Manager). Credentials are not stored in a " ++
            "plaintext file fallback — remove the plugin for this target, or add " ++
            "a keychain backend for it.",
    ),
};

/// The native backend module for this target. Only the selected switch prong is
/// evaluated at compile time, so a build never imports a backend for another OS.
/// The Linux backend is a runtime dispatcher over Secret Service / `pass`; macOS
/// and Windows are direct keychain FFI.
const native = switch (active_backend) {
    .keychain => @import("keychain_macos.zig"),
    .linux => @import("linux.zig"),
    .credential_manager => @import("credential_manager_windows.zig"),
};

comptime {
    // Force backend *selection* when the plugin is registered (i.e. compiled),
    // so an unsupported target fails at build time — not at the first
    // get/set/delete call, which is generic and would otherwise defer the error.
    // Referencing `active_backend` (the enum) rather than `native` (the backend
    // module) is deliberate: it triggers the `@compileError` without pulling the
    // backend's FFI *symbols* into the codegen of a build that never calls the
    // API. (The keychain library itself is still linked by the build half —
    // `main.linkSecretsBackend` — whenever the plugin is registered; this only
    // keeps unused API symbols out of a plain `zig build test`.)
    _ = active_backend;
}

/// The single, backend-agnostic error set every `get`/`set`/`delete` maps into.
/// Command code catches these on every OS — see the module doc.
pub const Error = error{
    /// A secret name is not valid UTF-8, or contains a NUL byte. Rejected up
    /// front, before any backend call.
    InvalidSecretName,
    /// The value exceeds what the active backend can store.
    SecretTooLarge,
    /// No usable secure store is available (Linux: no Secret Service and no
    /// initialized `pass`; or an unrecognized `ZCLI_SECRETS_BACKEND` override).
    BackendUnavailable,
    /// The store rejected the operation for a reason other than a missing key.
    BackendFailure,
    /// Allocation failed.
    OutOfMemory,
};

fn validateName(name: []const u8) Error!void {
    if (std.mem.indexOfScalar(u8, name, 0) != null) return Error.InvalidSecretName;
    if (!std.unicode.utf8ValidateSlice(name)) return Error.InvalidSecretName;
}

/// Collapse whatever a native backend raised into the shared `Error` set. Each
/// backend's own error names map to a uniform meaning; `OutOfMemory` is never
/// masked. Callers own any returned value; this only touches the error channel.
fn mapBackendError(e: anyerror) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.SecretTooLarge => error.SecretTooLarge,
        // Linux runtime-selection failures (no store / bad override), and a
        // Secret Service that turned out to be unreachable with no `pass` to
        // fall through to.
        error.SecretBackendUnavailable,
        error.InvalidBackendOverride,
        error.ServiceUnavailable,
        => error.BackendUnavailable,
        // Every backend's "the store call failed" variant.
        error.KeychainFailure,
        error.CredentialManagerFailure,
        error.SecretBackendFailure,
        => error.BackendFailure,
        // Anything unforeseen (e.g. a decode error surfaced raw) is still a
        // backend failure to the caller — never a silent success.
        else => error.BackendFailure,
    };
}

/// Per-context data. Holds no state today, but exists so the plugin's storage
/// API is reachable as `context.plugins.zcli_secrets.<op>(...)` without the
/// command having to import this module.
pub const ContextData = struct {
    /// Retrieve a secret by name. Returns `null` if it was never stored. The
    /// returned bytes are owned by `context.allocator` (the per-command arena),
    /// so they are freed when the command returns; free earlier if desired.
    pub fn get(_: *ContextData, context: anytype, name: []const u8) Error!?[]const u8 {
        try validateName(name);
        return native.get(context.allocator, context.io, context.environ, context.app_name, name) catch |e|
            return mapBackendError(e);
    }

    /// Store (or overwrite) a secret. The value is copied; the caller retains
    /// ownership of the passed slice.
    pub fn set(_: *ContextData, context: anytype, name: []const u8, value: []const u8) Error!void {
        try validateName(name);
        return native.set(context.allocator, context.io, context.environ, context.app_name, name, value) catch |e|
            return mapBackendError(e);
    }

    /// Remove a secret. A no-op (success) if it does not exist.
    pub fn delete(_: *ContextData, context: anytype, name: []const u8) Error!void {
        try validateName(name);
        return native.delete(context.allocator, context.io, context.environ, context.app_name, name) catch |e|
            return mapBackendError(e);
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

test "validateName rejects an embedded NUL and invalid UTF-8" {
    try validateName("token"); // ok
    try validateName(""); // ok (empty is a valid, if odd, key)
    try validateName("café/ключ/名前"); // multibyte UTF-8 is fine
    try testing.expectError(Error.InvalidSecretName, validateName("to\x00ken"));
    // A lone continuation byte is not valid UTF-8 — rejected on every OS rather
    // than working on macOS/Linux and failing only on Windows's UTF-16 store.
    try testing.expectError(Error.InvalidSecretName, validateName("bad\xffname"));
    try testing.expectError(Error.InvalidSecretName, validateName(&[_]u8{0x80}));
}

test "mapBackendError collapses every backend taxonomy into the shared set" {
    try testing.expectEqual(Error.OutOfMemory, mapBackendError(error.OutOfMemory));
    try testing.expectEqual(Error.SecretTooLarge, mapBackendError(error.SecretTooLarge));
    try testing.expectEqual(Error.BackendUnavailable, mapBackendError(error.SecretBackendUnavailable));
    try testing.expectEqual(Error.BackendUnavailable, mapBackendError(error.InvalidBackendOverride));
    try testing.expectEqual(Error.BackendFailure, mapBackendError(error.KeychainFailure));
    try testing.expectEqual(Error.BackendFailure, mapBackendError(error.CredentialManagerFailure));
    try testing.expectEqual(Error.BackendFailure, mapBackendError(error.SecretBackendFailure));
    // An unforeseen error still surfaces as a failure, never a silent success.
    try testing.expectEqual(Error.BackendFailure, mapBackendError(error.InvalidBase64));
}
