//! Linux Secret Service backend for `zcli_secrets`, via **libsecret**.
//!
//! Stores each secret through the freedesktop.org Secret Service (the D-Bus API
//! that gnome-keyring / KWallet implement), keyed by the attributes
//! `(service = app_name, account = secret name)`. The daemon encrypts secrets
//! at rest and mediates access, like the macOS Keychain.
//!
//! ## Why this makes the plugin opt-in
//!
//! libsecret (`libsecret-1`, which pulls in glib) is a dynamically-linked
//! system library and needs a running Secret Service over D-Bus. Linking it
//! into every CLI would break zcli's static single-binary property — so this
//! backend, and its linking, is compiled in only when an app registers
//! `zcli_secrets` on Linux (see the plugin's build wiring). A CLI that does not
//! opt in never references these symbols and stays static.
//!
//! ## Binary-safe values
//!
//! libsecret's password helper API treats a secret as a NUL-terminated C
//! string, so it cannot round-trip a value containing NUL bytes. To keep the
//! same "opaque bytes" contract the other backends offer, values are
//! base64-encoded before being handed to libsecret and decoded on read. (A user
//! inspecting the entry with `secret-tool` therefore sees base64, not the raw
//! token — documented here so that is not a surprise.)
//!
//! The `secret_password_{store,lookup,clear}_sync` calls used here are the
//! classic C-variadic helpers: `(schema, ..., attr_name, attr_value, ..., NULL)`.

const std = @import("std");

const b64 = std.base64.standard;

// ---------------------------------------------------------------------------
// libsecret / glib FFI
// ---------------------------------------------------------------------------

/// `GError` — glib's error box. We only ever read nothing out of it and free it.
const GError = extern struct {
    domain: u32, // GQuark
    code: c_int,
    message: ?[*:0]u8,
};

/// `SecretSchemaAttributeType`: STRING = 0 (the only one we use).
const SecretSchemaAttribute = extern struct {
    name: ?[*:0]const u8,
    type: c_int,
};

/// `SecretSchema`. The trailing `reserved*` fields are private ABI padding that
/// must be present so the struct size/layout matches libsecret's.
const SecretSchema = extern struct {
    name: ?[*:0]const u8,
    flags: c_int,
    attributes: [32]SecretSchemaAttribute,
    reserved: c_int = 0,
    reserved1: ?*anyopaque = null,
    reserved2: ?*anyopaque = null,
    reserved3: ?*anyopaque = null,
    reserved4: ?*anyopaque = null,
    reserved5: ?*anyopaque = null,
    reserved6: ?*anyopaque = null,
    reserved7: ?*anyopaque = null,
};

// C-variadic helpers. The variadic tail is attribute name/value pointer pairs
// terminated by a NULL pointer.
extern "c" fn secret_password_store_sync(
    schema: *const SecretSchema,
    collection: ?[*:0]const u8,
    label: [*:0]const u8,
    password: [*:0]const u8,
    cancellable: ?*anyopaque,
    err: *?*GError,
    ...,
) c_int;
extern "c" fn secret_password_lookup_sync(
    schema: *const SecretSchema,
    cancellable: ?*anyopaque,
    err: *?*GError,
    ...,
) ?[*:0]u8;
extern "c" fn secret_password_clear_sync(
    schema: *const SecretSchema,
    cancellable: ?*anyopaque,
    err: *?*GError,
    ...,
) c_int;
extern "c" fn secret_password_free(password: ?[*:0]u8) void;
extern "c" fn g_error_free(err: *GError) void;

/// Static schema identifying zcli secrets. `flags = 0` is `SECRET_SCHEMA_NONE`;
/// items are matched by the schema name plus the two string attributes.
const schema: SecretSchema = .{
    .name = "org.zcli.Secret",
    .flags = 0,
    .attributes = attrs: {
        var a = [_]SecretSchemaAttribute{.{ .name = null, .type = 0 }} ** 32;
        a[0] = .{ .name = "service", .type = 0 };
        a[1] = .{ .name = "account", .type = 0 };
        break :attrs a;
    },
};

const attr_service: [*:0]const u8 = "service";
const attr_account: [*:0]const u8 = "account";
const varargs_end: ?*anyopaque = null;

pub const Error = error{
    /// A libsecret call reported failure (e.g. no Secret Service available).
    SecretServiceFailure,
};

/// Retrieve a secret. Returns `null` if no matching item exists. The returned
/// bytes are owned by `allocator`.
pub fn get(allocator: std.mem.Allocator, service: []const u8, name: []const u8) !?[]const u8 {
    const svc = try allocator.dupeZ(u8, service);
    defer allocator.free(svc);
    const acct = try allocator.dupeZ(u8, name);
    defer allocator.free(acct);

    var err: ?*GError = null;
    const pw = secret_password_lookup_sync(&schema, null, &err, attr_service, svc.ptr, attr_account, acct.ptr, varargs_end);
    if (err) |e| {
        g_error_free(e);
        return Error.SecretServiceFailure;
    }
    const raw = pw orelse return null; // not found
    defer secret_password_free(raw);

    const encoded = std.mem.span(raw);
    const decoded_len = b64.Decoder.calcSizeForSlice(encoded) catch return Error.SecretServiceFailure;
    const out = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(out);
    b64.Decoder.decode(out, encoded) catch return Error.SecretServiceFailure;
    return out;
}

/// Store (or overwrite) a secret.
pub fn set(allocator: std.mem.Allocator, service: []const u8, name: []const u8, value: []const u8) !void {
    const svc = try allocator.dupeZ(u8, service);
    defer allocator.free(svc);
    const acct = try allocator.dupeZ(u8, name);
    defer allocator.free(acct);

    // base64 so arbitrary bytes survive libsecret's NUL-terminated string API.
    const encoded = try allocator.allocSentinel(u8, b64.Encoder.calcSize(value.len), 0);
    defer allocator.free(encoded);
    _ = b64.Encoder.encode(encoded, value);

    const label = try std.fmt.allocPrintSentinel(allocator, "{s}: {s}", .{ service, name }, 0);
    defer allocator.free(label);

    var err: ?*GError = null;
    const ok = secret_password_store_sync(&schema, null, label.ptr, encoded.ptr, null, &err, attr_service, svc.ptr, attr_account, acct.ptr, varargs_end);
    if (ok == 0) {
        if (err) |e| g_error_free(e);
        return Error.SecretServiceFailure;
    }
}

/// Remove a secret. Succeeds (no-op) if no matching item exists.
pub fn delete(allocator: std.mem.Allocator, service: []const u8, name: []const u8) !void {
    const svc = try allocator.dupeZ(u8, service);
    defer allocator.free(svc);
    const acct = try allocator.dupeZ(u8, name);
    defer allocator.free(acct);

    var err: ?*GError = null;
    // Returns TRUE if removed, FALSE if there was nothing to remove; either is
    // fine. Only a set `err` is a real failure.
    _ = secret_password_clear_sync(&schema, null, &err, attr_service, svc.ptr, attr_account, acct.ptr, varargs_end);
    if (err) |e| {
        g_error_free(e);
        return Error.SecretServiceFailure;
    }
}

test "secret service backend compiles and links against libsecret" {
    // Taking the address of these forces them to be analyzed and codegen'd, so
    // this test only passes when the exe links libsecret/glib — the link-time
    // half of the portability guarantee. Not called: a live round-trip needs a
    // running Secret Service (see secrets_live_test.zig, gated to CI).
    _ = &get;
    _ = &set;
    _ = &delete;
}
