const std = @import("std");
const build_utils = @import("build_utils.zig");

/// Integration tests for the build system command discovery and registry generation.
/// These tests verify that the build-time code generation works correctly across
/// various command structures and edge cases.

// Test helper to create temporary command directories
const TestDir = struct {
    dir: std.testing.TmpDir,
    path: []const u8,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !TestDir {
        var tmp_dir = std.testing.tmpDir(.{});
        const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
        return TestDir{
            .dir = tmp_dir,
            .path = path,
            .allocator = allocator,
        };
    }

    fn deinit(self: *TestDir) void {
        self.allocator.free(self.path);
        self.dir.cleanup();
    }

    fn createFile(self: *TestDir, relative_path: []const u8, content: []const u8) !void {
        // Create parent directories if needed
        if (std.fs.path.dirname(relative_path)) |dirname| {
            try self.dir.dir.makePath(dirname);
        }

        const file = try self.dir.dir.createFile(relative_path, .{});
        defer file.close();
        try file.writeAll(content);
    }
};

test "build integration: basic command discovery" {
    const allocator = std.testing.allocator;
    var test_dir = try TestDir.init(allocator);
    defer test_dir.deinit();

    // Create a simple command structure
    try test_dir.createFile("hello.zig",
        \\const zcli = @import("zcli");
        \\
        \\pub const Args = struct {
        \\    name: []const u8,
        \\};
        \\
        \\pub fn execute(args: Args, options: struct{}, context: *zcli.Context) !void {
        \\    try context.stdout().print("Hello, {s}!\n", .{args.name});
        \\}
    );

    try test_dir.createFile("version.zig",
        \\const zcli = @import("zcli");
        \\
        \\pub fn execute(args: struct{}, options: struct{}, context: *zcli.Context) !void {
        \\    try context.stdout().print("v1.0.0\n", .{});
        \\}
    );

    // Test command discovery
    var discovered = try build_utils.discoverCommands(allocator, test_dir.path);
    defer discovered.deinit();

    // Verify commands were discovered
    try std.testing.expect(discovered.root.contains("hello"));
    try std.testing.expect(discovered.root.contains("version"));
    try std.testing.expectEqual(@as(u32, 2), discovered.root.count());
}

test "build integration: nested command groups" {
    const allocator = std.testing.allocator;
    var test_dir = try TestDir.init(allocator);
    defer test_dir.deinit();

    // Create nested command structure
    try test_dir.createFile("users/index.zig",
        \\const zcli = @import("zcli");
        \\pub fn execute(args: struct{}, options: struct{}, context: *zcli.Context) !void {
        \\    try context.stdout().print("User management\n", .{});
        \\}
    );

    try test_dir.createFile("users/list.zig",
        \\const zcli = @import("zcli");
        \\pub fn execute(args: struct{}, options: struct{}, context: *zcli.Context) !void {
        \\    try context.stdout().print("Listing users\n", .{});
        \\}
    );

    try test_dir.createFile("users/create.zig",
        \\const zcli = @import("zcli");
        \\pub const Args = struct { name: []const u8 };
        \\pub fn execute(args: Args, options: struct{}, context: *zcli.Context) !void {
        \\    try context.stdout().print("Creating user: {s}\n", .{args.name});
        \\}
    );

    // Add deeply nested structure
    try test_dir.createFile("users/permissions/list.zig",
        \\const zcli = @import("zcli");
        \\pub fn execute(args: struct{}, options: struct{}, context: *zcli.Context) !void {
        \\    try context.stdout().print("Listing permissions\n", .{});
        \\}
    );

    var discovered = try build_utils.discoverCommands(allocator, test_dir.path);
    defer discovered.deinit();

    // Verify top-level groups
    try std.testing.expect(discovered.root.contains("users"));
    try std.testing.expectEqual(@as(u32, 1), discovered.root.count());

    // Verify users group structure
    const users_group = discovered.root.get("users").?;
    try std.testing.expect(users_group.command_type != .leaf);
    // index.zig is no longer a subcommand - it's the group's default command
    try std.testing.expect(!users_group.subcommands.?.contains("index"));
    try std.testing.expect(users_group.subcommands.?.contains("list"));
    try std.testing.expect(users_group.subcommands.?.contains("create"));
    try std.testing.expect(users_group.subcommands.?.contains("permissions"));
    try std.testing.expectEqual(@as(u32, 3), users_group.subcommands.?.count());

    // Verify nested permissions group
    const permissions_group = users_group.subcommands.?.get("permissions").?;
    try std.testing.expect(permissions_group.command_type != .leaf);
    try std.testing.expect(permissions_group.subcommands.?.contains("list"));
    try std.testing.expectEqual(@as(u32, 1), permissions_group.subcommands.?.count());
}

test "build integration: command name validation" {
    const allocator = std.testing.allocator;
    var test_dir = try TestDir.init(allocator);
    defer test_dir.deinit();

    // Create files with valid and invalid names
    try test_dir.createFile("valid-name.zig", "pub fn execute() !void {}");
    try test_dir.createFile("valid_name.zig", "pub fn execute() !void {}");
    try test_dir.createFile("ValidName123.zig", "pub fn execute() !void {}");

    // Invalid names that should be skipped
    try test_dir.createFile("invalid name.zig", "pub fn execute() !void {}"); // space
    try test_dir.createFile("invalid@name.zig", "pub fn execute() !void {}"); // special char
    try test_dir.createFile("../traverse.zig", "pub fn execute() !void {}"); // path traversal
    try test_dir.createFile(".hidden.zig", "pub fn execute() !void {}"); // hidden file

    var discovered = try build_utils.discoverCommands(allocator, test_dir.path);
    defer discovered.deinit();

    // Only valid names should be discovered
    try std.testing.expect(discovered.root.contains("valid-name"));
    try std.testing.expect(discovered.root.contains("valid_name"));
    try std.testing.expect(discovered.root.contains("ValidName123"));

    // Invalid names should be skipped
    try std.testing.expect(!discovered.root.contains("invalid name"));
    try std.testing.expect(!discovered.root.contains("invalid@name"));
    try std.testing.expect(!discovered.root.contains("../traverse"));
    try std.testing.expect(!discovered.root.contains(".hidden"));

    try std.testing.expectEqual(@as(u32, 3), discovered.root.count());
}

test "build integration: empty directories and edge cases" {
    const allocator = std.testing.allocator;
    var test_dir = try TestDir.init(allocator);
    defer test_dir.deinit();

    // Create empty directory structure
    try test_dir.dir.dir.makeDir("empty_group");
    try test_dir.dir.dir.makeDir("group_with_subdirs");
    try test_dir.dir.dir.makePath("group_with_subdirs/empty_subdir");

    // Group with only index file
    try test_dir.createFile("index_only/index.zig", "pub fn execute() !void {}");

    // Group with no index but with subcommands
    try test_dir.createFile("no_index/subcmd.zig", "pub fn execute() !void {}");

    var discovered = try build_utils.discoverCommands(allocator, test_dir.path);
    defer discovered.deinit();

    // Empty directories should not be included
    try std.testing.expect(!discovered.root.contains("empty_group"));
    try std.testing.expect(!discovered.root.contains("group_with_subdirs"));

    // Groups with content should be included
    try std.testing.expect(discovered.root.contains("index_only"));
    try std.testing.expect(discovered.root.contains("no_index"));

    const index_only = discovered.root.get("index_only").?;
    try std.testing.expect(index_only.command_type != .leaf);
    // index.zig is no longer a subcommand - it's the group's default command
    try std.testing.expect(!index_only.subcommands.?.contains("index"));

    const no_index = discovered.root.get("no_index").?;
    try std.testing.expect(no_index.command_type != .leaf);
    try std.testing.expect(no_index.subcommands.?.contains("subcmd"));
    try std.testing.expect(!no_index.subcommands.?.contains("index"));
}

test "build integration: maximum nesting depth" {
    const allocator = std.testing.allocator;
    var test_dir = try TestDir.init(allocator);
    defer test_dir.deinit();

    // Create nested structure within allowed depth
    const within_depth_path = "level1/level2/level3/level4/level5/cmd.zig";
    try test_dir.createFile(within_depth_path, "pub fn execute() !void {}");

    // Create structure within the max depth boundary
    const max_depth_path = "a/b/c/d/e/boundary.zig";
    try test_dir.createFile(max_depth_path, "pub fn execute() !void {}");

    // Try to create structure beyond max depth (should be ignored)
    const beyond_depth_path = "deep/l1/l2/l3/l4/l5/l6/l7/ignored.zig";
    try test_dir.createFile(beyond_depth_path, "pub fn execute() !void {}");

    var discovered = try build_utils.discoverCommands(allocator, test_dir.path);
    defer discovered.deinit();

    // Should discover the structure within allowed depth
    try std.testing.expect(discovered.root.contains("level1"));
    try std.testing.expect(discovered.root.contains("a"));

    // Should NOT discover the structure beyond max depth
    try std.testing.expect(!discovered.root.contains("deep"));

    // Navigate to verify we can reach the command at level5
    var current = discovered.root.get("level1").?;
    try std.testing.expect(current.command_type != .leaf);
    try std.testing.expect(current.subcommands.?.contains("level2"));

    current = current.subcommands.?.get("level2").?;
    try std.testing.expect(current.command_type != .leaf);
    try std.testing.expect(current.subcommands.?.contains("level3"));

    // Should be able to reach level5 where our command is
    current = current.subcommands.?.get("level3").?;
    current = current.subcommands.?.get("level4").?;
    current = current.subcommands.?.get("level5").?;
    try std.testing.expect(current.subcommands.?.contains("cmd"));
}

const code_generation = @import("build_utils/code_generation.zig");

test "build integration: registry source generation" {
    const allocator = std.testing.allocator;
    var test_dir = try TestDir.init(allocator);
    defer test_dir.deinit();

    // Create a simple command structure for registry generation
    try test_dir.createFile("hello.zig",
        \\const zcli = @import("zcli");
        \\
        \\pub const Args = struct { name: []const u8 };
        \\pub const Options = struct { loud: bool = false };
        \\
        \\pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
        \\    const greeting = if (options.loud) "HELLO" else "Hello";
        \\    try context.stdout().print("{s}, {s}!\n", .{greeting, args.name});
        \\}
    );

    try test_dir.createFile("users/list.zig",
        \\const zcli = @import("zcli");
        \\
        \\pub const Options = struct { format: enum { json, table } = .table };
        \\
        \\pub fn execute(args: struct{}, options: Options, context: *zcli.Context) !void {
        \\    try context.stdout().print("Listing users in {s} format\n", .{@tagName(options.format)});
        \\}
    );

    var discovered = try build_utils.discoverCommands(allocator, test_dir.path);
    defer discovered.deinit();

    // Generate registry source
    const config = build_utils.BuildConfig{
        .commands_dir = "", // Not used in code generation
        .plugins_dir = null,
        .plugins = null,
        .app_name = "testapp",
        .app_version = "1.0.0",
        .app_description = "Test CLI application",
    };

    // Call the new function with no plugins
    const registry_source = try code_generation.generateComptimeRegistrySource(allocator, discovered, config, &.{});
    defer allocator.free(registry_source);

    // Verify the generated source contains expected elements
    try std.testing.expect(std.mem.indexOf(u8, registry_source, "pub const app_name = \"testapp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry_source, "pub const app_version = \"1.0.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry_source, "Test CLI application") != null);

    // Verify new comptime registry format
    try std.testing.expect(std.mem.indexOf(u8, registry_source, "pub const registry = zcli.Registry.init") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry_source, ".build();") != null);

    // Verify registry exports
    try std.testing.expect(std.mem.indexOf(u8, registry_source, "pub const Context = @TypeOf(registry).Context;") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry_source, "pub fn init(allocator: std.mem.Allocator)") != null);

    // Note: The new comptime registry approach doesn't need cleanup functions

    // The new comptime registry approach handles memory management differently
}

test "build integration: special command names" {
    const allocator = std.testing.allocator;
    var test_dir = try TestDir.init(allocator);
    defer test_dir.deinit();

    // Test command with name that's a Zig keyword
    try test_dir.createFile("test.zig", "pub fn execute() !void {}");

    var discovered = try build_utils.discoverCommands(allocator, test_dir.path);
    defer discovered.deinit();

    try std.testing.expect(discovered.root.contains("test"));

    // Generate registry to verify special name handling
    const config = build_utils.BuildConfig{
        .commands_dir = "", // Not used in code generation
        .plugins_dir = null,
        .plugins = null,
        .app_name = "testapp",
        .app_version = "1.0.0",
        .app_description = "Test CLI",
    };

    // Call the new function with no plugins
    const registry_source = try code_generation.generateComptimeRegistrySource(allocator, discovered, config, &.{});
    defer allocator.free(registry_source);

    // Verify that 'test' command is properly registered in new format
    try std.testing.expect(std.mem.indexOf(u8, registry_source, "cmd_test") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry_source, ".register(\"test\", cmd_test)") != null);
}

test "build integration: isValidCommandName function" {
    // Test the validation function directly
    try std.testing.expect(build_utils.isValidCommandName("hello"));
    try std.testing.expect(build_utils.isValidCommandName("hello-world"));
    try std.testing.expect(build_utils.isValidCommandName("hello_world"));
    try std.testing.expect(build_utils.isValidCommandName("hello123"));
    try std.testing.expect(build_utils.isValidCommandName("UPPERCASE"));
    try std.testing.expect(build_utils.isValidCommandName("Mixed-Case_123"));

    // Invalid names
    try std.testing.expect(!build_utils.isValidCommandName(""));
    try std.testing.expect(!build_utils.isValidCommandName("../traverse"));
    try std.testing.expect(!build_utils.isValidCommandName("hello/world"));
    try std.testing.expect(!build_utils.isValidCommandName("hello\\world"));
    try std.testing.expect(!build_utils.isValidCommandName(".hidden"));
    try std.testing.expect(!build_utils.isValidCommandName("hello world"));
    try std.testing.expect(!build_utils.isValidCommandName("hello@world"));
    try std.testing.expect(!build_utils.isValidCommandName("hello$world"));
    try std.testing.expect(!build_utils.isValidCommandName("hello;rm -rf"));
}

test "build integration: error handling for invalid paths" {
    const allocator = std.testing.allocator;

    // Test with non-existent directory
    const result = build_utils.discoverCommands(allocator, "/nonexistent/directory/path");
    try std.testing.expectError(error.FileNotFound, result);

    // Test with path traversal attempt
    const traversal_result = build_utils.discoverCommands(allocator, "../../../etc");
    try std.testing.expectError(error.InvalidPath, traversal_result);
}

test "build integration: performance with many commands" {
    const allocator = std.testing.allocator;
    var test_dir = try TestDir.init(allocator);
    defer test_dir.deinit();

    const num_commands = 100;
    const command_template =
        \\const zcli = @import("zcli");
        \\pub fn execute(args: struct{{}}, options: struct{{}}, context: *zcli.Context) !void {{
        \\    try context.stdout().print("Command {}\n", .{{{}}});
        \\}}
    ;

    // Create many commands
    var i: u32 = 0;
    while (i < num_commands) : (i += 1) {
        const filename = try std.fmt.allocPrint(allocator, "cmd{}.zig", .{i});
        defer allocator.free(filename);

        const content = try std.fmt.allocPrint(allocator, command_template, .{ i, i });
        defer allocator.free(content);

        try test_dir.createFile(filename, content);
    }

    // Measure discovery performance
    const start_time = std.time.nanoTimestamp();
    var discovered = try build_utils.discoverCommands(allocator, test_dir.path);
    defer discovered.deinit();
    const discovery_time = std.time.nanoTimestamp() - start_time;

    // Verify all commands were discovered
    try std.testing.expectEqual(@as(u32, num_commands), discovered.root.count());

    // Discovery should complete within reasonable time (adjust threshold as needed)
    const max_discovery_time_ns = 100_000_000; // 100ms
    try std.testing.expect(discovery_time < max_discovery_time_ns);

    // Measure registry generation performance
    const gen_start_time = std.time.nanoTimestamp();
    const config = build_utils.BuildConfig{
        .commands_dir = "", // Not used in code generation
        .plugins_dir = null,
        .plugins = null,
        .app_name = "perftest",
        .app_version = "1.0.0",
        .app_description = "Performance test CLI",
    };

    // Call the new function with no plugins
    const registry_source = try code_generation.generateComptimeRegistrySource(allocator, discovered, config, &.{});
    defer allocator.free(registry_source);
    const generation_time = std.time.nanoTimestamp() - gen_start_time;

    // Registry generation should also complete within reasonable time
    const max_generation_time_ns = 200_000_000; // 200ms
    try std.testing.expect(generation_time < max_generation_time_ns);

    // Verify generated source contains all commands
    i = 0;
    while (i < num_commands) : (i += 1) {
        const search_pattern = try std.fmt.allocPrint(allocator, ".register(\"cmd{}\", cmd_cmd{})", .{ i, i });
        defer allocator.free(search_pattern);
        try std.testing.expect(std.mem.indexOf(u8, registry_source, search_pattern) != null);
    }
}
