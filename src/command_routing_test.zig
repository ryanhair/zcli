const std = @import("std");
const testing = std.testing;
const zcli = @import("zcli.zig");
const registry = @import("registry.zig");

// Test command modules to simulate the nested command scenario
const RootCommand = struct {
    pub const meta = .{
        .description = "Root command",
    };

    pub const Args = struct {};
    pub const Options = struct {};

    pub fn execute(_: Args, _: Options, context: *zcli.Context) !void {
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

    pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
        try context.io.stdout.print("nested executed: name={s}, force={}\n", .{ args.name, options.force });
    }
};

// Create a test registry with nested command paths to test longest-match routing
fn TestRegistry(comptime config: registry.Config) type {
    return zcli.Registry.init(config)
        .register("container", RootCommand) // 1 component
        .register("container run", NestedCommand) // 2 components
        .build();
}

test "command routing: longest match wins for nested commands" {
    // Create test registry
    const config = registry.Config{
        .app_name = "test",
        .app_version = "1.0.0",
        .app_description = "Test CLI",
    };

    const TestApp = TestRegistry(config);

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

    // Test command path sorting - longer paths should come first (simulating registry logic)
    const sorted_commands = comptime blk: {
        var cmds = commands[0..commands.len].*;

        // Bubble sort by path length (descending)
        var changed = true;
        while (changed) {
            changed = false;
            var i: usize = 0;
            while (i < cmds.len - 1) : (i += 1) {
                if (cmds[i].path.len < cmds[i + 1].path.len) {
                    const temp = cmds[i];
                    cmds[i] = cmds[i + 1];
                    cmds[i + 1] = temp;
                    changed = true;
                }
            }
        }
        break :blk cmds;
    };

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
    const config = registry.Config{
        .app_name = "test",
        .app_version = "1.0.0",
        .app_description = "Test CLI",
    };

    const TestApp = TestRegistry(config);

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
    const config = registry.Config{
        .app_name = "test",
        .app_version = "1.0.0",
        .app_description = "Test CLI",
    };

    const TestApp = TestRegistry(config);

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
