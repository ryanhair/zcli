const std = @import("std");
const types = @import("../build_utils/types.zig");
const zcli = @import("../zcli.zig");
const testing = std.testing;

const paths = @import("paths.zig");
const builder = @import("builder.zig");
const comptimeJoinPath = paths.comptimeJoinPath;
const sortedByPathLengthDesc = paths.sortedByPathLengthDesc;
const buildAliasPath = paths.buildAliasPath;
const pathsEqual = paths.pathsEqual;
const computeEntriesWithAliases = builder.computeEntriesWithAliases;
const Config = builder.Config;
const Registry = builder.Registry;

const build_utils = @import("../build_utils.zig");

// ============================================================================
// TEST HELPERS
// ============================================================================

/// Run the app with framework output captured — parse-error and group-help
/// tests otherwise spill onto the real stderr of every passing test run.
fn runQuiet(app: anytype, environ: *const std.process.Environ.Map, argv: []const []const u8) !void {
    var out_aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer out_aw.deinit();
    var err_aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer err_aw.deinit();
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    stdio.stdout_override = &out_aw.writer;
    stdio.stderr_override = &err_aw.writer;
    return app.executeWithStdio(testing.allocator, std.testing.io, environ, argv, &stdio);
}

fn createTestCommands(allocator: std.mem.Allocator) !types.DiscoveredCommands {
    var commands = types.DiscoveredCommands.init(allocator);

    // Create a pure command group (no index.zig)
    var network_subcommands = std.StringHashMap(types.DiscoveredCommand).init(allocator);

    // Create path array properly
    var network_ls_path = try allocator.alloc([]const u8, 2);
    network_ls_path[0] = try allocator.dupe(u8, "network");
    network_ls_path[1] = try allocator.dupe(u8, "ls");

    const network_ls = types.DiscoveredCommand{
        .name = try allocator.dupe(u8, "ls"),
        .path = network_ls_path,
        .file_path = try allocator.dupe(u8, "network/ls.zig"),
        .command_type = .leaf,
        .subcommands = null,
    };
    try network_subcommands.put(try allocator.dupe(u8, "ls"), network_ls);

    var network_path = try allocator.alloc([]const u8, 1);
    network_path[0] = try allocator.dupe(u8, "network");

    const network_group = types.DiscoveredCommand{
        .name = try allocator.dupe(u8, "network"),
        .path = network_path,
        .file_path = try allocator.dupe(u8, "network"), // No index.zig
        .command_type = .pure_group,
        .subcommands = network_subcommands,
    };
    try commands.root.put(try allocator.dupe(u8, "network"), network_group);

    // Create an optional command group (with index.zig)
    var container_subcommands = std.StringHashMap(types.DiscoveredCommand).init(allocator);
    var container_run_path = try allocator.alloc([]const u8, 2);
    container_run_path[0] = try allocator.dupe(u8, "container");
    container_run_path[1] = try allocator.dupe(u8, "run");

    const container_run = types.DiscoveredCommand{
        .name = try allocator.dupe(u8, "run"),
        .path = container_run_path,
        .file_path = try allocator.dupe(u8, "container/run.zig"),
        .command_type = .leaf,
        .subcommands = null,
    };
    try container_subcommands.put(try allocator.dupe(u8, "run"), container_run);

    var container_path = try allocator.alloc([]const u8, 1);
    container_path[0] = try allocator.dupe(u8, "container");

    const container_group = types.DiscoveredCommand{
        .name = try allocator.dupe(u8, "container"),
        .path = container_path,
        .file_path = try allocator.dupe(u8, "container/index.zig"),
        .command_type = .optional_group,
        .subcommands = container_subcommands,
    };
    try commands.root.put(try allocator.dupe(u8, "container"), container_group);

    // Create a leaf command
    var version_path = try allocator.alloc([]const u8, 1);
    version_path[0] = try allocator.dupe(u8, "version");

    const version_cmd = types.DiscoveredCommand{
        .name = try allocator.dupe(u8, "version"),
        .path = version_path,
        .file_path = try allocator.dupe(u8, "version.zig"),
        .command_type = .leaf,
        .subcommands = null,
    };
    try commands.root.put(try allocator.dupe(u8, "version"), version_cmd);

    return commands;
}

// ============================================================================
// COMMAND TYPE DETECTION TESTS
// ============================================================================

test "command type detection: pure group without index.zig" {
    const allocator = testing.allocator;
    var commands = try createTestCommands(allocator);
    defer commands.deinit();

    const network = commands.root.get("network").?;
    try testing.expect(network.command_type == .pure_group);
    try testing.expect(!std.mem.endsWith(u8, network.file_path, "index.zig"));
}

test "command type detection: optional group with index.zig" {
    const allocator = testing.allocator;
    var commands = try createTestCommands(allocator);
    defer commands.deinit();

    const container = commands.root.get("container").?;
    try testing.expect(container.command_type == .optional_group);
    try testing.expect(std.mem.endsWith(u8, container.file_path, "index.zig"));
}

test "command type detection: leaf command" {
    const allocator = testing.allocator;
    var commands = try createTestCommands(allocator);
    defer commands.deinit();

    const version = commands.root.get("version").?;
    try testing.expect(version.command_type == .leaf);
    try testing.expect(std.mem.endsWith(u8, version.file_path, ".zig"));
    try testing.expect(!std.mem.endsWith(u8, version.file_path, "index.zig"));
}

// ============================================================================
// CODE GENERATION TESTS
// ============================================================================

const code_generation = @import("../build_utils/code_generation.zig");

test "code generation: pure groups are not registered as commands" {
    const allocator = testing.allocator;
    var commands = try createTestCommands(allocator);
    defer commands.deinit();

    const config = types.BuildConfig{
        .commands_dir = "test/commands",
        .plugins_dir = null,
        .plugins = null,
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    };

    const source = try code_generation.generateComptimeRegistrySource(allocator, commands, config, &.{});
    defer allocator.free(source);

    // Pure group "network" should NOT be in .register() calls
    try testing.expect(std.mem.indexOf(u8, source, ".register(\"network\",") == null);

    // But its subcommand should be
    try testing.expect(std.mem.indexOf(u8, source, ".register(\"network ls\",") != null);

    // Optional group "container" SHOULD be registered
    try testing.expect(std.mem.indexOf(u8, source, ".register(\"container\",") != null);
}

test "code generation: pure groups listed in metadata" {
    const allocator = testing.allocator;
    var commands = try createTestCommands(allocator);
    defer commands.deinit();

    const config = types.BuildConfig{
        .commands_dir = "test/commands",
        .plugins_dir = null,
        .plugins = null,
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    };

    const source = try code_generation.generateComptimeRegistrySource(allocator, commands, config, &.{});
    defer allocator.free(source);

    // Should have pure_command_groups array
    try testing.expect(std.mem.indexOf(u8, source, "pub const pure_command_groups") != null);

    // Should list "network" as a pure group
    try testing.expect(std.mem.indexOf(u8, source, "&.{\"network\"}") != null);
}

// ============================================================================
// NESTED COMMAND GROUP TESTS
// ============================================================================

test "nested pure command groups" {
    const allocator = testing.allocator;
    var commands = types.DiscoveredCommands.init(allocator);
    defer commands.deinit();

    // Create nested structure: docker -> compose (pure) -> up (leaf)
    var compose_subcommands = std.StringHashMap(types.DiscoveredCommand).init(allocator);

    var compose_up_path = try allocator.alloc([]const u8, 3);
    compose_up_path[0] = try allocator.dupe(u8, "docker");
    compose_up_path[1] = try allocator.dupe(u8, "compose");
    compose_up_path[2] = try allocator.dupe(u8, "up");

    const compose_up = types.DiscoveredCommand{
        .name = try allocator.dupe(u8, "up"),
        .path = compose_up_path,
        .file_path = try allocator.dupe(u8, "docker/compose/up.zig"),
        .command_type = .leaf,
        .subcommands = null,
    };
    try compose_subcommands.put(try allocator.dupe(u8, "up"), compose_up);

    // Compose is a pure group (no index.zig)
    var compose_path = try allocator.alloc([]const u8, 2);
    compose_path[0] = try allocator.dupe(u8, "docker");
    compose_path[1] = try allocator.dupe(u8, "compose");

    const compose_group = types.DiscoveredCommand{
        .name = try allocator.dupe(u8, "compose"),
        .path = compose_path,
        .file_path = try allocator.dupe(u8, "docker/compose"),
        .command_type = .pure_group,
        .subcommands = compose_subcommands,
    };

    // Docker is an optional group
    var docker_subcommands = std.StringHashMap(types.DiscoveredCommand).init(allocator);
    try docker_subcommands.put(try allocator.dupe(u8, "compose"), compose_group);

    var docker_path = try allocator.alloc([]const u8, 1);
    docker_path[0] = try allocator.dupe(u8, "docker");

    const docker_group = types.DiscoveredCommand{
        .name = try allocator.dupe(u8, "docker"),
        .path = docker_path,
        .file_path = try allocator.dupe(u8, "docker/index.zig"),
        .command_type = .optional_group,
        .subcommands = docker_subcommands,
    };
    try commands.root.put(try allocator.dupe(u8, "docker"), docker_group);

    // Generate code
    const config = types.BuildConfig{
        .commands_dir = "test/commands",
        .plugins_dir = null,
        .plugins = null,
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    };

    const source = try code_generation.generateComptimeRegistrySource(allocator, commands, config, &.{});
    defer allocator.free(source);

    // Nested pure group should be in metadata
    try testing.expect(std.mem.indexOf(u8, source, "&.{\"docker\", \"compose\"}") != null);

    // Should NOT be registered as a command
    try testing.expect(std.mem.indexOf(u8, source, ".register(\"docker compose\",") == null);

    // But the leaf command under it should be
    try testing.expect(std.mem.indexOf(u8, source, ".register(\"docker compose up\",") != null);
}

// ============================================================================
// VALIDATION TESTS
// ============================================================================

// Test structures for compile-time validation
const ValidOptionalGroup = struct {
    pub const Args = struct {};
    pub const Options = struct {
        verbose: bool = false,
    };
    pub fn execute(_: Args, _: Options, _: *zcli.Context) !void {}
};

const InvalidOptionalGroup = struct {
    pub const Args = struct {
        name: []const u8, // This should fail validation!
    };
    pub const Options = struct {};
    pub fn execute(_: Args, _: Options, _: *zcli.Context) !void {}
};

test "validation: optional group with empty Args is valid" {
    // This should compile without issues
    const TestRegistry = Registry.init(.{
        .app_name = "test",
        .app_version = "1.0.0",
        .app_description = "test",
    })
        .register("group", ValidOptionalGroup)
        .register("group sub", ValidOptionalGroup) // Makes "group" a group with subcommands
        .build();
    _ = TestRegistry;

    try testing.expect(true); // If we get here, compilation succeeded
}

// This test is commented out because it would cause a compile error (which is what we want!)
// Uncomment to verify the validation works
// test "validation: optional group with Args fields fails" {
//     const TestRegistry = Registry.init(.{
//         .app_name = "test",
//         .app_version = "1.0.0",
//         .app_description = "test",
//     })
//         .register("group", InvalidOptionalGroup)
//         .register("group sub", ValidOptionalGroup)
//         .build();
// }

// ============================================================================
// EDGE CASES
// ============================================================================

test "empty pure command group without subcommands" {
    const allocator = testing.allocator;
    var commands = types.DiscoveredCommands.init(allocator);
    defer commands.deinit();

    // According to the discovery logic, empty directories are not included
    // This test documents that behavior

    // An empty pure group would not be discovered
    try testing.expect(commands.root.count() == 0);
}

test "command path array handling" {
    const allocator = testing.allocator;
    var commands = try createTestCommands(allocator);
    defer commands.deinit();

    const network = commands.root.get("network").?;
    try testing.expect(network.path.len == 1);
    try testing.expectEqualStrings("network", network.path[0]);

    const network_ls = network.subcommands.?.get("ls").?;
    try testing.expect(network_ls.path.len == 2);
    try testing.expectEqualStrings("network", network_ls.path[0]);
    try testing.expectEqualStrings("ls", network_ls.path[1]);
}

test "mixed command types in same parent" {
    const allocator = testing.allocator;
    var commands = types.DiscoveredCommands.init(allocator);
    defer commands.deinit();

    // Create a structure with both pure and optional groups at same level
    var app_subcommands = std.StringHashMap(types.DiscoveredCommand).init(allocator);

    // Pure group
    var pure_subcommands = std.StringHashMap(types.DiscoveredCommand).init(allocator);

    var pure_cmd_path = try allocator.alloc([]const u8, 2);
    pure_cmd_path[0] = try allocator.dupe(u8, "pure");
    pure_cmd_path[1] = try allocator.dupe(u8, "list");

    const pure_cmd = types.DiscoveredCommand{
        .name = try allocator.dupe(u8, "list"),
        .path = pure_cmd_path,
        .file_path = try allocator.dupe(u8, "pure/list.zig"),
        .command_type = .leaf,
        .subcommands = null,
    };
    try pure_subcommands.put(try allocator.dupe(u8, "list"), pure_cmd);

    var pure_path = try allocator.alloc([]const u8, 1);
    pure_path[0] = try allocator.dupe(u8, "pure");

    const pure_group = types.DiscoveredCommand{
        .name = try allocator.dupe(u8, "pure"),
        .path = pure_path,
        .file_path = try allocator.dupe(u8, "pure"),
        .command_type = .pure_group,
        .subcommands = pure_subcommands,
    };
    try app_subcommands.put(try allocator.dupe(u8, "pure"), pure_group);

    // Optional group
    var optional_subcommands = std.StringHashMap(types.DiscoveredCommand).init(allocator);

    var optional_cmd_path = try allocator.alloc([]const u8, 2);
    optional_cmd_path[0] = try allocator.dupe(u8, "optional");
    optional_cmd_path[1] = try allocator.dupe(u8, "exec");

    const optional_cmd = types.DiscoveredCommand{
        .name = try allocator.dupe(u8, "exec"),
        .path = optional_cmd_path,
        .file_path = try allocator.dupe(u8, "optional/exec.zig"),
        .command_type = .leaf,
        .subcommands = null,
    };
    try optional_subcommands.put(try allocator.dupe(u8, "exec"), optional_cmd);

    var optional_path = try allocator.alloc([]const u8, 1);
    optional_path[0] = try allocator.dupe(u8, "optional");

    const optional_group = types.DiscoveredCommand{
        .name = try allocator.dupe(u8, "optional"),
        .path = optional_path,
        .file_path = try allocator.dupe(u8, "optional/index.zig"),
        .command_type = .optional_group,
        .subcommands = optional_subcommands,
    };
    try app_subcommands.put(try allocator.dupe(u8, "optional"), optional_group);

    // Both should coexist properly
    commands.root = app_subcommands;

    const pure = commands.root.get("pure").?;
    const optional = commands.root.get("optional").?;

    try testing.expect(pure.command_type == .pure_group);
    try testing.expect(optional.command_type == .optional_group);
}

// Test command modules to simulate the nested command scenario
const RootCommand = struct {
    pub const meta = .{
        .description = "Root command",
    };

    pub const Args = struct {};
    pub const Options = struct {};

    pub fn execute(_: Args, _: Options, context: anytype) !void {
        try context.io.stdout.print("root executed\n", .{});
    }
};

const NestedCommand = struct {
    pub const meta = .{
        .description = "Nested command",
    };

    pub const Args = struct {
        name: []const u8,
    };
    pub const Options = struct {
        force: bool = false,
    };

    pub fn execute(args: Args, options: Options, context: anytype) !void {
        try context.io.stdout.print("nested executed: name={s}, force={}\n", .{ args.name, options.force });
    }
};

// Create a test registry with nested command paths to test longest-match routing
fn createTestRegistry(comptime config: Config) type {
    return Registry.init(config)
        .register("container", RootCommand) // 1 component
        .register("container run", NestedCommand) // 2 components
        .build();
}

test "command routing: longest match wins for nested commands" {
    // Create test registry
    const config = Config{
        .app_name = "test",
        .app_version = "1.0.0",
        .app_description = "Test CLI",
    };

    const TestApp = createTestRegistry(config);

    // Test that "container run arg" routes to NestedCommand (2 components)
    // not RootCommand (1 component)

    // Check that commands are properly registered
    const commands = TestApp.commands;
    var found_root = false;
    var found_nested = false;

    inline for (commands) |cmd| {
        if (std.mem.eql(u8, cmd.path[0], "container")) {
            if (cmd.path.len == 1) {
                found_root = true;
                try testing.expect(cmd.module == RootCommand);
            } else if (cmd.path.len == 2 and std.mem.eql(u8, cmd.path[1], "run")) {
                found_nested = true;
                try testing.expect(cmd.module == NestedCommand);
            }
        }
    }

    try testing.expect(found_root);
    try testing.expect(found_nested);

    // Test command path sorting - longer paths should come first (the same
    // comptime sort execute() uses for routing)
    const sorted_commands = comptime sortedByPathLengthDesc(commands);

    // Verify that longer commands come first in sorted order
    var prev_length: usize = std.math.maxInt(usize);
    inline for (sorted_commands) |cmd| {
        try testing.expect(cmd.path.len <= prev_length);
        prev_length = cmd.path.len;
    }

    // Test command matching logic (simulating the registry matching algorithm)
    const test_args = [_][]const u8{ "container", "run", "myapp" };

    // Find the longest matching command
    var best_match_length: usize = 0;
    var best_match_found = false;
    var best_match_is_nested = false;

    inline for (sorted_commands) |cmd| {
        const parts_count = cmd.path.len;

        if (parts_count <= test_args.len and parts_count > best_match_length) {
            // Check if all parts match
            var parts_match = true;
            for (cmd.path, 0..) |part, i| {
                if (i >= test_args.len or !std.mem.eql(u8, part, test_args[i])) {
                    parts_match = false;
                    break;
                }
            }

            if (parts_match) {
                best_match_found = true;
                best_match_length = parts_count;
                best_match_is_nested = (cmd.module == NestedCommand);
            }
        }
    }

    // Verify that the nested command (2 components) was selected
    // over the root command (1 component)
    try testing.expect(best_match_found);
    try testing.expect(best_match_length == 2);
    try testing.expect(best_match_is_nested);
}

test "command routing: exact match for single component commands" {
    // Create test registry
    const config = Config{
        .app_name = "test",
        .app_version = "1.0.0",
        .app_description = "Test CLI",
    };

    const TestApp = createTestRegistry(config);

    // Test that "container" routes to RootCommand when there's no longer match
    const test_args = [_][]const u8{"container"};
    const commands = TestApp.commands;

    // Find the longest matching command
    var best_match_length: usize = 0;
    var best_match_found = false;
    var best_match_is_root = false;

    inline for (commands) |cmd| {
        const parts_count = cmd.path.len;

        if (parts_count <= test_args.len and parts_count > best_match_length) {
            // Check if all parts match
            var parts_match = true;
            for (cmd.path, 0..) |part, i| {
                if (i >= test_args.len or !std.mem.eql(u8, part, test_args[i])) {
                    parts_match = false;
                    break;
                }
            }

            if (parts_match) {
                best_match_found = true;
                best_match_length = parts_count;
                best_match_is_root = (cmd.module == RootCommand);
            }
        }
    }

    // Verify that the root command (1 component) was selected
    try testing.expect(best_match_found);
    try testing.expect(best_match_length == 1);
    try testing.expect(best_match_is_root);
}

test "command routing: no partial matches" {
    // Create test registry
    const config = Config{
        .app_name = "test",
        .app_version = "1.0.0",
        .app_description = "Test CLI",
    };

    const TestApp = createTestRegistry(config);

    // Test that "container start" doesn't match any command
    // (we only have "container" and "container run")
    const test_args = [_][]const u8{ "container", "start" };
    const commands = TestApp.commands;

    // Find the longest matching command
    var best_match_length: usize = 0;
    var best_match_found = false;

    inline for (commands) |cmd| {
        const parts_count = cmd.path.len;

        if (parts_count <= test_args.len and parts_count > best_match_length) {
            // Check if all parts match
            var parts_match = true;
            for (cmd.path, 0..) |part, i| {
                if (i >= test_args.len or !std.mem.eql(u8, part, test_args[i])) {
                    parts_match = false;
                    break;
                }
            }

            if (parts_match) {
                best_match_found = true;
                best_match_length = parts_count;
            }
        }
    }

    // Should match "container" (1 component) but not "container start"
    try testing.expect(best_match_found);
    try testing.expect(best_match_length == 1); // Only matches "container", not "container start"
}

// ============================================================================
// PURE COMMAND GROUP TESTS
// Tests for the new command group architecture where pure command groups
// (directories without index.zig) always show help and never execute.
// ============================================================================

// Test command modules
const NetworkLs = struct {
    pub const meta = .{
        .description = "List networks",
    };
    pub const Args = struct {};
    pub const Options = struct {};
    pub fn execute(_: Args, _: Options, context: anytype) !void {
        // Test command - no output needed
        _ = context;
    }
};

const TestHelpPlugin = struct {
    pub const priority = 100;

    var help_shown = false;
    var command_found_error = false;

    pub fn reset() void {
        help_shown = false;
        command_found_error = false;
    }

    pub fn onError(context: anytype, err: anyerror) !bool {
        _ = context;
        if (err == error.CommandNotFound) {
            command_found_error = true;
            help_shown = true;
            return true; // Handle the error - this simulates help plugin behavior
        }
        return false;
    }
};

// Create a test registry that simulates pure command groups
fn createPureCommandTestRegistry() type {
    // Only register leaf commands - pure command groups are NOT registered
    return Registry.init(.{
        .app_name = "test-cli",
        .app_version = "1.0.0",
        .app_description = "Test CLI with pure command groups",
    })
        .register("network ls", NetworkLs) // Only the leaf command is registered
        .registerPlugin(TestHelpPlugin)
        .build();
}

test "pure command group behavior: always shows help without error" {
    const TestApp = createPureCommandTestRegistry();
    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    // Test 1: Pure command group without --help should show help and succeed
    TestHelpPlugin.reset();
    try runQuiet(&app, &test_environ, &.{"network"});

    // Should have triggered CommandNotFound -> help showing -> error handled
    try testing.expect(TestHelpPlugin.help_shown);
    try testing.expect(TestHelpPlugin.command_found_error);

    // Test 2: Pure command group with --help should also show help and succeed
    TestHelpPlugin.reset();
    try runQuiet(&app, &test_environ, &.{ "network", "--help" });

    // Should have triggered help showing (same behavior regardless of --help)
    try testing.expect(TestHelpPlugin.help_shown);
}

test "pure command group: subcommands execute normally" {
    const TestApp = createPureCommandTestRegistry();
    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    // Subcommand should execute normally without help plugin intervention
    TestHelpPlugin.reset();
    try runQuiet(&app, &test_environ, &.{ "network", "ls" });
    try testing.expect(!TestHelpPlugin.command_found_error); // Should not hit CommandNotFound
}

test "error handling: plugin returns true prevents error propagation" {
    const TestApp = createPureCommandTestRegistry();
    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    // This tests the fix - when a plugin handles CommandNotFound by returning true,
    // the registry should not propagate the error
    TestHelpPlugin.reset();
    try runQuiet(&app, &test_environ, &.{"nonexistent"});

    // Plugin should have handled the error
    try testing.expect(TestHelpPlugin.command_found_error);
    try testing.expect(TestHelpPlugin.help_shown);
}

// ============================================================================
// Execution-path semantics (guard the executeResolvedCommand refactor):
// metadata-only groups, and error/postExecute dispatch.
// ============================================================================

const MetadataOnlyGroup = struct {
    pub const meta = .{
        .description = "A command group registered without an execute function",
    };
};

test "metadata-only group without a handling plugin reports CommandNotFound" {
    const TestApp = Registry.init(.{
        .app_name = "test",
        .app_version = "1.0.0",
        .app_description = "test",
    })
        .register("group", MetadataOnlyGroup)
        .build();
    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    // No plugin handles CommandNotFound: the group message is printed (stderr
    // noise below is expected) and the error propagates — invoking a bare
    // group is not a success.
    try testing.expectError(
        error.CommandNotFound,
        runQuiet(&app, &test_environ, &.{"group"}),
    );
}

test "metadata-only group routes through onError so the help plugin can render it" {
    const TestApp = Registry.init(.{
        .app_name = "test",
        .app_version = "1.0.0",
        .app_description = "test",
    })
        .register("group", MetadataOnlyGroup)
        .registerPlugin(TestHelpPlugin)
        .build();
    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    TestHelpPlugin.reset();
    try runQuiet(&app, &test_environ, &.{"group"});
    try testing.expect(TestHelpPlugin.command_found_error);
}

const OkCommand = struct {
    pub const Args = struct {};
    pub const Options = struct {};
    pub fn execute(_: Args, _: Options, context: anytype) !void {
        _ = context;
    }
};

const FailingCommand = struct {
    pub const Args = struct {};
    pub const Options = struct {};
    pub fn execute(_: Args, _: Options, context: anytype) !void {
        _ = context;
        return error.Boom;
    }
};

const PostExecuteCapturePlugin = struct {
    var post_execute_success: ?bool = null;
    var seen_error: ?anyerror = null;

    pub fn reset() void {
        post_execute_success = null;
        seen_error = null;
    }

    pub fn onError(context: anytype, err: anyerror) !bool {
        _ = context;
        seen_error = err;
        return err == error.Boom; // handle command failures, not routing errors
    }

    pub fn postExecute(context: anytype, success: bool) !void {
        _ = context;
        post_execute_success = success;
    }
};

fn createPostExecuteTestRegistry() type {
    return Registry.init(.{
        .app_name = "test",
        .app_version = "1.0.0",
        .app_description = "test",
    })
        .register("ok", OkCommand)
        .register("fail", FailingCommand)
        .registerPlugin(PostExecuteCapturePlugin)
        .build();
}

test "successful execution reaches postExecute with success=true" {
    const TestApp = createPostExecuteTestRegistry();
    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    PostExecuteCapturePlugin.reset();
    try runQuiet(&app, &test_environ, &.{"ok"});
    try testing.expectEqual(@as(?bool, true), PostExecuteCapturePlugin.post_execute_success);
    try testing.expectEqual(@as(?anyerror, null), PostExecuteCapturePlugin.seen_error);
}

test "handled execution error is suppressed and reaches postExecute with success=false" {
    const TestApp = createPostExecuteTestRegistry();
    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    PostExecuteCapturePlugin.reset();
    // onError handles error.Boom, so execute() must not propagate it — but
    // postExecute still observes the failure.
    try runQuiet(&app, &test_environ, &.{"fail"});
    try testing.expectEqual(@as(?anyerror, error.Boom), PostExecuteCapturePlugin.seen_error);
    try testing.expectEqual(@as(?bool, false), PostExecuteCapturePlugin.post_execute_success);
}

test "comptimeJoinPath joins components with spaces" {
    try testing.expectEqualStrings("container run", comptime comptimeJoinPath(&.{ "container", "run" }));
    try testing.expectEqualStrings("root", comptime comptimeJoinPath(&.{"root"}));
    try testing.expectEqualStrings("", comptime comptimeJoinPath(&.{}));
}

test "sortedByPathLengthDesc handles an empty command list" {
    // Regression: the sort used `i < len - 1`, which underflows usize at
    // comptime for a registry with zero regular commands (plugin-only).
    const Entry = struct { path: []const []const u8 };
    const none: [0]Entry = .{};
    const sorted = comptime sortedByPathLengthDesc(&none);
    try testing.expectEqual(@as(usize, 0), sorted.len);
}

// Regression fixture: a registry whose ONLY command comes from a plugin, with
// slice-typed Args/Options fields. Exercises two comptime paths that used to
// be compile errors when first reached: the zero-command routing sort (usize
// underflow) and FieldInfo extraction for slice fields (`.Slice` is not a
// valid `std.builtin.Type.Pointer.Size` literal in 0.16 — it's `.slice`).
const SliceFieldPlugin = struct {
    var executed = false;
    var tag_count: usize = 0;

    pub fn reset() void {
        executed = false;
        tag_count = 0;
    }

    pub const commands = struct {
        pub const tagged = struct {
            pub const meta = .{ .description = "test command with slice fields" };
            pub const Args = struct {
                tags: []const []const u8,
            };
            pub const Options = struct {
                labels: []const []const u8 = &.{},
            };
            pub fn execute(args: Args, options: Options, context: anytype) !void {
                _ = options;
                _ = context;
                SliceFieldPlugin.executed = true;
                SliceFieldPlugin.tag_count = args.tags.len;
            }
        };
    };
};

test "plugin-only registry routes and executes a plugin command with slice fields" {
    const TestApp = Registry.init(.{
        .app_name = "plugin-only",
        .app_version = "1.0.0",
        .app_description = "Registry with zero regular commands",
    })
        .registerPlugin(SliceFieldPlugin)
        .build();

    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    SliceFieldPlugin.reset();
    try runQuiet(&app, &test_environ, &.{ "tagged", "a", "b" });

    try testing.expect(SliceFieldPlugin.executed);
    try testing.expectEqual(@as(usize, 2), SliceFieldPlugin.tag_count);
}

// ============================================================================
// Alias Tests
// ============================================================================

test "buildAliasPath: top-level command" {
    // Top-level command ["ls"] with alias "list" should produce ["list"]
    const original_path = &[_][]const u8{"ls"};
    const alias_path = comptime buildAliasPath(original_path, "list");

    try testing.expectEqual(@as(usize, 1), alias_path.len);
    try testing.expectEqualStrings("list", alias_path[0]);
}

test "buildAliasPath: nested command" {
    // Nested command ["container", "ls"] with alias "list" should produce ["container", "list"]
    const original_path = &[_][]const u8{ "container", "ls" };
    const alias_path = comptime buildAliasPath(original_path, "list");

    try testing.expectEqual(@as(usize, 2), alias_path.len);
    try testing.expectEqualStrings("container", alias_path[0]);
    try testing.expectEqualStrings("list", alias_path[1]);
}

test "buildAliasPath: deeply nested command" {
    // Deeply nested command ["a", "b", "c"] with alias "d" should produce ["a", "b", "d"]
    const original_path = &[_][]const u8{ "a", "b", "c" };
    const alias_path = comptime buildAliasPath(original_path, "d");

    try testing.expectEqual(@as(usize, 3), alias_path.len);
    try testing.expectEqualStrings("a", alias_path[0]);
    try testing.expectEqualStrings("b", alias_path[1]);
    try testing.expectEqualStrings("d", alias_path[2]);
}

test "pathsEqual: equal paths" {
    const path1 = &[_][]const u8{ "container", "ls" };
    const path2 = &[_][]const u8{ "container", "ls" };
    try testing.expect(pathsEqual(path1, path2));
}

test "pathsEqual: different lengths" {
    const path1 = &[_][]const u8{ "container", "ls" };
    const path2 = &[_][]const u8{"container"};
    try testing.expect(!pathsEqual(path1, path2));
}

test "pathsEqual: different components" {
    const path1 = &[_][]const u8{ "container", "ls" };
    const path2 = &[_][]const u8{ "container", "list" };
    try testing.expect(!pathsEqual(path1, path2));
}

test "pathsEqual: empty paths" {
    const path1: []const []const u8 = &.{};
    const path2: []const []const u8 = &.{};
    try testing.expect(pathsEqual(path1, path2));
}

// Test command with aliases for registration tests
const AliasTestCommand = struct {
    pub const meta = .{
        .description = "Test command with aliases",
        .aliases = &.{ "alias1", "alias2" },
    };
    pub const Args = struct {};
    pub const Options = struct {};
    pub fn execute(_: Args, _: Options, _: *zcli.Context) !void {}
};

const NoAliasTestCommand = struct {
    pub const meta = .{
        .description = "Test command without aliases",
    };
    pub const Args = struct {};
    pub const Options = struct {};
    pub fn execute(_: Args, _: Options, _: *zcli.Context) !void {}
};

test "alias registration: creates multiple command entries" {
    // Test that computeEntriesWithAliases creates entries for primary + aliases
    const entries = comptime computeEntriesWithAliases(&.{}, "test", AliasTestCommand);

    // Should have 3 entries: primary "test", alias "alias1", alias "alias2"
    try testing.expectEqual(@as(usize, 3), entries.len);
}

test "alias registration: all entries point to same module" {
    const entries = comptime computeEntriesWithAliases(&.{}, "test", AliasTestCommand);

    // All entries should point to the same module
    inline for (entries) |entry| {
        try testing.expect(entry.module == AliasTestCommand);
    }
}

test "alias registration: command without aliases creates single entry" {
    const entries = comptime computeEntriesWithAliases(&.{}, "test", NoAliasTestCommand);

    // Should have only 1 entry
    try testing.expectEqual(@as(usize, 1), entries.len);
}

// Regression fixture for the diagnostic pipeline: a plugin that records what
// context.diagnostic held when its onError hook ran, plus a command with a
// typed option to fail parsing against.
const DiagnosticCapturePlugin = struct {
    var captured: ?zcli.ZcliDiagnostic = null;
    var captured_err: ?anyerror = null;

    pub fn reset() void {
        captured = null;
        captured_err = null;
    }

    pub fn onError(context: anytype, err: anyerror) !bool {
        captured = context.diagnostic;
        captured_err = err;
        return true; // handled — suppress
    }

    pub const commands = struct {
        pub const ping = struct {
            pub const meta = .{ .description = "ping with a typed option" };
            pub const Args = struct {};
            pub const Options = struct { count: u32 = 1 };
            pub fn execute(args: Args, options: Options, context: anytype) !void {
                _ = args;
                _ = options;
                _ = context;
            }
        };
    };
};

test "parse errors run onError with context.diagnostic populated" {
    const TestApp = Registry.init(.{
        .app_name = "diag-test",
        .app_version = "1.0.0",
        .app_description = "diagnostic pipeline test",
    })
        .registerPlugin(DiagnosticCapturePlugin)
        .build();

    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    // Unknown option: the plugin sees the error AND the precise diagnostic.
    DiagnosticCapturePlugin.reset();
    try runQuiet(&app, &test_environ, &.{ "ping", "--bogus" });
    try testing.expectEqual(@as(?anyerror, error.OptionUnknown), DiagnosticCapturePlugin.captured_err);
    try testing.expectEqualStrings("bogus", DiagnosticCapturePlugin.captured.?.OptionUnknown.option_name);

    // Invalid value: same pipeline, different diagnostic payload.
    DiagnosticCapturePlugin.reset();
    try runQuiet(&app, &test_environ, &.{ "ping", "--count", "lots" });
    try testing.expectEqual(@as(?anyerror, error.OptionInvalidValue), DiagnosticCapturePlugin.captured_err);
    try testing.expectEqualStrings("lots", DiagnosticCapturePlugin.captured.?.OptionInvalidValue.provided_value);
    try testing.expectEqualStrings("count", DiagnosticCapturePlugin.captured.?.OptionInvalidValue.option_name);
}

// Fixture for the typed-global-options pipeline: declares one global of each
// supported category (also exercising declaration-time type validation),
// records what handleGlobalOption receives, and captures parse failures.
const TypedGlobalsPlugin = struct {
    var level: i64 = -1;
    var ratio: f64 = 0;
    var label: []const u8 = "";
    var verbose: bool = false;
    var debug: bool = false;
    var captured_err: ?anyerror = null;
    var captured_diag: ?zcli.ZcliDiagnostic = null;
    var command_ran: bool = false;

    pub fn reset() void {
        level = -1;
        ratio = 0;
        label = "";
        verbose = false;
        debug = false;
        captured_err = null;
        captured_diag = null;
        command_ran = false;
    }

    pub const global_options = [_]zcli.GlobalOption{
        zcli.option("level", i64, .{ .short = 'l', .description = "level" }),
        zcli.option("ratio", f64, .{ .description = "ratio" }),
        zcli.option("label", []const u8, .{ .description = "label" }),
        zcli.option("verbose", bool, .{ .short = 'v', .description = "verbose" }),
        zcli.option("debug", bool, .{ .short = 'd', .description = "debug" }),
    };

    pub fn handleGlobalOption(context: anytype, name: []const u8, value: anytype) !void {
        _ = context;
        const T = @TypeOf(value);
        if (comptime T == i64) {
            level = value;
        } else if (comptime T == f64) {
            ratio = value;
        } else if (comptime T == []const u8) {
            label = value;
        } else if (comptime T == bool) {
            if (std.mem.eql(u8, name, "verbose")) verbose = value;
            if (std.mem.eql(u8, name, "debug")) debug = value;
        }
    }

    pub fn onError(context: anytype, err: anyerror) !bool {
        captured_err = err;
        captured_diag = context.diagnostic;
        return true;
    }

    pub const commands = struct {
        pub const ping = struct {
            pub const meta = .{ .description = "noop" };
            pub const Args = struct {};
            pub const Options = struct {};
            pub fn execute(args: Args, options: Options, context: anytype) !void {
                _ = args;
                _ = options;
                _ = context;
                TypedGlobalsPlugin.command_ran = true;
            }
        };
    };
};

fn typedGlobalsApp() type {
    return Registry.init(.{
        .app_name = "globals-test",
        .app_version = "1.0.0",
        .app_description = "typed global options",
    })
        .registerPlugin(TypedGlobalsPlugin)
        .build();
}

test "global options: full type set converts and dispatches" {
    const TestApp = typedGlobalsApp();
    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    TypedGlobalsPlugin.reset();
    try runQuiet(&app, &test_environ, &.{ "--level", "5", "--ratio", "1.5", "--label", "hi", "-v", "ping" });
    try testing.expectEqual(@as(i64, 5), TypedGlobalsPlugin.level);
    try testing.expectEqual(@as(f64, 1.5), TypedGlobalsPlugin.ratio);
    try testing.expectEqualStrings("hi", TypedGlobalsPlugin.label);
    try testing.expect(TypedGlobalsPlugin.verbose);
    try testing.expect(TypedGlobalsPlugin.command_ran);
}

test "global options: short options take values (no more assume-boolean)" {
    const TestApp = typedGlobalsApp();
    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    TypedGlobalsPlugin.reset();
    try runQuiet(&app, &test_environ, &.{ "-l", "7", "ping" });
    try testing.expectEqual(@as(i64, 7), TypedGlobalsPlugin.level);
    try testing.expect(TypedGlobalsPlugin.command_ran);

    // Negative values pass the shared next-token rule.
    TypedGlobalsPlugin.reset();
    try runQuiet(&app, &test_environ, &.{ "--level", "-5", "ping" });
    try testing.expectEqual(@as(i64, -5), TypedGlobalsPlugin.level);
}

test "global options: boolean bundles are all-or-nothing" {
    const TestApp = typedGlobalsApp();
    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    // All chars are boolean globals: both dispatch.
    TypedGlobalsPlugin.reset();
    try runQuiet(&app, &test_environ, &.{ "-vd", "ping" });
    try testing.expect(TypedGlobalsPlugin.verbose);
    try testing.expect(TypedGlobalsPlugin.debug);
    try testing.expect(TypedGlobalsPlugin.command_ran);

    // A bundle containing a non-global char is left for the command parser
    // (which reports it, instead of the old behavior: consuming the token
    // and silently dropping the unknown chars).
    TypedGlobalsPlugin.reset();
    try runQuiet(&app, &test_environ, &.{ "ping", "-vx" });
    try testing.expectEqual(@as(?anyerror, error.OptionUnknown), TypedGlobalsPlugin.captured_err);
    try testing.expect(!TypedGlobalsPlugin.command_ran);
}

test "global options: missing and invalid values produce diagnostics" {
    const TestApp = typedGlobalsApp();
    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    // Value missing at end of argv.
    TypedGlobalsPlugin.reset();
    try runQuiet(&app, &test_environ, &.{"--level"});
    try testing.expectEqual(@as(?anyerror, error.OptionMissingValue), TypedGlobalsPlugin.captured_err);
    try testing.expectEqualStrings("level", TypedGlobalsPlugin.captured_diag.?.OptionMissingValue.option_name);

    // Next token is a flag, not a value.
    TypedGlobalsPlugin.reset();
    try runQuiet(&app, &test_environ, &.{ "--level", "--verbose" });
    try testing.expectEqual(@as(?anyerror, error.OptionMissingValue), TypedGlobalsPlugin.captured_err);

    // Unparseable value.
    TypedGlobalsPlugin.reset();
    try runQuiet(&app, &test_environ, &.{ "--level", "abc", "ping" });
    try testing.expectEqual(@as(?anyerror, error.OptionInvalidValue), TypedGlobalsPlugin.captured_err);
    try testing.expectEqualStrings("abc", TypedGlobalsPlugin.captured_diag.?.OptionInvalidValue.provided_value);
    try testing.expectEqualStrings("i64", TypedGlobalsPlugin.captured_diag.?.OptionInvalidValue.expected_type);
}

// ============================================================================
// Option constraints (ADR-0022) — end-to-end through the wired registry
// ============================================================================

// Captures the constraint diagnostics so the assertions can read the offending
// names, and swallows the error so runQuiet returns cleanly.
const ConstraintCapturePlugin = struct {
    var captured_err: ?anyerror = null;
    var captured_diag: ?zcli.ZcliDiagnostic = null;
    var command_ran: bool = false;

    pub fn reset() void {
        captured_err = null;
        captured_diag = null;
        command_ran = false;
    }

    pub fn onError(context: anytype, err: anyerror) !bool {
        captured_err = err;
        captured_diag = context.diagnostic;
        return true;
    }
};

// --json/--yaml/--xml are mutually exclusive; --output-format requires --output.
const ConstrainedCommand = struct {
    pub const meta = .{
        .description = "constrained",
        .exclusive = .{.{ .json, .yaml, .xml }},
        .options = .{
            .output_format = .{ .requires = .{.output} },
        },
    };
    pub const Args = struct {};
    pub const Options = struct {
        json: bool = false,
        yaml: bool = false,
        xml: bool = false,
        output: ?[]const u8 = null,
        output_format: ?enum { pretty, compact } = null,
    };
    pub fn execute(_: Args, _: Options, _: anytype) !void {
        ConstraintCapturePlugin.command_ran = true;
    }
};

fn constrainedApp() type {
    return Registry.init(.{
        .app_name = "constraints-test",
        .app_version = "1.0.0",
        .app_description = "option constraints",
    })
        .register("run", ConstrainedCommand)
        .registerPlugin(ConstraintCapturePlugin)
        .build();
}

test "constraints e2e: exclusive members together are rejected" {
    var app = constrainedApp().init();
    const env = std.process.Environ.Map.init(testing.allocator);

    ConstraintCapturePlugin.reset();
    try runQuiet(&app, &env, &.{ "run", "--json", "--yaml" });
    try testing.expectEqual(@as(?anyerror, error.OptionMutuallyExclusive), ConstraintCapturePlugin.captured_err);
    try testing.expectEqualStrings("json", ConstraintCapturePlugin.captured_diag.?.OptionMutuallyExclusive.first);
    try testing.expectEqualStrings("yaml", ConstraintCapturePlugin.captured_diag.?.OptionMutuallyExclusive.second);
    try testing.expect(!ConstraintCapturePlugin.command_ran);
}

test "constraints e2e: one exclusive member is fine" {
    var app = constrainedApp().init();
    const env = std.process.Environ.Map.init(testing.allocator);

    ConstraintCapturePlugin.reset();
    try runQuiet(&app, &env, &.{ "run", "--yaml" });
    try testing.expectEqual(@as(?anyerror, null), ConstraintCapturePlugin.captured_err);
    try testing.expect(ConstraintCapturePlugin.command_ran);
}

test "constraints e2e: requires without its dependency is rejected" {
    var app = constrainedApp().init();
    const env = std.process.Environ.Map.init(testing.allocator);

    ConstraintCapturePlugin.reset();
    try runQuiet(&app, &env, &.{ "run", "--output-format", "pretty" });
    try testing.expectEqual(@as(?anyerror, error.OptionMissingDependency), ConstraintCapturePlugin.captured_err);
    try testing.expectEqualStrings("output-format", ConstraintCapturePlugin.captured_diag.?.OptionMissingDependency.option_name);
    try testing.expectEqualStrings("output", ConstraintCapturePlugin.captured_diag.?.OptionMissingDependency.required_name);
    try testing.expect(!ConstraintCapturePlugin.command_ran);
}

test "constraints e2e: requires satisfied by its dependency runs" {
    var app = constrainedApp().init();
    const env = std.process.Environ.Map.init(testing.allocator);

    ConstraintCapturePlugin.reset();
    try runQuiet(&app, &env, &.{ "run", "--output-format", "pretty", "--output", "out.txt" });
    try testing.expectEqual(@as(?anyerror, null), ConstraintCapturePlugin.captured_err);
    try testing.expect(ConstraintCapturePlugin.command_ran);
}
