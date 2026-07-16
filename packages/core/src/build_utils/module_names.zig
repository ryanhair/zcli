//! Single source of truth for the generated registry's module names.
//! code_generation.zig emits `const X = @import("X");` lines and
//! module_creation.zig registers the modules under the build graph — both
//! derive names here, so an emitted import string can never drift from a
//! registered module name. All names pass through identifier.sanitize, so a
//! dash-named command file ("my-cmd.zig") yields a valid identifier on both
//! sides.

const std = @import("std");
const identifier = @import("../identifier.zig");
const discovery_types = @import("discovery_types.zig");

const DiscoveredCommand = discovery_types.DiscoveredCommand;
const DiscoveredCommands = discovery_types.DiscoveredCommands;

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

/// The generated module identifier for a single command, or null for a command
/// type that gets no module (a pure group). Mirrors exactly what
/// code_generation.zig emits and module_creation.zig registers: top-level
/// commands are named from the leaf/index helpers, nested ones from the
/// path-joined helpers. `is_root` says whether the command sits at the top of
/// the command tree (matching how the two generators split root iteration from
/// their recursive descent). Caller owns the result.
fn moduleNameFor(allocator: std.mem.Allocator, cmd: *const DiscoveredCommand, is_root: bool) !?[]u8 {
    return switch (cmd.command_type) {
        .leaf => if (is_root)
            try leafModuleName(allocator, cmd.name)
        else
            try pathModuleName(allocator, cmd.path),
        .optional_group => if (is_root)
            try indexModuleName(allocator, cmd.name)
        else
            try pathIndexModuleName(allocator, cmd.path),
        .pure_group => null,
    };
}

/// A pair of command files whose generated module identifiers are equal.
/// `module_name` is owned by the caller; the file paths are borrowed from the
/// `DiscoveredCommands` passed to `findModuleNameCollision`.
pub const ModuleNameCollision = struct {
    module_name: []u8,
    first_file: []const u8,
    second_file: []const u8,
};

/// Scan every discovered command and report the first pair whose generated
/// module identifiers collide, or null when all are unique.
///
/// Names are sanitized (non-alnum → `_`) and path parts joined with `_`, so the
/// join separator and the sanitized separator are the same character:
/// `foo/bar-baz.zig` and `foo/bar/baz.zig` both yield `foo_bar_baz`, and
/// `my-cmd.zig` and `my_cmd.zig` both yield `cmd_my_cmd`. Two distinct commands
/// sharing one module name would emit duplicate `const X = @import(...)` decls
/// in the generated registry — an opaque compile error — and silently overwrite
/// each other's `b.addModule` mapping. The build calls this first so it can
/// reject the collision with a message naming both source files instead.
pub fn findModuleNameCollision(allocator: std.mem.Allocator, commands: DiscoveredCommands) !?ModuleNameCollision {
    var seen = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        seen.deinit();
    }
    return findCollisionInMap(allocator, &seen, &commands.root, true);
}

fn findCollisionInMap(
    allocator: std.mem.Allocator,
    seen: *std.StringHashMap([]const u8),
    map: *const std.StringHashMap(DiscoveredCommand),
    is_root: bool,
) !?ModuleNameCollision {
    var it = map.iterator();
    while (it.next()) |entry| {
        const cmd = entry.value_ptr.*;
        if (try moduleNameFor(allocator, &cmd, is_root)) |name| {
            const gop = try seen.getOrPut(name);
            if (gop.found_existing) {
                // `name` was not stored (an equal key already owns the slot);
                // hand the caller its own copy of the colliding identifier.
                defer allocator.free(name);
                return ModuleNameCollision{
                    .module_name = try allocator.dupe(u8, gop.key_ptr.*),
                    .first_file = gop.value_ptr.*,
                    .second_file = cmd.file_path,
                };
            }
            // `seen` now owns `name` as its key; record which file claimed it.
            gop.value_ptr.* = cmd.file_path;
        }
        if (cmd.subcommands) |*subcmds| {
            if (try findCollisionInMap(allocator, seen, subcmds, false)) |collision| {
                return collision;
            }
        }
    }
    return null;
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

// --- Collision detection helpers ---------------------------------------------

fn dupePath(allocator: std.mem.Allocator, path: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, path.len);
    for (path, 0..) |p, i| out[i] = try allocator.dupe(u8, p);
    return out;
}

fn makeCommand(
    allocator: std.mem.Allocator,
    name: []const u8,
    path: []const []const u8,
    file_path: []const u8,
    command_type: discovery_types.CommandType,
    subcommands: ?std.StringHashMap(DiscoveredCommand),
) !DiscoveredCommand {
    return .{
        .name = try allocator.dupe(u8, name),
        .path = try dupePath(allocator, path),
        .file_path = try allocator.dupe(u8, file_path),
        .command_type = command_type,
        .subcommands = subcommands,
    };
}

fn putLeaf(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap(DiscoveredCommand),
    name: []const u8,
    path: []const []const u8,
    file_path: []const u8,
) !void {
    try map.put(try allocator.dupe(u8, name), try makeCommand(allocator, name, path, file_path, .leaf, null));
}

test "findModuleNameCollision flags two top-level commands with the same sanitized name" {
    const allocator = testing.allocator;
    var commands = DiscoveredCommands.init(allocator);
    defer commands.deinit();

    // Both files survive discovery (distinct map keys) but sanitize to the same
    // top-level module identifier `cmd_my_cmd`.
    try putLeaf(allocator, &commands.root, "my-cmd", &.{"my-cmd"}, "my-cmd.zig");
    try putLeaf(allocator, &commands.root, "my_cmd", &.{"my_cmd"}, "my_cmd.zig");

    const collision = (try findModuleNameCollision(allocator, commands)).?;
    defer allocator.free(collision.module_name);
    try testing.expectEqualStrings("cmd_my_cmd", collision.module_name);
}

test "findModuleNameCollision flags a leaf/nested path collision" {
    const allocator = testing.allocator;
    var commands = DiscoveredCommands.init(allocator);
    defer commands.deinit();

    // commands/foo/bar/baz.zig  → path [foo, bar, baz] → foo_bar_baz
    var bar_subs = std.StringHashMap(DiscoveredCommand).init(allocator);
    try bar_subs.put(
        try allocator.dupe(u8, "baz"),
        try makeCommand(allocator, "baz", &.{ "foo", "bar", "baz" }, "foo/bar/baz.zig", .leaf, null),
    );

    var foo_subs = std.StringHashMap(DiscoveredCommand).init(allocator);
    try foo_subs.put(
        try allocator.dupe(u8, "bar"),
        try makeCommand(allocator, "bar", &.{ "foo", "bar" }, "foo/bar", .pure_group, bar_subs),
    );
    // commands/foo/bar-baz.zig → path [foo, bar-baz] → foo_bar_baz
    try foo_subs.put(
        try allocator.dupe(u8, "bar-baz"),
        try makeCommand(allocator, "bar-baz", &.{ "foo", "bar-baz" }, "foo/bar-baz.zig", .leaf, null),
    );

    try commands.root.put(
        try allocator.dupe(u8, "foo"),
        try makeCommand(allocator, "foo", &.{"foo"}, "foo", .pure_group, foo_subs),
    );

    const collision = (try findModuleNameCollision(allocator, commands)).?;
    defer allocator.free(collision.module_name);
    try testing.expectEqualStrings("foo_bar_baz", collision.module_name);
}

test "findModuleNameCollision returns null when all module names are unique" {
    const allocator = testing.allocator;
    var commands = DiscoveredCommands.init(allocator);
    defer commands.deinit();

    try putLeaf(allocator, &commands.root, "foo", &.{"foo"}, "foo.zig");
    try putLeaf(allocator, &commands.root, "bar", &.{"bar"}, "bar.zig");

    var group_subs = std.StringHashMap(DiscoveredCommand).init(allocator);
    try group_subs.put(
        try allocator.dupe(u8, "list"),
        try makeCommand(allocator, "list", &.{ "users", "list" }, "users/list.zig", .leaf, null),
    );
    try commands.root.put(
        try allocator.dupe(u8, "users"),
        try makeCommand(allocator, "users", &.{"users"}, "users/index.zig", .optional_group, group_subs),
    );

    try testing.expect((try findModuleNameCollision(allocator, commands)) == null);
}
