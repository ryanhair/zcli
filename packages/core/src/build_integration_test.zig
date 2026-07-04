//! Integration tests for build-time command discovery and registry generation:
//! real temp directory trees pushed through `discoverInDir` (the shared core
//! both the build and `zcli tree` use), and the discovered structures pushed
//! through `generateComptimeRegistrySource`.
//!
//! Discovery and codegen work from file *names and structure* only — neither
//! reads file contents — so command files here are one-line placeholders.

const std = @import("std");
const command_discovery = @import("build_utils/command_discovery.zig");
const code_generation = @import("build_utils/code_generation.zig");
const types = @import("build_utils/types.zig");

const testing = std.testing;

const placeholder = "pub fn execute() void {}";

/// Write `sub_path`, creating any missing parent directories.
fn writeNested(dir: std.Io.Dir, io: std.Io, sub_path: []const u8, data: []const u8) !void {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, sub_path, i, '/')) |slash| {
        dir.createDir(io, sub_path[0..slash], .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        i = slash + 1;
    }
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
}

fn discover(tmp: *std.testing.TmpDir) !command_discovery.DiscoveredCommands {
    const io = testing.io;
    var dir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    return command_discovery.discoverInDir(testing.allocator, io, dir);
}

const test_config = types.BuildConfig{
    .commands_dir = "", // not used by code generation
    .plugins_dir = null,
    .plugins = null,
    .app_name = "testapp",
    .app_version = "1.0.0",
    .app_description = "Test CLI application",
};

test "build integration: basic command discovery" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "hello.zig", .data = placeholder });
    try tmp.dir.writeFile(io, .{ .sub_path = "version.zig", .data = placeholder });

    var discovered = try discover(&tmp);
    defer discovered.deinit();

    try testing.expect(discovered.root.contains("hello"));
    try testing.expect(discovered.root.contains("version"));
    try testing.expectEqual(@as(u32, 2), discovered.root.count());
}

test "build integration: nested command groups" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeNested(tmp.dir, io, "users/index.zig", placeholder);
    try writeNested(tmp.dir, io, "users/list.zig", placeholder);
    try writeNested(tmp.dir, io, "users/create.zig", placeholder);
    try writeNested(tmp.dir, io, "users/permissions/list.zig", placeholder);

    var discovered = try discover(&tmp);
    defer discovered.deinit();

    try testing.expect(discovered.root.contains("users"));
    try testing.expectEqual(@as(u32, 1), discovered.root.count());

    // index.zig is the group's default command, not a subcommand.
    const users_group = discovered.root.get("users").?;
    try testing.expect(users_group.command_type == .optional_group);
    try testing.expect(!users_group.subcommands.?.contains("index"));
    try testing.expect(users_group.subcommands.?.contains("list"));
    try testing.expect(users_group.subcommands.?.contains("create"));
    try testing.expect(users_group.subcommands.?.contains("permissions"));
    try testing.expectEqual(@as(u32, 3), users_group.subcommands.?.count());

    // The nested group has no index.zig -> pure group.
    const permissions_group = users_group.subcommands.?.get("permissions").?;
    try testing.expect(permissions_group.command_type == .pure_group);
    try testing.expect(permissions_group.subcommands.?.contains("list"));
    try testing.expectEqual(@as(u32, 1), permissions_group.subcommands.?.count());
}

test "build integration: invalid and hidden names are skipped" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "valid-name.zig", .data = placeholder });
    try tmp.dir.writeFile(io, .{ .sub_path = "valid_name.zig", .data = placeholder });
    try tmp.dir.writeFile(io, .{ .sub_path = "ValidName123.zig", .data = placeholder });

    try tmp.dir.writeFile(io, .{ .sub_path = "invalid name.zig", .data = placeholder }); // space
    try tmp.dir.writeFile(io, .{ .sub_path = "invalid@name.zig", .data = placeholder }); // special char
    try tmp.dir.writeFile(io, .{ .sub_path = ".hidden.zig", .data = placeholder }); // hidden file
    try tmp.dir.writeFile(io, .{ .sub_path = "_helper.zig", .data = placeholder }); // helper convention

    var discovered = try discover(&tmp);
    defer discovered.deinit();

    try testing.expect(discovered.root.contains("valid-name"));
    try testing.expect(discovered.root.contains("valid_name"));
    try testing.expect(discovered.root.contains("ValidName123"));

    try testing.expect(!discovered.root.contains("invalid name"));
    try testing.expect(!discovered.root.contains("invalid@name"));
    try testing.expect(!discovered.root.contains(".hidden"));
    try testing.expect(!discovered.root.contains("_helper"));

    try testing.expectEqual(@as(u32, 3), discovered.root.count());
}

test "build integration: empty directories and edge cases" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "empty_group", .default_dir);
    try tmp.dir.createDir(io, "group_with_subdirs", .default_dir);
    try writeNested(tmp.dir, io, "group_with_subdirs/empty_subdir/.keep", "");

    try writeNested(tmp.dir, io, "index_only/index.zig", placeholder);
    try writeNested(tmp.dir, io, "no_index/subcmd.zig", placeholder);

    var discovered = try discover(&tmp);
    defer discovered.deinit();

    // Directories with no commands anywhere below them are not groups.
    try testing.expect(!discovered.root.contains("empty_group"));
    try testing.expect(!discovered.root.contains("group_with_subdirs"));

    const index_only = discovered.root.get("index_only").?;
    try testing.expect(index_only.command_type == .optional_group);
    try testing.expect(!index_only.subcommands.?.contains("index"));

    const no_index = discovered.root.get("no_index").?;
    try testing.expect(no_index.command_type == .pure_group);
    try testing.expect(no_index.subcommands.?.contains("subcmd"));
}

test "build integration: maximum nesting depth" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Within the depth limit (6): discovered.
    try writeNested(tmp.dir, io, "level1/level2/level3/level4/level5/cmd.zig", placeholder);
    // Beyond the limit: the whole chain ends up empty and is dropped.
    try writeNested(tmp.dir, io, "deep/l1/l2/l3/l4/l5/l6/l7/ignored.zig", placeholder);

    var discovered = try discover(&tmp);
    defer discovered.deinit();

    try testing.expect(discovered.root.contains("level1"));
    try testing.expect(!discovered.root.contains("deep"));

    // The command at level5 is reachable through the group chain.
    var current = discovered.root.get("level1").?;
    current = current.subcommands.?.get("level2").?;
    current = current.subcommands.?.get("level3").?;
    current = current.subcommands.?.get("level4").?;
    current = current.subcommands.?.get("level5").?;
    try testing.expect(current.subcommands.?.contains("cmd"));
}

test "build integration: registry source generation from a discovered tree" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "hello.zig", .data = placeholder });
    try writeNested(tmp.dir, io, "users/list.zig", placeholder);

    var discovered = try discover(&tmp);
    defer discovered.deinit();

    const source = try code_generation.generateComptimeRegistrySource(testing.allocator, discovered, test_config, &.{});
    defer testing.allocator.free(source);

    // App metadata constants.
    try testing.expect(std.mem.indexOf(u8, source, "pub const app_name = \"testapp\"") != null);
    try testing.expect(std.mem.indexOf(u8, source, "pub const app_version = \"1.0.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, source, "Test CLI application") != null);

    // Registry shape and exports.
    try testing.expect(std.mem.indexOf(u8, source, "const RegistryType = zcli.Registry.init") != null);
    try testing.expect(std.mem.indexOf(u8, source, ".build();") != null);
    try testing.expect(std.mem.indexOf(u8, source, "pub const Context = RegistryType.Context;") != null);
    try testing.expect(std.mem.indexOf(u8, source, "pub fn init() RegistryType") != null);

    // Both commands are registered, the nested one by its full path.
    try testing.expect(std.mem.indexOf(u8, source, ".register(\"hello\", cmd_hello)") != null);
    try testing.expect(std.mem.indexOf(u8, source, ".register(\"users list\"") != null);
}

test "build integration: a Zig-keyword command name is registered" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "test.zig", .data = placeholder });

    var discovered = try discover(&tmp);
    defer discovered.deinit();

    try testing.expect(discovered.root.contains("test"));

    const source = try code_generation.generateComptimeRegistrySource(testing.allocator, discovered, test_config, &.{});
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, ".register(\"test\", cmd_test)") != null);
}

test "build integration: discovery and generation scale to many commands" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Correctness at scale only — no wall-clock assertions, which are flaky by
    // construction on shared CI runners.
    const num_commands = 100;
    var i: u32 = 0;
    while (i < num_commands) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const filename = try std.fmt.bufPrint(&name_buf, "cmd{d}.zig", .{i});
        try tmp.dir.writeFile(io, .{ .sub_path = filename, .data = placeholder });
    }

    var discovered = try discover(&tmp);
    defer discovered.deinit();

    try testing.expectEqual(@as(u32, num_commands), discovered.root.count());

    const source = try code_generation.generateComptimeRegistrySource(testing.allocator, discovered, test_config, &.{});
    defer testing.allocator.free(source);

    i = 0;
    while (i < num_commands) : (i += 1) {
        var pat_buf: [64]u8 = undefined;
        const pattern = try std.fmt.bufPrint(&pat_buf, ".register(\"cmd{d}\", cmd_cmd{d})", .{ i, i });
        try testing.expect(std.mem.indexOf(u8, source, pattern) != null);
    }
}
