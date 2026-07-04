//! Single source of truth for the generated registry's module names.
//! code_generation.zig emits `const X = @import("X");` lines and
//! module_creation.zig registers the modules under the build graph — both
//! derive names here, so an emitted import string can never drift from a
//! registered module name. All names pass through identifier.sanitize, so a
//! dash-named command file ("my-cmd.zig") yields a valid identifier on both
//! sides.

const std = @import("std");
const identifier = @import("../identifier.zig");

/// Top-level leaf command: `cmd_<name>`. The prefix keeps top-level command
/// modules from colliding with other module-level decls (and keeps "test"
/// legal — `@import("test")` aside, `const test = ...` is not).
pub fn leafModuleName(allocator: std.mem.Allocator, cmd_name: []const u8) ![]u8 {
    const sanitized = try identifier.sanitize(allocator, cmd_name);
    defer allocator.free(sanitized);
    return std.fmt.allocPrint(allocator, "cmd_{s}", .{sanitized});
}

/// Top-level optional group (directory with index.zig): `<name>_index`.
pub fn indexModuleName(allocator: std.mem.Allocator, cmd_name: []const u8) ![]u8 {
    const sanitized = try identifier.sanitize(allocator, cmd_name);
    defer allocator.free(sanitized);
    return std.fmt.allocPrint(allocator, "{s}_index", .{sanitized});
}

/// Nested command: sanitized path parts joined with '_' (unique even for
/// deeply nested commands).
pub fn pathModuleName(allocator: std.mem.Allocator, path: []const []const u8) ![]u8 {
    var parts = try std.ArrayList([]const u8).initCapacity(allocator, path.len);
    defer {
        for (parts.items) |part| allocator.free(part);
        parts.deinit(allocator);
    }
    for (path) |part| {
        parts.appendAssumeCapacity(try identifier.sanitize(allocator, part));
    }
    return std.mem.join(allocator, "_", parts.items);
}

/// Nested optional group: `<path joined>_index`.
pub fn pathIndexModuleName(allocator: std.mem.Allocator, path: []const []const u8) ![]u8 {
    const base = try pathModuleName(allocator, path);
    defer allocator.free(base);
    return std.fmt.allocPrint(allocator, "{s}_index", .{base});
}

const testing = std.testing;

test "leafModuleName sanitizes dashes" {
    const name = try leafModuleName(testing.allocator, "my-cmd");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("cmd_my_cmd", name);
}

test "leafModuleName handles the 'test' command without special-casing" {
    const name = try leafModuleName(testing.allocator, "test");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("cmd_test", name);
}

test "indexModuleName sanitizes dashes" {
    const name = try indexModuleName(testing.allocator, "my-group");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("my_group_index", name);
}

test "pathModuleName joins sanitized parts" {
    const name = try pathModuleName(testing.allocator, &.{ "gh", "add-item" });
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("gh_add_item", name);
}

test "pathIndexModuleName appends _index" {
    const name = try pathIndexModuleName(testing.allocator, &.{ "sprint", "sub-group" });
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("sprint_sub_group_index", name);
}
