//! macOS Keychain backend for `zcli_secrets`.
//!
//! Stores each secret as a *generic password* item in the user's login
//! keychain, keyed by `(service = app_name, account = secret name)`. The OS
//! encrypts these at rest and mediates access.
//!
//! ## Why this makes the plugin opt-in
//!
//! These calls live in `Security.framework` (and `CoreFoundation` for the
//! CoreFoundation object graph and `CFRelease`). Linking a framework requires
//! dynamic linking, which would break zcli's static single-binary (libc-free
//! musl) property if forced on every CLI. That is exactly why secrets are a
//! plugin: this backend — and the framework linking it needs — is compiled in
//! *only* when an app registers `zcli_secrets` on macOS (see the plugin's build
//! wiring). A CLI that does not opt in never references these symbols and stays
//! static.
//!
//! ## API choice
//!
//! This uses the modern `SecItem*` / CFDictionary API
//! (`SecItemAdd`/`SecItemCopyMatching`/`SecItemUpdate`/`SecItemDelete`) with
//! `kSecClassGenericPassword`. The item attributes (`kSecAttrService` /
//! `kSecAttrAccount`) map 1:1 onto the `(service, account)` key scheme the older
//! `SecKeychain*GenericPassword` C API used, so a secret written by a prior zcli
//! build remains readable after this migration. The classic `SecKeychain*` API
//! this replaced was deprecated in the macOS SDK (since macOS 12) in favor of
//! exactly these `SecItem*` calls.
//!
//! The `SecItem*` API is CFDictionary-based, so every call marshals a small
//! CoreFoundation dictionary of typed attributes rather than a flat C argument
//! list. Zig declares its own `extern` prototypes for the handful of symbols
//! used, so the SDK's deprecation attributes are irrelevant here (there were
//! none to begin with on the new API).

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
/// Returned by copy-matching/update/delete when the requested item does not exist.
const errSecItemNotFound: OSStatus = -25300;
/// Returned by add when an item with the same service+account already exists.
const errSecDuplicateItem: OSStatus = -25299;

// CoreFoundation object references. Each `CF*Ref` is an opaque pointer; the
// immutable ones are `const`, the mutable dictionary is not. `CFTypeRef` is the
// generic supertype every CF object coerces to.
const CFTypeRef = ?*const anyopaque;
const CFAllocatorRef = ?*const anyopaque;
const CFStringRef = ?*const anyopaque;
const CFDataRef = ?*const anyopaque;
const CFBooleanRef = ?*const anyopaque;
const CFDictionaryRef = ?*const anyopaque;
const CFMutableDictionaryRef = ?*anyopaque;

/// `CFIndex` is CoreFoundation's signed size type (`signed long` → `isize`).
const CFIndex = isize;
/// `CFStringEncoding`; `0x08000100` is `kCFStringEncodingUTF8`.
const CFStringEncoding = u32;
const kCFStringEncodingUTF8: CFStringEncoding = 0x08000100;

/// The default CoreFoundation allocator is a null `CFAllocatorRef`.
const kCFAllocatorDefault: CFAllocatorRef = null;

// The dictionary key/value callback tables are opaque structs; we only ever need
// their addresses. `kCFTypeDictionaryKeyCallBacks` / `...ValueCallBacks` make the
// dictionary retain/release + hash/equal its CF-object keys and values, which is
// what lets us release the strings/data we insert while the dictionary keeps them
// alive for the duration of the call.
const CFDictionaryKeyCallBacks = opaque {};
const CFDictionaryValueCallBacks = opaque {};
extern "c" const kCFTypeDictionaryKeyCallBacks: CFDictionaryKeyCallBacks;
extern "c" const kCFTypeDictionaryValueCallBacks: CFDictionaryValueCallBacks;

// Boolean singleton used for the `kSecReturnData` query flag.
extern "c" const kCFBooleanTrue: CFBooleanRef;

// Security.framework attribute keys (all `CFStringRef` globals). These identify
// the fields of the query/attribute dictionaries we build.
extern "c" const kSecClass: CFStringRef;
extern "c" const kSecClassGenericPassword: CFStringRef;
extern "c" const kSecAttrService: CFStringRef;
extern "c" const kSecAttrAccount: CFStringRef;
extern "c" const kSecValueData: CFStringRef;
extern "c" const kSecReturnData: CFStringRef;
extern "c" const kSecMatchLimit: CFStringRef;
extern "c" const kSecMatchLimitOne: CFStringRef;

extern "c" fn CFStringCreateWithBytes(
    alloc: CFAllocatorRef,
    bytes: [*]const u8,
    numBytes: CFIndex,
    encoding: CFStringEncoding,
    isExternalRepresentation: u8,
) callconv(.c) CFStringRef;

extern "c" fn CFDataCreate(
    alloc: CFAllocatorRef,
    bytes: [*]const u8,
    length: CFIndex,
) callconv(.c) CFDataRef;

extern "c" fn CFDataGetBytePtr(data: CFDataRef) callconv(.c) ?[*]const u8;
extern "c" fn CFDataGetLength(data: CFDataRef) callconv(.c) CFIndex;

extern "c" fn CFDictionaryCreateMutable(
    allocator: CFAllocatorRef,
    capacity: CFIndex,
    keyCallBacks: ?*const CFDictionaryKeyCallBacks,
    valueCallBacks: ?*const CFDictionaryValueCallBacks,
) callconv(.c) CFMutableDictionaryRef;

extern "c" fn CFDictionaryAddValue(
    theDict: CFMutableDictionaryRef,
    key: ?*const anyopaque,
    value: ?*const anyopaque,
) callconv(.c) void;

extern "c" fn CFRelease(cf: CFTypeRef) callconv(.c) void;

extern "c" fn SecItemAdd(attributes: CFDictionaryRef, result: ?*CFTypeRef) callconv(.c) OSStatus;
extern "c" fn SecItemCopyMatching(query: CFDictionaryRef, result: ?*CFTypeRef) callconv(.c) OSStatus;
extern "c" fn SecItemUpdate(query: CFDictionaryRef, attributesToUpdate: CFDictionaryRef) callconv(.c) OSStatus;
extern "c" fn SecItemDelete(query: CFDictionaryRef) callconv(.c) OSStatus;

pub const Error = error{
    /// A Keychain call failed with an unexpected `OSStatus`, or a CoreFoundation
    /// object could not be created.
    KeychainFailure,
};

/// Build a UTF-8 `CFString` from a byte slice. Caller owns the result and must
/// `CFRelease` it (or hand it to a dictionary that retains it).
fn cfString(bytes: []const u8) Error!CFStringRef {
    // `isExternalRepresentation = 0`: the bytes are interpreted in the given
    // encoding, not as a BOM-prefixed external form.
    return CFStringCreateWithBytes(kCFAllocatorDefault, bytes.ptr, @intCast(bytes.len), kCFStringEncodingUTF8, 0) orelse
        Error.KeychainFailure;
}

/// Wrap secret bytes in a `CFData`. CoreFoundation copies the bytes into its own
/// buffer; the caller's `bytes` slice is never mutated and never reaches argv (it
/// travels only through this in-memory CF object). Caller owns the result and
/// must `CFRelease` it.
fn cfData(bytes: []const u8) Error!CFDataRef {
    return CFDataCreate(kCFAllocatorDefault, bytes.ptr, @intCast(bytes.len)) orelse
        Error.KeychainFailure;
}

/// Create a fresh mutable CF dictionary that retains/releases its CF-object keys
/// and values. Caller owns it and must `CFRelease` it.
fn newDict() Error!CFMutableDictionaryRef {
    return CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks,
    ) orelse Error.KeychainFailure;
}

/// Build the base query dictionary that identifies a single generic-password
/// item by `(service, account)`. Caller owns the returned dictionary and must
/// `CFRelease` it. The dictionary retains the strings, so they are released here.
fn baseQuery(service: []const u8, name: []const u8) Error!CFMutableDictionaryRef {
    const svc = try cfString(service);
    defer CFRelease(svc);
    const acc = try cfString(name);
    defer CFRelease(acc);

    const dict = try newDict();
    errdefer CFRelease(dict);
    CFDictionaryAddValue(dict, kSecClass, kSecClassGenericPassword);
    CFDictionaryAddValue(dict, kSecAttrService, svc);
    CFDictionaryAddValue(dict, kSecAttrAccount, acc);
    return dict;
}

/// Retrieve a secret. Returns `null` if no item exists for this service+account.
/// The returned bytes are owned by `allocator` (copied out of the CoreFoundation
/// `CFData`, which is released before returning).
///
/// `io` and `environ` are part of the uniform backend interface (the Linux
/// backend shells out and needs them); the Keychain FFI does not, so they are
/// ignored here.
pub fn get(allocator: std.mem.Allocator, _: std.Io, _: *const std.process.Environ.Map, service: []const u8, name: []const u8) !?[]const u8 {
    const query = try baseQuery(service, name);
    defer CFRelease(query);
    // Ask for the raw secret bytes back, and cap the match to a single item.
    CFDictionaryAddValue(query, kSecReturnData, kCFBooleanTrue);
    CFDictionaryAddValue(query, kSecMatchLimit, kSecMatchLimitOne);

    var result: CFTypeRef = null;
    const status = SecItemCopyMatching(query, &result);
    if (status == errSecItemNotFound) return null;
    if (status != errSecSuccess) return keychainFailure(status);

    // Success with `kSecReturnData` yields a `CFData`. A success with no object
    // is not a documented outcome, but guard it rather than dereference null:
    // treat it as an empty secret.
    const data: CFDataRef = result orelse return try allocator.dupe(u8, "");
    defer CFRelease(data);

    const len: usize = @intCast(CFDataGetLength(data));
    if (len == 0) return try allocator.dupe(u8, "");
    const ptr = CFDataGetBytePtr(data) orelse return try allocator.dupe(u8, "");
    return try allocator.dupe(u8, ptr[0..len]);
}

/// Store (or overwrite) a secret. If an item already exists it is updated in
/// place; otherwise a new item is added. The `allocator` is unused here (the
/// secret bytes are handed to CoreFoundation directly); it is in the signature so
/// every native backend shares one interface.
pub fn set(_: std.mem.Allocator, _: std.Io, _: *const std.process.Environ.Map, service: []const u8, name: []const u8, value: []const u8) !void {
    // Add → (on duplicate) Update is a read-modify-write racing a concurrent
    // `delete`, and both `SecItem*` calls can surface that race as
    // `errSecItemNotFound`:
    //
    //   - our Add races a Delete on the same item and securityd returns
    //     `errSecItemNotFound` instead of adding (an Add is never *legitimately*
    //     "not found" — it just means the store was mid-mutation, so try again);
    //   - the item vanishes between an `errSecDuplicateItem` Add and our Update,
    //     so the Update reports `errSecItemNotFound`.
    //
    // In every case the item genuinely does not exist at that instant, so the
    // correct action is to Add again, not to fail. Retry the whole Add/Update
    // cycle on those benign not-found races. Each pass makes forward progress (a
    // fresh Add), and a race only recurs if another writer mutates in our window
    // *again* — independent events, so the loop converges in practice within one
    // or two passes. `max_attempts` is only a livelock backstop against a
    // pathological adversary that manages to delete in our window on every
    // consecutive pass; it is set well above any realistic contention (two CLIs
    // each doing a single op collide at most once) so a benign race never exhausts
    // it and surfaces as a spurious failure.
    const max_attempts = 16;
    var attempts: u8 = 0;
    while (true) : (attempts += 1) {
        // Attempt to add a brand-new item carrying the secret value.
        const add_query = try baseQuery(service, name);
        defer CFRelease(add_query);
        const add_value = try cfData(value);
        defer CFRelease(add_value);
        CFDictionaryAddValue(add_query, kSecValueData, add_value);

        const status = SecItemAdd(add_query, null);
        if (status == errSecSuccess) return;
        // Add lost a race with a concurrent delete — loop to re-Add.
        if (status == errSecItemNotFound and attempts < max_attempts) continue;
        if (status != errSecDuplicateItem) return keychainFailure(status);

        // Item exists. An *empty* value cannot be written with SecItemUpdate:
        // macOS silently ignores a zero-length `kSecValueData` and leaves the
        // stored value unchanged (returning errSecSuccess). A zero-length value
        // *does* store correctly via SecItemAdd, so the only way to overwrite an
        // existing item with an empty value is to delete it and re-Add — which the
        // loop does by removing the item here and looping back to the Add above.
        if (value.len == 0) {
            if (attempts >= max_attempts) return keychainFailure(status);
            const del_query = try baseQuery(service, name);
            defer CFRelease(del_query);
            const del = SecItemDelete(del_query);
            // Deleted, or a concurrent delete already removed it — either way the
            // next Add can proceed. Any other status is a real failure.
            if (del != errSecSuccess and del != errSecItemNotFound) return keychainFailure(del);
            continue;
        }

        // Non-empty value — update its data in place. The query matches by
        // service+account; the attributes-to-update carry only the new value.
        const update_query = try baseQuery(service, name);
        defer CFRelease(update_query);
        const attrs = try newDict();
        defer CFRelease(attrs);
        const update_value = try cfData(value);
        defer CFRelease(update_value);
        CFDictionaryAddValue(attrs, kSecValueData, update_value);

        const update = SecItemUpdate(update_query, attrs);
        if (update == errSecSuccess) return;
        // Benign race: the item was deleted between our Add and this Update. Loop
        // to re-Add rather than surface an opaque failure.
        if (update == errSecItemNotFound and attempts < max_attempts) continue;
        return keychainFailure(update);
    }
}

/// Remove a secret. Succeeds (no-op) if no item exists. `allocator` is unused
/// (see `set`), present for interface parity across native backends.
pub fn delete(_: std.mem.Allocator, _: std.Io, _: *const std.process.Environ.Map, service: []const u8, name: []const u8) !void {
    const query = try baseQuery(service, name);
    defer CFRelease(query);

    const status = SecItemDelete(query);
    if (status == errSecSuccess) return;
    // The caller asked for the item to be gone; if it was already absent (or was
    // removed by a concurrent `delete`/`set` between a prior read and now) that is
    // success, not a failure.
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
