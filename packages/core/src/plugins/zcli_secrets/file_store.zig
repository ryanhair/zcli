//! File-backed secret store — the portable fallback backend for `zcli_secrets`.
//!
//! This backend is pure Zig (no libc, no dynamic linking), so it preserves
//! zcli's static-single-binary property. It is the backend used wherever a
//! native OS keychain is not compiled in (currently: everywhere except macOS).
//!
//! ## At-rest security
//!
//! Secrets are stored **in plaintext on disk**, protected only by filesystem
//! permissions:
//!
//! - The store directory is created `0700` (owner-only).
//! - The store file is created — and, defeating any process `umask`, forced —
//!   to `0600` (owner read/write only).
//!
//! This is strictly weaker than an OS keychain (which encrypts at rest and can
//! gate access per-application). It is the documented fallback; a CLI author
//! who needs stronger guarantees should target a platform with a keychain
//! backend. Values are base64-encoded so arbitrary credential bytes survive a
//! JSON round-trip; base64 is **not** encryption.
//!
//! ## On-disk format
//!
//! A single JSON object mapping secret name to base64-encoded value:
//!
//! ```json
//! { "token": "aGVsbG8=", "refresh": "d29ybGQ=" }
//! ```

const std = @import("std");

/// Name of the store file within the secrets directory.
pub const store_file_name = "secrets.json";

/// Temp file the store is written to before being atomically renamed into
/// place. Kept in the same directory so the rename stays within one filesystem.
const store_tmp_name = "secrets.json.tmp";

/// Cap on the store file we will read into memory. Secrets are small; a store
/// larger than this is treated as corrupt rather than allocated.
const max_store_bytes = 4 * 1024 * 1024;

const b64 = std.base64.standard;

pub const Error = error{
    /// The store file exists but is not the expected JSON-object shape.
    CorruptStore,
};

/// Owner-only permissions for the store file (`-rw-------`) on POSIX. On
/// platforms whose permission model has no Unix mode (e.g. Windows — where this
/// backend is only a theoretical fallback, the native store being the default),
/// fall back to the default file permissions.
fn filePermissions() std.Io.File.Permissions {
    return if (@hasDecl(std.Io.File.Permissions, "fromMode"))
        std.Io.File.Permissions.fromMode(0o600)
    else
        .default_file;
}

/// Read the whole store file into a parsed JSON object, or return an empty
/// object if the file does not exist yet. Caller owns `parsed` and must
/// `deinit` it. Returns `null` when there is no store yet.
fn readStore(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir) !?std.json.Parsed(std.json.Value) {
    const content = dir.readFileAlloc(io, store_file_name, allocator, .limited(max_store_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{
        .allocate = .alloc_always,
    }) catch return Error.CorruptStore;
    if (parsed.value != .object) {
        parsed.deinit();
        return Error.CorruptStore;
    }
    return parsed;
}

/// Serialize `obj` back to the store, **atomically**: write to a temp file
/// (owner-only), fsync it, then rename it over the real store. The rename means
/// a concurrent reader — or a crash mid-write — sees either the complete old
/// store or the complete new one, never a truncated file that would lose every
/// stored secret. Owner-only `0600` is forced after creation to defeat `umask`.
fn writeStore(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, obj: std.json.Value) !void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, obj, .{});
    defer allocator.free(bytes);

    var file = try dir.createFile(io, store_tmp_name, .{ .permissions = filePermissions() });
    // Remove the temp file if anything below fails (write, sync, or rename).
    errdefer dir.deleteFile(io, store_tmp_name) catch {};
    {
        defer file.close(io);
        // Force 0600 regardless of umask (createFile's mode is masked by umask).
        try file.setPermissions(io, filePermissions());
        try file.writeStreamingAll(io, bytes);
        try file.sync(io);
    }
    try dir.rename(store_tmp_name, dir, store_file_name, io);
}

/// Retrieve a secret by name. Returns `null` if the store or the name is
/// absent. The returned bytes are owned by `allocator`.
pub fn get(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, name: []const u8) !?[]const u8 {
    const parsed = (try readStore(io, allocator, dir)) orelse return null;
    defer parsed.deinit();

    const encoded = parsed.value.object.get(name) orelse return null;
    if (encoded != .string) return Error.CorruptStore;

    const decoded_len = try b64.Decoder.calcSizeForSlice(encoded.string);
    const out = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(out);
    try b64.Decoder.decode(out, encoded.string);
    return out;
}

/// Store (or overwrite) a secret. `value` is copied into the store; the caller
/// retains ownership of the passed slice.
pub fn set(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, name: []const u8, value: []const u8) !void {
    const parsed = try readStore(io, allocator, dir);
    // Work inside whichever arena owns the parsed tree so all keys/values share
    // one lifetime; fall back to a fresh arena when there is no store yet.
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = if (parsed) |p| p.arena.allocator() else scratch.allocator();
    defer if (parsed) |p| p.deinit();

    var obj: std.json.ObjectMap = if (parsed) |p| p.value.object else .empty;

    const encoded_len = b64.Encoder.calcSize(value.len);
    const encoded = try a.alloc(u8, encoded_len);
    _ = b64.Encoder.encode(encoded, value);

    // Dupe the name into the same arena so the map key outlives any freed input.
    try obj.put(a, try a.dupe(u8, name), .{ .string = encoded });

    try writeStore(io, allocator, dir, .{ .object = obj });
}

/// Remove a secret. Succeeds (no-op) if the store or the name is absent.
pub fn delete(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, name: []const u8) !void {
    const parsed = (try readStore(io, allocator, dir)) orelse return;
    defer parsed.deinit();

    var obj = parsed.value.object;
    if (!obj.swapRemove(name)) return; // absent — nothing to write
    try writeStore(io, allocator, dir, .{ .object = obj });
}

// ============================================================================
// Tests
// ============================================================================

test "set then get round-trips a value" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try set(io, allocator, tmp.dir, "token", "s3cr3t-value");

    const got = (try get(io, allocator, tmp.dir, "token")).?;
    defer allocator.free(got);
    try std.testing.expectEqualStrings("s3cr3t-value", got);
}

test "get returns null for missing name and missing store" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // No store file at all.
    try std.testing.expect((try get(io, allocator, tmp.dir, "absent")) == null);

    // Store exists but name absent.
    try set(io, allocator, tmp.dir, "present", "x");
    try std.testing.expect((try get(io, allocator, tmp.dir, "absent")) == null);
}

test "set overwrites an existing value and preserves siblings" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try set(io, allocator, tmp.dir, "a", "one");
    try set(io, allocator, tmp.dir, "b", "two");
    try set(io, allocator, tmp.dir, "a", "uno");

    const a = (try get(io, allocator, tmp.dir, "a")).?;
    defer allocator.free(a);
    const b = (try get(io, allocator, tmp.dir, "b")).?;
    defer allocator.free(b);
    try std.testing.expectEqualStrings("uno", a);
    try std.testing.expectEqualStrings("two", b);
}

test "delete removes a value and is a no-op when absent" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try delete(io, allocator, tmp.dir, "never"); // no store yet — no error

    try set(io, allocator, tmp.dir, "k", "v");
    try delete(io, allocator, tmp.dir, "k");
    try std.testing.expect((try get(io, allocator, tmp.dir, "k")) == null);

    try delete(io, allocator, tmp.dir, "k"); // already gone — no error
}

test "values with arbitrary bytes survive base64 round-trip" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const raw = [_]u8{ 0x00, 0xff, 0x0a, '"', '\\', 0x7f, 'a' };
    try set(io, allocator, tmp.dir, "bin", &raw);

    const got = (try get(io, allocator, tmp.dir, "bin")).?;
    defer allocator.free(got);
    try std.testing.expectEqualSlices(u8, &raw, got);
}

test "store file is created with owner-only permissions" {
    // POSIX-only: guard at compile time so the Unix-mode API (`toMode`) is not
    // even analyzed on platforms without it (e.g. Windows).
    if (comptime std.Io.File.Permissions.has_executable_bit) {
        const io = std.testing.io;
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try set(io, allocator, tmp.dir, "k", "v");

        var file = try tmp.dir.openFile(io, store_file_name, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    } else return error.SkipZigTest;
}

test "set leaves no temp file behind after the atomic rename" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try set(io, allocator, tmp.dir, "a", "one");
    try set(io, allocator, tmp.dir, "a", "two"); // overwrite an existing store

    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, store_tmp_name, .{}));
}

test "a corrupt store surfaces CorruptStore rather than a bad decode" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = store_file_name, .data = "not json at all" });
    try std.testing.expectError(Error.CorruptStore, get(io, allocator, tmp.dir, "k"));
}
