const std = @import("std");
const testing = std.testing;
const zcli = @import("zcli.zig");

// Test basic argument transformation
test "basic argument transformation" {
    const allocator = testing.allocator;

    const TransformUppercasePlugin = struct {
        pub fn transformArgs(
            context: *zcli.Context,
            args: []const []const u8,
        ) !zcli.TransformResult {
            var new_args = try context.allocator.alloc([]const u8, args.len);
            for (args, 0..) |arg, i| {
                new_args[i] = try std.ascii.allocUpperString(context.allocator, arg);
            }
            return .{ .args = new_args };
        }
    };

    const TestRegistry = zcli.Registry.init(.{
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    })
        .registerPlugin(TransformUppercasePlugin)
        .build();

    var app = TestRegistry.init();
    var context = zcli.Context.init(allocator);
    defer context.deinit();

    const args = [_][]const u8{ "hello", "world" };
    const result = try app.transformArgs(&context, &args);
    defer {
        for (result.args) |arg| {
            context.allocator.free(arg);
        }
        context.allocator.free(result.args);
    }

    try testing.expectEqualStrings(result.args[0], "HELLO");
    try testing.expectEqualStrings(result.args[1], "WORLD");
}

// Test transformation with consumption
test "transformation with argument consumption" {
    const allocator = testing.allocator;

    const TransformFilterPlugin = struct {
        pub fn transformArgs(
            context: *zcli.Context,
            args: []const []const u8,
        ) !zcli.TransformResult {
            var filtered = std.ArrayList([]const u8).init(context.allocator);
            var consumed = std.ArrayList(usize).init(context.allocator);
            defer filtered.deinit();
            defer consumed.deinit();

            for (args, 0..) |arg, i| {
                if (std.mem.startsWith(u8, arg, "--internal-")) {
                    try consumed.append(i);
                } else {
                    try filtered.append(arg);
                }
            }

            return .{
                .args = try filtered.toOwnedSlice(),
                .consumed_indices = try consumed.toOwnedSlice(),
            };
        }
    };

    const TestRegistry = zcli.Registry.init(.{
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    })
        .registerPlugin(TransformFilterPlugin)
        .build();

    var app = TestRegistry.init();
    var context = zcli.Context.init(allocator);
    defer context.deinit();

    const args = [_][]const u8{ "command", "--internal-debug", "arg1", "--internal-trace", "arg2" };
    const result = try app.transformArgs(&context, &args);
    defer {
        context.allocator.free(result.args);
        context.allocator.free(result.consumed_indices);
    }

    try testing.expect(result.args.len == 3);
    try testing.expectEqualStrings(result.args[0], "command");
    try testing.expectEqualStrings(result.args[1], "arg1");
    try testing.expectEqualStrings(result.args[2], "arg2");

    try testing.expect(result.consumed_indices.len == 2);
    try testing.expect(result.consumed_indices[0] == 1); // --internal-debug
    try testing.expect(result.consumed_indices[1] == 3); // --internal-trace
}

// Test transformation chain with multiple plugins
test "transformation chain with multiple plugins" {
    const allocator = testing.allocator;

    const TransformPlugin1 = struct {
        pub const priority = 100;
        pub fn transformArgs(
            context: *zcli.Context,
            args: []const []const u8,
        ) !zcli.TransformResult {
            // Replace "alias" with "actual-command" - no allocation, just return modified view
            if (args.len > 0 and std.mem.eql(u8, args[0], "alias")) {
                // Create a new slice with the modified command (this will be cleaned up by Plugin2)
                var new_args = try context.allocator.alloc([]const u8, args.len);
                new_args[0] = "actual-command";
                if (args.len > 1) {
                    @memcpy(new_args[1..], args[1..]);
                }
                return .{ .args = new_args };
            }
            return .{ .args = args };
        }
    };

    const TransformPlugin2 = struct {
        pub const priority = 50;
        pub fn transformArgs(
            context: *zcli.Context,
            args: []const []const u8,
        ) !zcli.TransformResult {
            // Add a prefix to all arguments and free the intermediate allocation if needed
            var new_args = try context.allocator.alloc([]const u8, args.len);
            for (args, 0..) |arg, i| {
                new_args[i] = try std.fmt.allocPrint(context.allocator, "prefix-{s}", .{arg});
            }
            // Clean up intermediate allocation if it's not the original args
            // We can check by seeing if the first arg is our expected "actual-command"
            if (args.len > 0 and std.mem.eql(u8, args[0], "actual-command")) {
                // This means Plugin1 allocated the args array, so we need to free it
                context.allocator.free(args);
            }
            return .{ .args = new_args };
        }
    };

    const TestRegistry = zcli.Registry.init(.{
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    })
        .registerPlugin(TransformPlugin1)
        .registerPlugin(TransformPlugin2)
        .build();

    var app = TestRegistry.init();
    var context = zcli.Context.init(allocator);
    defer context.deinit();

    const args = [_][]const u8{ "alias", "arg" };
    const result = try app.transformArgs(&context, &args);
    defer {
        for (result.args) |arg| {
            context.allocator.free(arg);
        }
        context.allocator.free(result.args);
    }

    // Plugin1 runs first (higher priority), changes "alias" to "actual-command"
    // Plugin2 runs second, adds "prefix-" to all args
    try testing.expectEqualStrings(result.args[0], "prefix-actual-command");
    try testing.expectEqualStrings(result.args[1], "prefix-arg");
}

// Test stopping transformation pipeline
test "stopping transformation pipeline" {
    const allocator = testing.allocator;

    const TransformStopPlugin = struct {
        pub fn transformArgs(
            context: *zcli.Context,
            args: []const []const u8,
        ) !zcli.TransformResult {
            _ = context;
            if (args.len > 0 and std.mem.eql(u8, args[0], "stop")) {
                return .{
                    .args = &.{},
                    .continue_processing = false,
                };
            }
            return .{ .args = args };
        }
    };

    const TransformNeverCalledPlugin = struct {
        pub var was_called = false;

        pub fn transformArgs(
            context: *zcli.Context,
            args: []const []const u8,
        ) !zcli.TransformResult {
            _ = context;
            was_called = true;
            return .{ .args = args };
        }
    };

    const TestRegistry = zcli.Registry.init(.{
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    })
        .registerPlugin(TransformStopPlugin)
        .registerPlugin(TransformNeverCalledPlugin)
        .build();

    var app = TestRegistry.init();
    var context = zcli.Context.init(allocator);
    defer context.deinit();

    TransformNeverCalledPlugin.was_called = false;

    const args = [_][]const u8{ "stop", "other", "args" };
    const result = try app.transformArgs(&context, &args);

    try testing.expect(result.args.len == 0);
    try testing.expect(!result.continue_processing);
    try testing.expect(!TransformNeverCalledPlugin.was_called);
}

// Test environment variable expansion
test "environment variable expansion transformation" {
    const allocator = testing.allocator;

    const TransformEnvPlugin = struct {
        pub fn transformArgs(
            context: *zcli.Context,
            args: []const []const u8,
        ) !zcli.TransformResult {
            var new_args = std.ArrayList([]const u8).init(context.allocator);
            defer new_args.deinit();

            for (args) |arg| {
                if (std.mem.startsWith(u8, arg, "$")) {
                    const env_var = arg[1..];
                    if (context.environment.get(env_var)) |value| {
                        try new_args.append(value);
                    } else {
                        try new_args.append(arg); // Keep original if not found
                    }
                } else {
                    try new_args.append(arg);
                }
            }

            return .{ .args = try new_args.toOwnedSlice() };
        }
    };

    const TestRegistry = zcli.Registry.init(.{
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    })
        .registerPlugin(TransformEnvPlugin)
        .build();

    var app = TestRegistry.init();
    var context = zcli.Context.init(allocator);
    defer context.deinit();

    // Set environment variables
    try context.environment.put("USER", "testuser");
    try context.environment.put("HOME", "/home/testuser");

    const args = [_][]const u8{ "command", "$USER", "$HOME", "$NONEXISTENT" };
    const result = try app.transformArgs(&context, &args);
    defer context.allocator.free(result.args);

    try testing.expectEqualStrings(result.args[0], "command");
    try testing.expectEqualStrings(result.args[1], "testuser");
    try testing.expectEqualStrings(result.args[2], "/home/testuser");
    try testing.expectEqualStrings(result.args[3], "$NONEXISTENT"); // Unchanged
}

// Test path expansion transformation
test "path expansion transformation" {
    const allocator = testing.allocator;

    const TransformPathPlugin = struct {
        pub fn transformArgs(
            context: *zcli.Context,
            args: []const []const u8,
        ) !zcli.TransformResult {
            var new_args = std.ArrayList([]const u8).init(context.allocator);
            defer new_args.deinit();

            for (args) |arg| {
                if (std.mem.startsWith(u8, arg, "~/")) {
                    const home = context.environment.get("HOME") orelse "/home/user";
                    const expanded = try std.fmt.allocPrint(context.allocator, "{s}{s}", .{ home, arg[1..] });
                    try new_args.append(expanded);
                } else {
                    try new_args.append(arg);
                }
            }

            return .{ .args = try new_args.toOwnedSlice() };
        }
    };

    const TestRegistry = zcli.Registry.init(.{
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    })
        .registerPlugin(TransformPathPlugin)
        .build();

    var app = TestRegistry.init();
    var context = zcli.Context.init(allocator);
    defer context.deinit();

    try context.environment.put("HOME", "/home/testuser");

    const args = [_][]const u8{ "~/Documents/file.txt", "~/Downloads", "/absolute/path" };
    const result = try app.transformArgs(&context, &args);
    defer {
        // Only free the allocated ones (~/... paths)
        for (result.args, 0..) |arg, i| {
            if (i < 2) { // First two were expanded from ~/...
                context.allocator.free(arg);
            }
        }
        context.allocator.free(result.args);
    }

    try testing.expectEqualStrings(result.args[0], "/home/testuser/Documents/file.txt");
    try testing.expectEqualStrings(result.args[1], "/home/testuser/Downloads");
    try testing.expectEqualStrings(result.args[2], "/absolute/path");
}

// Test argument injection transformation
test "argument injection transformation" {
    const allocator = testing.allocator;

    const TransformInjectionPlugin = struct {
        pub fn transformArgs(
            context: *zcli.Context,
            args: []const []const u8,
        ) !zcli.TransformResult {
            // If user runs "commit", inject -m if not present
            if (args.len > 0 and std.mem.eql(u8, args[0], "commit")) {
                var has_message = false;
                for (args) |arg| {
                    if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
                        has_message = true;
                        break;
                    }
                }

                if (!has_message) {
                    var new_args = try context.allocator.alloc([]const u8, args.len + 2);
                    @memcpy(new_args[0..args.len], args);
                    new_args[args.len] = "-m";
                    new_args[args.len + 1] = "Auto-generated commit message";
                    return .{ .args = new_args };
                }
            }
            return .{ .args = args };
        }
    };

    const TestRegistry = zcli.Registry.init(.{
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    })
        .registerPlugin(TransformInjectionPlugin)
        .build();

    var app = TestRegistry.init();
    var context = zcli.Context.init(allocator);
    defer context.deinit();

    // Test injection when -m is missing
    const args1 = [_][]const u8{ "commit", "file.txt" };
    const result1 = try app.transformArgs(&context, &args1);
    defer context.allocator.free(result1.args);

    try testing.expect(result1.args.len == 4);
    try testing.expectEqualStrings(result1.args[0], "commit");
    try testing.expectEqualStrings(result1.args[1], "file.txt");
    try testing.expectEqualStrings(result1.args[2], "-m");
    try testing.expectEqualStrings(result1.args[3], "Auto-generated commit message");

    // Test no injection when -m is present
    const args2 = [_][]const u8{ "commit", "-m", "User message", "file.txt" };
    const result2 = try app.transformArgs(&context, &args2);

    try testing.expect(result2.args.len == 4);
    try testing.expectEqualStrings(result2.args[2], "User message");
}

// Test transformation error handling
test "transformation error handling" {
    const allocator = testing.allocator;

    const TransformErrorPlugin = struct {
        pub fn transformArgs(
            context: *zcli.Context,
            args: []const []const u8,
        ) !zcli.TransformResult {
            _ = context;
            if (args.len > 0 and std.mem.eql(u8, args[0], "error")) {
                return error.TransformationFailed;
            }
            return .{ .args = args };
        }
    };

    const TestRegistry = zcli.Registry.init(.{
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    })
        .registerPlugin(TransformErrorPlugin)
        .build();

    var app = TestRegistry.init();
    var context = zcli.Context.init(allocator);
    defer context.deinit();

    const args = [_][]const u8{ "error", "command" };
    const result = app.transformArgs(&context, &args);

    try testing.expectError(error.TransformationFailed, result);
}
