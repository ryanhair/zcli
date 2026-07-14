//! The name index for stored secrets.
//!
//! `zcli_secrets` (OS keychain / Credential Manager / Secret Service) stores
//! an opaque value by name, but it has no "list all names" operation — so this
//! tiny JSON file alongside it tracks *which names exist*, without ever
//! touching a secret value itself. `vault list` reads it to enumerate entries,
//! and `get`/`remove`'s dynamic completion (ADR-0026) reads it to offer known
//! names on <TAB>.

const std = @import("std");

pub const IndexData = struct {
    names: [][]const u8 = &.{},
};

const FILENAME = ".vault-index.json";

pub const LoadResult = struct {
    value: IndexData,
    _parsed: ?std.json.Parsed(IndexData),

    pub fn deinit(self: *LoadResult) void {
        if (self._parsed) |*p| p.deinit();
    }
};

pub fn load(allocator: std.mem.Allocator, io: std.Io) !LoadResult {
    const cwd = std.Io.Dir.cwd();
    const content = cwd.readFileAlloc(io, FILENAME, allocator, .limited(1024 * 1024)) catch {
        return .{ .value = .{}, ._parsed = null };
    };
    defer allocator.free(content);
    if (content.len == 0) return .{ .value = .{}, ._parsed = null };
    const parsed = std.json.parseFromSlice(IndexData, allocator, content, .{
        .allocate = .alloc_always,
    }) catch return .{ .value = .{}, ._parsed = null };
    return .{ .value = parsed.value, ._parsed = parsed };
}

pub fn save(_: std.mem.Allocator, io: std.Io, data: IndexData) !void {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, FILENAME, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    try fw.interface.print("{f}", .{std.json.fmt(data, .{ .whitespace = .indent_2 })});
    try fw.interface.flush();
}

pub fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Returns a new owned slice with `name` appended, unless already present (in
/// which case the input slice is returned unchanged — no-op re-add).
pub fn withAdded(allocator: std.mem.Allocator, names: []const []const u8, name: []const u8) ![][]const u8 {
    if (contains(names, name)) return allocator.dupe([]const u8, names);
    const grown = try allocator.alloc([]const u8, names.len + 1);
    @memcpy(grown[0..names.len], names);
    grown[names.len] = name;
    return grown;
}

/// Returns a new owned slice with every entry equal to `name` removed.
pub fn withRemoved(allocator: std.mem.Allocator, names: []const []const u8, name: []const u8) ![][]const u8 {
    var remaining: std.ArrayList([]const u8) = .empty;
    defer remaining.deinit(allocator);
    for (names) |n| {
        if (!std.mem.eql(u8, n, name)) try remaining.append(allocator, n);
    }
    return remaining.toOwnedSlice(allocator);
}

test "withAdded: skips a duplicate name" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{"github"};
    const result = try withAdded(allocator, &names, "github");
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
}

test "withRemoved: drops the matching entry" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "github", "npm" };
    const result = try withRemoved(allocator, &names, "github");
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("npm", result[0]);
}
