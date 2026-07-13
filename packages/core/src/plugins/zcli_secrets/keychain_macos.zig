//! macOS Keychain backend for `zcli_secrets`.
//!
//! Stores each secret as a *generic password* item in the user's login
//! keychain, keyed by `(service = app_name, account = secret name)`. The OS
//! encrypts these at rest and mediates access.
//!
//! ## Why this makes the plugin opt-in
//!
//! These calls live in `Security.framework` (and `CoreFoundation` for
//! `CFRelease`). Linking a framework requires dynamic linking, which would
//! break zcli's static single-binary (libc-free musl) property if forced on
//! every CLI. That is exactly why secrets are a plugin: this backend — and the
//! framework linking it needs — is compiled in *only* when an app registers
//! `zcli_secrets` on macOS (see the plugin's build wiring). A CLI that does not
//! opt in never references these symbols and stays static.
//!
//! ## API choice
//!
//! This uses the classic `SecKeychain*GenericPassword` C API. It is marked
//! deprecated in the macOS SDK in favor of the `SecItem*` / CFDictionary API,
//! but it remains present and functional, and its flat C signatures need no
//! CoreFoundation dictionary marshalling — which keeps this FFI small and
//! auditable. (Zig declares its own `extern` prototypes, so the SDK's
//! deprecation attribute produces no warning here.)

const std = @import("std");

const log = std.log.scoped(.zcli_secrets);

/// Log a failing `OSStatus` (never a secret value) and map it to `KeychainFailure`.
fn keychainFailure(status: OSStatus) Error {
    log.debug("keychain call failed, OSStatus {d}", .{status});
    return Error.KeychainFailure;
}

// ---------------------------------------------------------------------------
// Security.framework / CoreFoundation FFI
// ---------------------------------------------------------------------------

/// `OSStatus` is a signed 32-bit result code. `0` (`errSecSuccess`) is success.
const OSStatus = i32;
const errSecSuccess: OSStatus = 0;
/// Returned by find/delete/update when the requested item does not exist.
const errSecItemNotFound: OSStatus = -25300;
/// Returned by add when an item with the same service+account already exists.
const errSecDuplicateItem: OSStatus = -25299;

/// Opaque `SecKeychainItemRef` (a CoreFoundation type).
const SecKeychainItemRef = ?*anyopaque;

extern "c" fn SecKeychainAddGenericPassword(
    keychain: ?*anyopaque,
    serviceNameLength: u32,
    serviceName: [*]const u8,
    accountNameLength: u32,
    accountName: [*]const u8,
    passwordLength: u32,
    passwordData: [*]const u8,
    itemRef: ?*SecKeychainItemRef,
) callconv(.c) OSStatus;

extern "c" fn SecKeychainFindGenericPassword(
    keychainOrArray: ?*anyopaque,
    serviceNameLength: u32,
    serviceName: [*]const u8,
    accountNameLength: u32,
    accountName: [*]const u8,
    passwordLength: ?*u32,
    passwordData: ?*?*anyopaque,
    itemRef: ?*SecKeychainItemRef,
) callconv(.c) OSStatus;

extern "c" fn SecKeychainItemModifyAttributesAndData(
    itemRef: SecKeychainItemRef,
    attrList: ?*const anyopaque,
    length: u32,
    data: ?*const anyopaque,
) callconv(.c) OSStatus;

extern "c" fn SecKeychainItemDelete(itemRef: SecKeychainItemRef) callconv(.c) OSStatus;

extern "c" fn SecKeychainItemFreeContent(
    attrList: ?*anyopaque,
    data: ?*anyopaque,
) callconv(.c) OSStatus;

extern "c" fn CFRelease(cf: ?*anyopaque) callconv(.c) void;

pub const Error = error{
    /// A Keychain call failed with an unexpected `OSStatus`.
    KeychainFailure,
    /// A secret's byte length exceeds what the Keychain C API can address (u32).
    SecretTooLarge,
};

fn castLen(len: usize) !u32 {
    return std.math.cast(u32, len) orelse Error.SecretTooLarge;
}

/// Retrieve a secret. Returns `null` if no item exists for this service+account.
/// The returned bytes are owned by `allocator` (copied out of the Keychain's
/// own buffer, which is freed before returning).
///
/// `io` and `environ` are part of the uniform backend interface (the Linux
/// backend shells out and needs them); the Keychain FFI does not, so they are
/// ignored here.
pub fn get(allocator: std.mem.Allocator, _: std.Io, _: *const std.process.Environ.Map, service: []const u8, name: []const u8) !?[]const u8 {
    var password_len: u32 = 0;
    var password_data: ?*anyopaque = null;

    const status = SecKeychainFindGenericPassword(
        null,
        try castLen(service.len),
        service.ptr,
        try castLen(name.len),
        name.ptr,
        &password_len,
        &password_data,
        null,
    );
    if (status == errSecItemNotFound) return null;
    if (status != errSecSuccess) return keychainFailure(status);

    defer _ = SecKeychainItemFreeContent(null, password_data);
    // A success with no data pointer is not a documented outcome, but guard it
    // rather than dereference null: treat it as an empty secret.
    const data = password_data orelse return try allocator.dupe(u8, "");
    const src: [*]const u8 = @ptrCast(data);
    return try allocator.dupe(u8, src[0..password_len]);
}

/// Store (or overwrite) a secret. If an item already exists it is updated in
/// place; otherwise a new item is added. The `allocator` is unused here (the
/// Keychain C API is length-based); it is in the signature so every native
/// backend shares one interface.
pub fn set(_: std.mem.Allocator, _: std.Io, _: *const std.process.Environ.Map, service: []const u8, name: []const u8, value: []const u8) !void {
    const value_len = try castLen(value.len);
    const service_len = try castLen(service.len);
    const name_len = try castLen(name.len);

    // Add → (on duplicate) Find → Modify is a read-modify-write with *two* TOCTOU
    // windows against a concurrent `delete`: the item can vanish between our Add
    // and our Find (Find → `errSecItemNotFound`), or between our Find and our
    // Modify (Modify → `errSecItemNotFound`). In both cases the item genuinely no
    // longer exists, so the correct action is simply to Add again, not to fail.
    //
    // Retry the whole Add/Find/Modify cycle on those benign not-found races. Each
    // pass makes forward progress (a fresh Add), and a race only recurs if another
    // writer deletes in our window *again* — independent events, so the loop
    // converges in practice within one or two passes. `max_attempts` is only a
    // livelock backstop against a pathological adversary that manages to delete in
    // our window on every consecutive pass; it is set well above any realistic
    // contention (two CLIs each doing a single op collide at most once) so a benign
    // race never exhausts it and surfaces as a spurious failure.
    const max_attempts = 16;
    var attempts: u8 = 0;
    while (true) : (attempts += 1) {
        const status = SecKeychainAddGenericPassword(
            null,
            service_len,
            service.ptr,
            name_len,
            name.ptr,
            value_len,
            value.ptr,
            null,
        );
        if (status == errSecSuccess) return;
        if (status != errSecDuplicateItem) return keychainFailure(status);

        // Item exists — find it and modify its data in place.
        var item: SecKeychainItemRef = null;
        const find = SecKeychainFindGenericPassword(
            null,
            service_len,
            service.ptr,
            name_len,
            name.ptr,
            null,
            null,
            &item,
        );
        // The item was deleted out from under us between Add and Find; loop to
        // re-Add rather than surface an opaque failure for a benign race.
        if (find == errSecItemNotFound) {
            if (attempts < max_attempts) continue;
            return keychainFailure(find);
        }
        if (find != errSecSuccess) return keychainFailure(find);
        defer CFRelease(item);

        const modify = SecKeychainItemModifyAttributesAndData(item, null, value_len, value.ptr);
        if (modify == errSecSuccess) return;
        // Same benign race, one window later: the item was deleted between our
        // Find and this Modify. Loop to re-Add rather than fail. (`item` is still
        // released by the `defer` above as this iteration's scope exits.)
        if (modify == errSecItemNotFound and attempts < max_attempts) continue;
        return keychainFailure(modify);
    }
}

/// Remove a secret. Succeeds (no-op) if no item exists. `allocator` is unused
/// (see `set`), present for interface parity across native backends.
pub fn delete(_: std.mem.Allocator, _: std.Io, _: *const std.process.Environ.Map, service: []const u8, name: []const u8) !void {
    var item: SecKeychainItemRef = null;
    const find = SecKeychainFindGenericPassword(
        null,
        try castLen(service.len),
        service.ptr,
        try castLen(name.len),
        name.ptr,
        null,
        null,
        &item,
    );
    if (find == errSecItemNotFound) return;
    if (find != errSecSuccess) return keychainFailure(find);
    defer CFRelease(item);

    const status = SecKeychainItemDelete(item);
    if (status == errSecSuccess) return;
    // Find→Delete has the mirror of `set`'s TOCTOU: the item can be removed
    // (by a concurrent `delete`, or a `set` that re-Added over it) between our
    // Find and this Delete, so Delete returns `errSecItemNotFound`. The caller
    // asked for the item to be gone and it is — that is success, not a failure.
    if (status == errSecItemNotFound) return;
    return keychainFailure(status);
}

test "keychain backend compiles and links against Security.framework" {
    // Taking the address of these concrete functions forces them to be
    // analyzed and codegen'd, so this test only passes when the exe links
    // Security/CoreFoundation — that is the link-time half of the portability
    // guarantee. The functions are NOT called: a real round-trip would mutate
    // the developer's login keychain (and may prompt), so functional coverage
    // is done manually, not in the unit suite.
    _ = &get;
    _ = &set;
    _ = &delete;
}
