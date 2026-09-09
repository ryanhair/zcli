//! Child-environment composition for `process.zig`.
//!
//! The public policy types remain owned by `process.zig`; this private module
//! owns their validation and composition so the spawn lifecycle only consumes
//! a finished environment map.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const is_windows = builtin.os.tag == .windows;

pub const PolicyError = error{ InvalidEnvName, InvalidEnvValue };
pub const Error = PolicyError || Allocator.Error;

fn nameInList(name: []const u8, list: []const []const u8) bool {
    for (list) |entry| {
        if (is_windows) {
            if (std.os.windows.eqlIgnoreCaseWtf8(entry, name)) return true;
        } else if (std.mem.eql(u8, entry, name)) return true;
    }
    return false;
}

/// Validate a caller-supplied name. Inherited entries are left untouched.
fn validName(name: []const u8) bool {
    if (!std.process.Environ.Map.validateKeyForPut(name)) return false;
    return name.len == 0 or name[0] != '=';
}

fn validValue(value: []const u8) bool {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return false;
    return !is_windows or std.unicode.wtf8ValidateSlice(value);
}

/// Compose a child map from a process.EnvSpec-shaped value. `anytype` keeps the
/// public policy types at the process module's existing interface.
pub fn build(
    allocator: Allocator,
    base: *const std.process.Environ.Map,
    spec: anytype,
) Error!std.process.Environ.Map {
    var map: std.process.Environ.Map = .init(allocator);
    errdefer map.deinit();

    switch (spec.policy) {
        .inherit => for (base.keys(), base.values()) |k, v| try map.put(k, v),
        .allow => |list| for (base.keys(), base.values()) |k, v| {
            if (nameInList(k, list)) try map.put(k, v);
        },
        .deny => |list| for (base.keys(), base.values()) |k, v| {
            if (!nameInList(k, list)) try map.put(k, v);
        },
        .replace => |entries| for (entries) |entry| try putChecked(&map, entry),
    }

    for (spec.add) |entry| try putChecked(&map, entry);
    return map;
}

fn putChecked(map: *std.process.Environ.Map, entry: anytype) Error!void {
    if (!validName(entry.name)) return error.InvalidEnvName;
    if (!validValue(entry.value)) return error.InvalidEnvValue;
    try map.put(entry.name, entry.value);
}

pub fn testComposition(comptime Spec: type) !void {
    const a = std.testing.allocator;
    var base: std.process.Environ.Map = .init(a);
    defer base.deinit();
    try base.put("PATH", "/bin");
    try base.put("HOME", "/home/x");
    try base.put("SECRET", "s3cr3t");

    var inherited = try build(a, &base, Spec{});
    defer inherited.deinit();
    try std.testing.expectEqual(@as(usize, 3), inherited.count());
    try std.testing.expectEqualStrings("/bin", inherited.get("PATH").?);

    var allowed = try build(a, &base, Spec{ .policy = .{ .allow = &.{"PATH"} } });
    defer allowed.deinit();
    try std.testing.expectEqual(@as(usize, 1), allowed.count());
    try std.testing.expect(allowed.get("SECRET") == null);

    var denied = try build(a, &base, Spec{ .policy = .{ .deny = &.{"SECRET"} } });
    defer denied.deinit();
    try std.testing.expectEqual(@as(usize, 2), denied.count());
    try std.testing.expect(denied.get("SECRET") == null);
    try std.testing.expectEqualStrings("/home/x", denied.get("HOME").?);

    var replaced = try build(a, &base, Spec{
        .policy = .{ .replace = &.{.{ .name = "ONLY", .value = "1" }} },
    });
    defer replaced.deinit();
    try std.testing.expectEqual(@as(usize, 1), replaced.count());
    try std.testing.expectEqualStrings("1", replaced.get("ONLY").?);
    try std.testing.expect(replaced.get("PATH") == null);

    var added = try build(a, &base, Spec{
        .add = &.{.{ .name = "PATH", .value = "/override" }},
    });
    defer added.deinit();
    try std.testing.expectEqualStrings("/override", added.get("PATH").?);
}

pub fn testNameMatching(comptime Spec: type) !void {
    const a = std.testing.allocator;
    var base: std.process.Environ.Map = .init(a);
    defer base.deinit();
    try base.put("Path", "/bin");
    var map = try build(a, &base, Spec{ .policy = .{ .allow = &.{"PATH"} } });
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, if (is_windows) 1 else 0), map.count());
}

pub fn testValidation(comptime Spec: type) !void {
    const a = std.testing.allocator;
    var base: std.process.Environ.Map = .init(a);
    defer base.deinit();

    for ([_][]const u8{ "", "A=B", "A\x00B", "=C:" }) |name| {
        try std.testing.expectError(error.InvalidEnvName, build(a, &base, Spec{
            .add = &.{.{ .name = name, .value = "x" }},
        }));
    }
    try std.testing.expectError(error.InvalidEnvValue, build(a, &base, Spec{
        .add = &.{.{ .name = "A", .value = "x\x00y" }},
    }));
    try std.testing.expectError(error.InvalidEnvName, build(a, &base, Spec{
        .policy = .{ .replace = &.{.{ .name = "=X", .value = "1" }} },
    }));
}
