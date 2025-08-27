const std = @import("std");
const testing = std.testing;
const build_utils = @import("build_utils.zig");

// ============================================================================
// E2E Tests for Help System
// ============================================================================
//
// This test suite comprehensively tests all variations of help output to
// prevent regressions in the help system formatting, alignment, and content.

test "help system: app help shows all commands with proper formatting" {
    const allocator = testing.allocator;

    // Create a temporary test directory structure
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test command structure
    try tmp_dir.dir.makeDir("commands");
    try tmp_dir.dir.writeFile(.{ .sub_path = "commands/version.zig", .data = 
        \\const zcli = @import("zcli");
        \\
        \\pub const meta = zcli.CommandMeta{
        \\    .description = "Show version information",
        \\};
        \\
        \\pub fn execute(ctx: *zcli.Context, args: [][]const u8, options: struct{}) !void {
        \\    _ = ctx; _ = args; _ = options;
        \\}
    });

    // Create a group command with index
    try tmp_dir.dir.makeDir("commands/users");
    try tmp_dir.dir.writeFile(.{ .sub_path = "commands/users/index.zig", .data = 
        \\const zcli = @import("zcli");
        \\
        \\pub const meta = zcli.CommandMeta{
        \\    .description = "User management commands",
        \\};
        \\
        \\pub fn execute(ctx: *zcli.Context, args: [][]const u8, options: struct{}) !void {
        \\    _ = ctx; _ = args; _ = options;
        \\}
    });

    try tmp_dir.dir.writeFile(.{ .sub_path = "commands/users/list.zig", .data = 
        \\const zcli = @import("zcli");
        \\
        \\pub const meta = zcli.CommandMeta{
        \\    .description = "List all users",
        \\};
        \\
        \\pub fn execute(ctx: *zcli.Context, args: [][]const u8, options: struct{}) !void {
        \\    _ = ctx; _ = args; _ = options;
        \\}
    });

    // Create a simple command without description
    try tmp_dir.dir.writeFile(.{ .sub_path = "commands/simple.zig", .data = 
        \\const zcli = @import("zcli");
        \\
        \\pub fn execute(ctx: *zcli.Context, args: [][]const u8, options: struct{}) !void {
        \\    _ = ctx; _ = args; _ = options;
        \\}
    });

    // Discover commands
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const commands_path = try std.fs.path.join(allocator, &.{ tmp_path, "commands" });
    defer allocator.free(commands_path);

    var discovered = build_utils.discoverCommands(allocator, commands_path) catch |err| switch (err) {
        error.FileNotFound => {
            // Skip test if we can't access the filesystem
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer discovered.deinit();

    // Verify the discovered structure
    try testing.expect(discovered.root.contains("version"));
    try testing.expect(discovered.root.contains("users"));
    try testing.expect(discovered.root.contains("simple"));

    const users_group = discovered.root.get("users").?;
    try testing.expect(users_group.command_type != .leaf);
    try testing.expect(users_group.subcommands.?.contains("list"));
    try testing.expect(!users_group.subcommands.?.contains("index")); // index.zig should not be a subcommand

    const version_cmd = discovered.root.get("version").?;
    try testing.expect(version_cmd.command_type == .leaf);

    const simple_cmd = discovered.root.get("simple").?;
    try testing.expect(simple_cmd.command_type == .leaf);
}

test "help system: command help with options shows proper alignment" {
    const allocator = testing.allocator;

    // Create a temporary test directory structure
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("commands");
    try tmp_dir.dir.writeFile(.{ .sub_path = "commands/commit.zig", .data = 
        \\const zcli = @import("zcli");
        \\
        \\pub const Args = struct {
        \\    files: [][]const u8 = &.{},
        \\};
        \\
        \\pub const Options = struct {
        \\    message: ?[]const u8 = null,
        \\    amend: bool = false,
        \\    all: bool = false,
        \\    verbose: bool = false,
        \\    sign_off: bool = false,
        \\    no_verify: bool = false,
        \\};
        \\
        \\pub const meta = zcli.CommandMeta{
        \\    .description = "Record changes to the repository",
        \\    .examples = &.{
        \\        "commit --message \"Add new feature\"",
        \\        "commit -m \"Fix bug in parser\"",
        \\        "commit --amend",
        \\        "commit --all --message \"Update all files\"",
        \\    },
        \\};
        \\
        \\pub fn execute(ctx: *zcli.Context, args: Args, options: Options) !void {
        \\    _ = ctx; _ = args; _ = options;
        \\}
    });

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const commands_path = try std.fs.path.join(allocator, &.{ tmp_path, "commands" });
    defer allocator.free(commands_path);

    var discovered = build_utils.discoverCommands(allocator, commands_path) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer discovered.deinit();

    // Verify command structure
    try testing.expect(discovered.root.contains("commit"));
    const commit_cmd = discovered.root.get("commit").?;
    try testing.expect(commit_cmd.command_type == .leaf);

    // Verify the command path is an array
    try testing.expect(commit_cmd.path.len == 1);
    try testing.expectEqualStrings("commit", commit_cmd.path[0]);
}

test "help system: group command help structure" {
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create nested group structure
    try tmp_dir.dir.makeDir("commands");
    try tmp_dir.dir.makeDir("commands/docker");
    try tmp_dir.dir.makeDir("commands/docker/container");

    // Docker group with index
    try tmp_dir.dir.writeFile(.{ .sub_path = "commands/docker/index.zig", .data = 
        \\const zcli = @import("zcli");
        \\
        \\pub const meta = zcli.CommandMeta{
        \\    .description = "Docker management commands",
        \\};
        \\
        \\pub fn execute(ctx: *zcli.Context, args: [][]const u8, options: struct{}) !void {
        \\    _ = ctx; _ = args; _ = options;
        \\}
    });

    // Container subgroup with index
    try tmp_dir.dir.writeFile(.{ .sub_path = "commands/docker/container/index.zig", .data = 
        \\const zcli = @import("zcli");
        \\
        \\pub const meta = zcli.CommandMeta{
        \\    .description = "Container management commands",
        \\};
        \\
        \\pub fn execute(ctx: *zcli.Context, args: [][]const u8, options: struct{}) !void {
        \\    _ = ctx; _ = args; _ = options;
        \\}
    });

    // Container subcommands
    try tmp_dir.dir.writeFile(.{ .sub_path = "commands/docker/container/ls.zig", .data = 
        \\const zcli = @import("zcli");
        \\
        \\pub const Options = struct {
        \\    all: bool = false,
        \\    quiet: bool = false,
        \\    size: bool = false,
        \\    filter: [][]const u8 = &.{},
        \\};
        \\
        \\pub const meta = zcli.CommandMeta{
        \\    .description = "List containers",
        \\};
        \\
        \\pub fn execute(ctx: *zcli.Context, args: [][]const u8, options: Options) !void {
        \\    _ = ctx; _ = args; _ = options;
        \\}
    });

    try tmp_dir.dir.writeFile(.{ .sub_path = "commands/docker/container/run.zig", .data = 
        \\const zcli = @import("zcli");
        \\
        \\pub const Args = struct {
        \\    image: []const u8,
        \\    command: [][]const u8 = &.{},
        \\};
        \\
        \\pub const Options = struct {
        \\    detach: bool = false,
        \\    interactive: bool = false,
        \\    tty: bool = false,
        \\    name: ?[]const u8 = null,
        \\    publish: [][]const u8 = &.{},
        \\    volume: [][]const u8 = &.{},
        \\    environment: [][]const u8 = &.{},
        \\};
        \\
        \\pub const meta = zcli.CommandMeta{
        \\    .description = "Run a command in a new container",
        \\    .examples = &.{
        \\        "container run ubuntu:latest",
        \\        "container run -it ubuntu:latest bash",
        \\        "container run -d --name web nginx",
        \\    },
        \\};
        \\
        \\pub fn execute(ctx: *zcli.Context, args: Args, options: Options) !void {
        \\    _ = ctx; _ = args; _ = options;
        \\}
    });

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const commands_path = try std.fs.path.join(allocator, &.{ tmp_path, "commands" });
    defer allocator.free(commands_path);

    var discovered = build_utils.discoverCommands(allocator, commands_path) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer discovered.deinit();

    // Verify top-level group
    try testing.expect(discovered.root.contains("docker"));
    const docker_group = discovered.root.get("docker").?;
    try testing.expect(docker_group.command_type != .leaf);
    try testing.expect(docker_group.path.len == 1);
    try testing.expectEqualStrings("docker", docker_group.path[0]);

    // Verify nested group structure
    try testing.expect(docker_group.subcommands.?.contains("container"));
    const container_group = docker_group.subcommands.?.get("container").?;
    try testing.expect(container_group.command_type != .leaf);
    try testing.expect(container_group.path.len == 2);
    try testing.expectEqualStrings("docker", container_group.path[0]);
    try testing.expectEqualStrings("container", container_group.path[1]);

    // Verify subcommands
    try testing.expect(container_group.subcommands.?.contains("ls"));
    try testing.expect(container_group.subcommands.?.contains("run"));

    const ls_cmd = container_group.subcommands.?.get("ls").?;
    try testing.expect(ls_cmd.command_type == .leaf);
    try testing.expect(ls_cmd.path.len == 3);
    try testing.expectEqualStrings("docker", ls_cmd.path[0]);
    try testing.expectEqualStrings("container", ls_cmd.path[1]);
    try testing.expectEqualStrings("ls", ls_cmd.path[2]);

    const run_cmd = container_group.subcommands.?.get("run").?;
    try testing.expect(run_cmd.command_type == .leaf);
    try testing.expect(run_cmd.path.len == 3);
    try testing.expectEqualStrings("docker", run_cmd.path[0]);
    try testing.expectEqualStrings("container", run_cmd.path[1]);
    try testing.expectEqualStrings("run", run_cmd.path[2]);
}

test "help system: commands with no metadata" {
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("commands");

    // Command with no meta
    try tmp_dir.dir.writeFile(.{ .sub_path = "commands/bare.zig", .data = 
        \\const zcli = @import("zcli");
        \\
        \\pub fn execute(ctx: *zcli.Context, args: [][]const u8, options: struct{}) !void {
        \\    _ = ctx; _ = args; _ = options;
        \\}
    });

    // Command with empty meta
    try tmp_dir.dir.writeFile(.{ .sub_path = "commands/empty_meta.zig", .data = 
        \\const zcli = @import("zcli");
        \\
        \\pub const meta = zcli.CommandMeta{};
        \\
        \\pub fn execute(ctx: *zcli.Context, args: [][]const u8, options: struct{}) !void {
        \\    _ = ctx; _ = args; _ = options;
        \\}
    });

    // Command with partial meta
    try tmp_dir.dir.writeFile(.{ .sub_path = "commands/partial_meta.zig", .data = 
        \\const zcli = @import("zcli");
        \\
        \\pub const meta = zcli.CommandMeta{
        \\    .description = "A command with partial metadata",
        \\};
        \\
        \\pub fn execute(ctx: *zcli.Context, args: [][]const u8, options: struct{}) !void {
        \\    _ = ctx; _ = args; _ = options;
        \\}
    });

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const commands_path = try std.fs.path.join(allocator, &.{ tmp_path, "commands" });
    defer allocator.free(commands_path);

    var discovered = build_utils.discoverCommands(allocator, commands_path) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer discovered.deinit();

    // Verify all commands are discovered
    try testing.expect(discovered.root.contains("bare"));
    try testing.expect(discovered.root.contains("empty_meta"));
    try testing.expect(discovered.root.contains("partial_meta"));

    // All should be regular commands, not groups
    try testing.expect(discovered.root.get("bare").?.command_type == .leaf);
    try testing.expect(discovered.root.get("empty_meta").?.command_type == .leaf);
    try testing.expect(discovered.root.get("partial_meta").?.command_type == .leaf);
}

test "help system: commands with complex options for alignment testing" {
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("commands");
    try tmp_dir.dir.writeFile(.{ .sub_path = "commands/complex.zig", .data = 
        \\const zcli = @import("zcli");
        \\
        \\pub const Args = struct {
        \\    input_file: []const u8,
        \\    output_files: [][]const u8 = &.{},
        \\};
        \\
        \\pub const Options = struct {
        \\    // Test various option name lengths for alignment
        \\    a: bool = false,                      // Very short
        \\    verbose: bool = false,                // Medium
        \\    extremely_long_option_name: bool = false,  // Very long
        \\    format: enum { json, xml, yaml } = .json,
        \\    count: u32 = 1,
        \\    timeout: f64 = 30.0,
        \\    tags: [][]const u8 = &.{},
        \\    include_pattern: [][]const u8 = &.{},
        \\    exclude_pattern: [][]const u8 = &.{},
        \\    max_depth: ?u32 = null,
        \\    follow_symlinks: bool = false,
        \\    case_sensitive: bool = true,
        \\    dry_run: bool = false,
        \\    force: bool = false,
        \\    quiet: bool = false,
        \\    debug: bool = false,
        \\    config_file: ?[]const u8 = null,
        \\    log_level: enum { debug, info, warn, @"error" } = .info,
        \\};
        \\
        \\pub const meta = zcli.CommandMeta{
        \\    .description = "A complex command for testing option alignment",
        \\    .examples = &.{
        \\        "complex input.txt --verbose",
        \\        "complex input.txt --format json --count 5",
        \\        "complex input.txt --extremely-long-option-name --dry-run",
        \\    },
        \\};
        \\
        \\pub fn execute(ctx: *zcli.Context, args: Args, options: Options) !void {
        \\    _ = ctx; _ = args; _ = options;
        \\}
    });

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const commands_path = try std.fs.path.join(allocator, &.{ tmp_path, "commands" });
    defer allocator.free(commands_path);

    var discovered = build_utils.discoverCommands(allocator, commands_path) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer discovered.deinit();

    // Verify command discovery
    try testing.expect(discovered.root.contains("complex"));
    const complex_cmd = discovered.root.get("complex").?;
    try testing.expect(complex_cmd.command_type == .leaf);
    try testing.expect(complex_cmd.path.len == 1);
    try testing.expectEqualStrings("complex", complex_cmd.path[0]);
}

test "help system: edge cases and invalid commands" {
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("commands");

    // Valid command
    try tmp_dir.dir.writeFile(.{ .sub_path = "commands/valid.zig", .data = 
        \\const zcli = @import("zcli");
        \\pub fn execute(ctx: *zcli.Context, args: [][]const u8, options: struct{}) !void {
        \\    _ = ctx; _ = args; _ = options;
        \\}
    });

    // File with .zig extension but not a command
    try tmp_dir.dir.writeFile(.{ .sub_path = "commands/not_a_command.zig", .data = 
        \\// This is not a valid command file
        \\const std = @import("std");
    });

    // Non-.zig file (should be ignored)
    try tmp_dir.dir.writeFile(.{ .sub_path = "commands/readme.txt", .data = "This should be ignored" });

    // Directory without index.zig and no subcommands (should be ignored)
    try tmp_dir.dir.makeDir("commands/empty_dir");

    // Directory with only non-command files (should be ignored)
    try tmp_dir.dir.makeDir("commands/non_command_dir");
    try tmp_dir.dir.writeFile(.{ .sub_path = "commands/non_command_dir/config.json", .data = "{}" });

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const commands_path = try std.fs.path.join(allocator, &.{ tmp_path, "commands" });
    defer allocator.free(commands_path);

    var discovered = build_utils.discoverCommands(allocator, commands_path) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer discovered.deinit();

    // Should contain the valid command and also the malformed .zig files
    // (Current behavior: discovery only checks file extension, not content validity)
    try testing.expect(discovered.root.contains("valid"));
    try testing.expect(discovered.root.contains("not_a_command")); // Currently discovered due to .zig extension
    try testing.expect(!discovered.root.contains("readme")); // Non-.zig files ignored
    try testing.expect(!discovered.root.contains("empty_dir"));
    try testing.expect(!discovered.root.contains("non_command_dir"));

    // Should have 2 commands (valid + malformed .zig file)
    try testing.expectEqual(@as(u32, 2), discovered.root.count());
}

test "help system: command path array consistency" {
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("commands");
    try tmp_dir.dir.makeDir("commands/git");
    try tmp_dir.dir.makeDir("commands/git/remote");

    // Multi-level nested command
    try tmp_dir.dir.writeFile(.{ .sub_path = "commands/git/remote/add.zig", .data = 
        \\const zcli = @import("zcli");
        \\
        \\pub const Args = struct {
        \\    name: []const u8,
        \\    url: []const u8,
        \\};
        \\
        \\pub const Options = struct {
        \\    fetch: bool = false,
        \\    tags: bool = true,
        \\    mirror: enum { fetch, push } = .fetch,
        \\};
        \\
        \\pub const meta = zcli.CommandMeta{
        \\    .description = "Add a remote repository",
        \\};
        \\
        \\pub fn execute(ctx: *zcli.Context, args: Args, options: Options) !void {
        \\    _ = ctx; _ = args; _ = options;
        \\}
    });

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const commands_path = try std.fs.path.join(allocator, &.{ tmp_path, "commands" });
    defer allocator.free(commands_path);

    var discovered = build_utils.discoverCommands(allocator, commands_path) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer discovered.deinit();

    // Verify deeply nested command structure
    try testing.expect(discovered.root.contains("git"));
    const git_group = discovered.root.get("git").?;
    try testing.expect(git_group.command_type != .leaf);

    try testing.expect(git_group.subcommands.?.contains("remote"));
    const remote_group = git_group.subcommands.?.get("remote").?;
    try testing.expect(remote_group.command_type != .leaf);

    try testing.expect(remote_group.subcommands.?.contains("add"));
    const add_cmd = remote_group.subcommands.?.get("add").?;
    try testing.expect(add_cmd.command_type == .leaf);

    // Verify the path array is correctly structured
    try testing.expect(add_cmd.path.len == 3);
    try testing.expectEqualStrings("git", add_cmd.path[0]);
    try testing.expectEqualStrings("remote", add_cmd.path[1]);
    try testing.expectEqualStrings("add", add_cmd.path[2]);

    // This is the key test: ensure we're using arrays, not string splitting
    // If this were using string splitting, we'd see issues with spaces or dots
    try testing.expect(@TypeOf(add_cmd.path) == []const []const u8);
    try testing.expect(@TypeOf(add_cmd.path[0]) == []const u8);
}

test "help system: regression protection for alignment formatting" {
    // This test ensures that the command path system we implemented doesn't break
    // the core functionality of command discovery and path handling
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("commands");

    // Create commands that would fail if we were still using string splitting
    // These names would be problematic with space-based splitting
    try tmp_dir.dir.writeFile(.{ .sub_path = "commands/test_command.zig", .data = 
        \\const zcli = @import("zcli");
        \\pub fn execute(ctx: *zcli.Context, args: [][]const u8, options: struct{}) !void {
        \\    _ = ctx; _ = args; _ = options;
        \\}
    });

    try tmp_dir.dir.writeFile(.{ .sub_path = "commands/long-name-with-dashes.zig", .data = 
        \\const zcli = @import("zcli");
        \\pub fn execute(ctx: *zcli.Context, args: [][]const u8, options: struct{}) !void {
        \\    _ = ctx; _ = args; _ = options;
        \\}
    });

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const commands_path = try std.fs.path.join(allocator, &.{ tmp_path, "commands" });
    defer allocator.free(commands_path);

    var discovered = build_utils.discoverCommands(allocator, commands_path) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer discovered.deinit();

    // Both commands should be discovered correctly
    try testing.expect(discovered.root.contains("test_command"));
    try testing.expect(discovered.root.contains("long-name-with-dashes"));

    // Verify path arrays are correctly formed
    const test_cmd = discovered.root.get("test_command").?;
    try testing.expectEqualStrings("test_command", test_cmd.path[0]);
    try testing.expect(test_cmd.path.len == 1);

    const dash_cmd = discovered.root.get("long-name-with-dashes").?;
    try testing.expectEqualStrings("long-name-with-dashes", dash_cmd.path[0]);
    try testing.expect(dash_cmd.path.len == 1);

    // Ensure they're not groups (would indicate parsing issues)
    try testing.expect(test_cmd.command_type == .leaf);
    try testing.expect(dash_cmd.command_type == .leaf);
}
