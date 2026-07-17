//! Windows Credential Manager backend for `zcli_secrets`, via `advapi32`.
//!
//! Stores each secret as a generic credential (`CRED_TYPE_GENERIC`) in the
//! current user's credential set, keyed by a target name of `service:account`.
//! The OS protects the blob at rest under the user's login (DPAPI).
//!
//! ## Why this makes the plugin opt-in
//!
//! The `Cred*W` functions live in `advapi32`. Even though Zig bundles the
//! import library, this backend is compiled in only when an app registers
//! `zcli_secrets` on Windows — a CLI that does not opt in never references these
//! symbols. Unlike the macOS/Linux keychains, the credential store is always
//! available for the logged-in user with no daemon, so this backend round-trips
//! in CI directly.
//!
//! The credential blob is length-based (`CredentialBlobSize`), so arbitrary
//! bytes are stored as-is — no base64 needed here.

const std = @import("std");
const windows = std.os.windows;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;

const FILETIME = extern struct {
    dwLowDateTime: DWORD = 0,
    dwHighDateTime: DWORD = 0,
};

/// `CREDENTIALW` (wincred.h). Field order/types must match the OS struct.
const CREDENTIALW = extern struct {
    Flags: DWORD = 0,
    Type: DWORD = 0,
    TargetName: ?[*:0]const u16 = null,
    Comment: ?[*:0]const u16 = null,
    LastWritten: FILETIME = .{},
    CredentialBlobSize: DWORD = 0,
    CredentialBlob: ?[*]u8 = null,
    Persist: DWORD = 0,
    AttributeCount: DWORD = 0,
    Attributes: ?*anyopaque = null,
    TargetAlias: ?[*:0]const u16 = null,
    UserName: ?[*:0]const u16 = null,
};

const CRED_TYPE_GENERIC: DWORD = 1;
const CRED_PERSIST_LOCAL_MACHINE: DWORD = 2;
/// `CRED_MAX_CREDENTIAL_BLOB_SIZE` — 5 * 512 bytes.
const CRED_MAX_CREDENTIAL_BLOB_SIZE: usize = 5 * 512;

extern "advapi32" fn CredWriteW(cred: *const CREDENTIALW, flags: DWORD) callconv(.winapi) BOOL;
extern "advapi32" fn CredReadW(target: [*:0]const u16, typ: DWORD, flags: DWORD, cred: *?*CREDENTIALW) callconv(.winapi) BOOL;
extern "advapi32" fn CredDeleteW(target: [*:0]const u16, typ: DWORD, flags: DWORD) callconv(.winapi) BOOL;
extern "advapi32" fn CredFree(buffer: *anyopaque) callconv(.winapi) void;

pub const Error = error{
    /// A `Cred*W` call failed for a reason other than "not found".
    CredentialManagerFailure,
    /// The value exceeds `CRED_MAX_CREDENTIAL_BLOB_SIZE`.
    SecretTooLarge,
};

const log = std.log.scoped(.zcli_secrets);

/// Log the last Win32 error (never a secret value) and map it to a failure.
fn credentialFailure() Error {
    log.debug("credential manager call failed, Win32 error {d}", .{@intFromEnum(windows.GetLastError())});
    return Error.CredentialManagerFailure;
}

/// Build the UTF-8 target name as a length-prefixed encoding of `(service,
/// name)`: `"<len(service)>:<service>:<name>"`. The leading count makes the
/// split point unambiguous, so distinct pairs never collide — a plain
/// `"service:name"` would let `("a:b","c")` and `("a","b:c")` share one entry.
/// Caller owns the result.
fn encodeTarget(allocator: std.mem.Allocator, service: []const u8, name: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{d}:{s}:{s}", .{ service.len, service, name });
}

/// Build the UTF-16, NUL-terminated Credential Manager target name.
fn makeTarget(allocator: std.mem.Allocator, service: []const u8, name: []const u8) ![:0]u16 {
    const utf8 = try encodeTarget(allocator, service, name);
    defer allocator.free(utf8);
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, utf8) catch |err| switch (err) {
        error.InvalidUtf8 => return Error.CredentialManagerFailure,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

/// Retrieve a secret. Returns `null` if no matching credential exists. The
/// returned bytes are owned by `allocator`.
///
/// `io` and `environ` are part of the uniform backend interface (the Linux
/// backend shells out and needs them); the Credential Manager FFI does not, so
/// they are ignored here.
pub fn get(allocator: std.mem.Allocator, _: std.Io, _: *const std.process.Environ.Map, service: []const u8, name: []const u8) !?[]const u8 {
    const target = try makeTarget(allocator, service, name);
    defer allocator.free(target);

    var cred: ?*CREDENTIALW = null;
    if (!CredReadW(target.ptr, CRED_TYPE_GENERIC, 0, &cred).toBool()) {
        if (windows.GetLastError() == windows.Win32Error.NOT_FOUND) return null;
        return credentialFailure();
    }
    const c = cred.?;
    defer CredFree(c);

    const blob = c.CredentialBlob orelse return try allocator.dupe(u8, "");
    const plaintext = blob[0..c.CredentialBlobSize];
    // Wipe the OS-heap plaintext before CredFree hands the buffer back to the
    // heap — otherwise a copy of the secret lingers in freed memory (recoverable
    // via core dump, attached debugger, or heap reuse). `secureZero` uses
    // volatile writes so the compiler cannot elide it. Registered after the
    // `CredFree` defer so it runs first (LIFO): wipe, then free.
    defer std.crypto.secureZero(u8, plaintext);
    return try allocator.dupe(u8, plaintext);
}

/// Store (or overwrite) a secret. `CredWriteW` overwrites an existing
/// credential with the same target, so no separate update path is needed.
pub fn set(allocator: std.mem.Allocator, _: std.Io, _: *const std.process.Environ.Map, service: []const u8, name: []const u8, value: []const u8) !void {
    if (value.len > CRED_MAX_CREDENTIAL_BLOB_SIZE) return Error.SecretTooLarge;

    const target = try makeTarget(allocator, service, name);
    defer allocator.free(target);
    const user = try std.unicode.utf8ToUtf16LeAllocZ(allocator, name);
    defer allocator.free(user);

    const cred = CREDENTIALW{
        .Type = CRED_TYPE_GENERIC,
        .TargetName = target.ptr,
        .CredentialBlobSize = @intCast(value.len),
        // CredWriteW takes a *const credential and does not modify the blob.
        .CredentialBlob = @constCast(value.ptr),
        // Persists across this user's logon sessions on this machine (still
        // per-user, not shared between users) — not roamed like ENTERPRISE.
        .Persist = CRED_PERSIST_LOCAL_MACHINE,
        .UserName = user.ptr,
    };
    if (!CredWriteW(&cred, 0).toBool()) return credentialFailure();
}

/// Remove a secret. Succeeds (no-op) if no matching credential exists.
pub fn delete(allocator: std.mem.Allocator, _: std.Io, _: *const std.process.Environ.Map, service: []const u8, name: []const u8) !void {
    const target = try makeTarget(allocator, service, name);
    defer allocator.free(target);

    if (!CredDeleteW(target.ptr, CRED_TYPE_GENERIC, 0).toBool()) {
        if (windows.GetLastError() == windows.Win32Error.NOT_FOUND) return; // no-op
        return credentialFailure();
    }
}

test "credential manager backend compiles and links against advapi32" {
    // Forces the functions to be analyzed and linked (the link-time half of the
    // guarantee). A live round-trip runs in CI via secrets_live_test.zig.
    _ = &get;
    _ = &set;
    _ = &delete;
}

test "encodeTarget length-prefix disambiguates the service/name split" {
    const a = std.testing.allocator;

    const t1 = try encodeTarget(a, "a:b", "c");
    defer a.free(t1);
    const t2 = try encodeTarget(a, "a", "b:c");
    defer a.free(t2);

    // The classic flattening `"a:b:c"` collides for both pairs; the length
    // prefix makes them distinct.
    try std.testing.expect(!std.mem.eql(u8, t1, t2));
    try std.testing.expectEqualStrings("3:a:b:c", t1);
    try std.testing.expectEqualStrings("1:a:b:c", t2);

    // An empty service or name is still unambiguous.
    const t3 = try encodeTarget(a, "", "token");
    defer a.free(t3);
    try std.testing.expectEqualStrings("0::token", t3);
}
