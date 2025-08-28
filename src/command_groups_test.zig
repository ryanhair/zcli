const std = @import("std");
const testing = std.testing;
const build_utils = @import("build_utils.zig");
const registry = @import("registry.zig");
const zcli = @import("zcli.zig");

// ============================================================================
// TEST HELPERS
// ============================================================================

fn createTestCommands(allocator: std.mem.Allocator) !build_utils.DiscoveredCommands {
    var commands = build_utils.DiscoveredCommands.init(allocator);

    // Create a pure command group (no index.zig)
    var network_subcommands = std.StringHashMap(build_utils.CommandInfo).init(allocator);

    // Create path array properly
    var network_ls_path = try allocator.alloc([]const u8, 2);
    network_ls_path[0] = try allocator.dupe(u8, "network");
    network_ls_path[1] = try allocator.dupe(u8, "ls");

    const network_ls = build_utils.CommandInfo{
        .name = try allocator.dupe(u8, "ls"),
        .path = network_ls_path,
        .file_path = try allocator.dupe(u8, "network/ls.zig"),
        .command_type = .leaf,
        .subcommands = null,
    };
    try network_subcommands.put(try allocator.dupe(u8, "ls"), network_ls);

    var network_path = try allocator.alloc([]const u8, 1);
    network_path[0] = try allocator.dupe(u8, "network");

    const network_group = build_utils.CommandInfo{
        .name = try allocator.dupe(u8, "network"),
        .path = network_path,
        .file_path = try allocator.dupe(u8, "network"), // No index.zig
        .command_type = .pure_group,
        .subcommands = network_subcommands,
    };
    try commands.root.put(try allocator.dupe(u8, "network"), network_group);

    // Create an optional command group (with index.zig)
    var container_subcommands = std.StringHashMap(build_utils.CommandInfo).init(allocator);
    var container_run_path = try allocator.alloc([]const u8, 2);
    container_run_path[0] = try allocator.dupe(u8, "container");
    container_run_path[1] = try allocator.dupe(u8, "run");

    const container_run = build_utils.CommandInfo{
        .name = try allocator.dupe(u8, "run"),
        .path = container_run_path,
        .file_path = try allocator.dupe(u8, "container/run.zig"),
        .command_type = .leaf,
        .subcommands = null,
    };
    try container_subcommands.put(try allocator.dupe(u8, "run"), container_run);

    var container_path = try allocator.alloc([]const u8, 1);
    container_path[0] = try allocator.dupe(u8, "container");

    const container_group = build_utils.CommandInfo{
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

    const version_cmd = build_utils.CommandInfo{
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

test "code generation: pure groups are not registered as commands" {
    const allocator = testing.allocator;

    var commands = try createTestCommands(allocator);
    defer commands.deinit();

    const config = build_utils.BuildConfig{
        .commands_dir = "test/commands",
        .plugins_dir = null,
        .plugins = null,
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    };

    const source = try build_utils.generateComptimeRegistrySource(allocator, commands, config, &.{});
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

    const config = build_utils.BuildConfig{
        .commands_dir = "test/commands",
        .plugins_dir = null,
        .plugins = null,
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    };

    const source = try build_utils.generateComptimeRegistrySource(allocator, commands, config, &.{});
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

    var commands = build_utils.DiscoveredCommands.init(allocator);
    defer commands.deinit();

    // Create nested structure: docker -> compose (pure) -> up (leaf)
    var compose_subcommands = std.StringHashMap(build_utils.CommandInfo).init(allocator);

    var compose_up_path = try allocator.alloc([]const u8, 3);
    compose_up_path[0] = try allocator.dupe(u8, "docker");
    compose_up_path[1] = try allocator.dupe(u8, "compose");
    compose_up_path[2] = try allocator.dupe(u8, "up");

    const compose_up = build_utils.CommandInfo{
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

    const compose_group = build_utils.CommandInfo{
        .name = try allocator.dupe(u8, "compose"),
        .path = compose_path,
        .file_path = try allocator.dupe(u8, "docker/compose"),
        .command_type = .pure_group,
        .subcommands = compose_subcommands,
    };

    // Docker is an optional group
    var docker_subcommands = std.StringHashMap(build_utils.CommandInfo).init(allocator);
    try docker_subcommands.put(try allocator.dupe(u8, "compose"), compose_group);

    var docker_path = try allocator.alloc([]const u8, 1);
    docker_path[0] = try allocator.dupe(u8, "docker");

    const docker_group = build_utils.CommandInfo{
        .name = try allocator.dupe(u8, "docker"),
        .path = docker_path,
        .file_path = try allocator.dupe(u8, "docker/index.zig"),
        .command_type = .optional_group,
        .subcommands = docker_subcommands,
    };
    try commands.root.put(try allocator.dupe(u8, "docker"), docker_group);

    // Generate code
    const config = build_utils.BuildConfig{
        .commands_dir = "test/commands",
        .plugins_dir = null,
        .plugins = null,
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    };

    const source = try build_utils.generateComptimeRegistrySource(allocator, commands, config, &.{});
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
    const TestRegistry = registry.Registry.init(.{
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
//     const TestRegistry = registry.Registry.init(.{
//         .app_name = "test",
//         .app_version = "1.0.0",
//         .app_description = "test",
//     })
//         .register("group", InvalidOptionalGroup)
//         .register("group sub", ValidOptionalGroup)
//         .build();
//
//     _ = TestRegistry;
// }

// ============================================================================
// EDGE CASES
// ============================================================================

test "empty pure command group without subcommands" {
    const allocator = testing.allocator;

    var commands = build_utils.DiscoveredCommands.init(allocator);
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

    var commands = build_utils.DiscoveredCommands.init(allocator);
    defer commands.deinit();

    // Create a structure with both pure and optional groups at same level
    var app_subcommands = std.StringHashMap(build_utils.CommandInfo).init(allocator);

    // Pure group
    var pure_subcommands = std.StringHashMap(build_utils.CommandInfo).init(allocator);

    var pure_cmd_path = try allocator.alloc([]const u8, 2);
    pure_cmd_path[0] = try allocator.dupe(u8, "pure");
    pure_cmd_path[1] = try allocator.dupe(u8, "list");

    const pure_cmd = build_utils.CommandInfo{
        .name = try allocator.dupe(u8, "list"),
        .path = pure_cmd_path,
        .file_path = try allocator.dupe(u8, "pure/list.zig"),
        .command_type = .leaf,
        .subcommands = null,
    };
    try pure_subcommands.put(try allocator.dupe(u8, "list"), pure_cmd);

    var pure_path = try allocator.alloc([]const u8, 1);
    pure_path[0] = try allocator.dupe(u8, "pure");

    const pure_group = build_utils.CommandInfo{
        .name = try allocator.dupe(u8, "pure"),
        .path = pure_path,
        .file_path = try allocator.dupe(u8, "pure"),
        .command_type = .pure_group,
        .subcommands = pure_subcommands,
    };
    try app_subcommands.put(try allocator.dupe(u8, "pure"), pure_group);

    // Optional group
    var optional_subcommands = std.StringHashMap(build_utils.CommandInfo).init(allocator);

    var optional_cmd_path = try allocator.alloc([]const u8, 2);
    optional_cmd_path[0] = try allocator.dupe(u8, "optional");
    optional_cmd_path[1] = try allocator.dupe(u8, "exec");

    const optional_cmd = build_utils.CommandInfo{
        .name = try allocator.dupe(u8, "exec"),
        .path = optional_cmd_path,
        .file_path = try allocator.dupe(u8, "optional/exec.zig"),
        .command_type = .leaf,
        .subcommands = null,
    };
    try optional_subcommands.put(try allocator.dupe(u8, "exec"), optional_cmd);

    var optional_path = try allocator.alloc([]const u8, 1);
    optional_path[0] = try allocator.dupe(u8, "optional");

    const optional_group = build_utils.CommandInfo{
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
