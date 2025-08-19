const std = @import("std");
const build_utils = @import("build_utils.zig");
const execution = @import("execution.zig");

/// Comprehensive integration tests for the plugin system
/// These tests verify that plugins work correctly in realistic scenarios

// Mock plugin for testing all features
const MockPlugin = struct {
    // Command transformer
    pub fn transformCommand(comptime next: anytype) type {
        return struct {
            pub fn execute(ctx: anytype, args: anytype) !void {
                ctx.test_data.command_transform_called = true;
                try next.execute(ctx, args);
                ctx.test_data.command_transform_completed = true;
            }
        };
    }
    
    // Error transformer
    pub fn transformError(comptime next: anytype) type {
        return struct {
            pub fn handle(err: anyerror, ctx: anytype) !void {
                ctx.test_data.error_transform_called = true;
                try next.handle(err, ctx);
            }
        };
    }
    
    // Help transformer
    pub fn transformHelp(comptime next: anytype) type {
        return struct {
            pub fn generate(ctx: anytype, command_name: ?[]const u8) ![]const u8 {
                ctx.test_data.help_transform_called = true;
                const base = try next.generate(ctx, command_name);
                const result = try std.fmt.allocPrint(ctx.allocator, "{s}\n[MockPlugin]", .{base});
                ctx.allocator.free(base);
                return result;
            }
        };
    }
    
    // Context extension
    pub const ContextExtension = struct {
        initialized: bool,
        value: i32,
        
        pub fn init(allocator: std.mem.Allocator) !@This() {
            _ = allocator;
            return .{
                .initialized = true,
                .value = 42,
            };
        }
        
        pub fn deinit(self: *@This()) void {
            self.initialized = false;
        }
    };
    
    // Plugin commands
    pub const commands = struct {
        pub const mock_cmd = struct {
            pub const meta = .{
                .description = "Mock command for testing",
            };
            
            pub fn execute(ctx: anytype, args: anytype) !void {
                _ = args;
                ctx.test_data.plugin_command_executed = true;
            }
        };
    };
};

// Test data struct to track what was called
const TestData = struct {
    command_transform_called: bool = false,
    command_transform_completed: bool = false,
    error_transform_called: bool = false,
    help_transform_called: bool = false,
    plugin_command_executed: bool = false,
};

test "plugin pipeline composition order" {
    // Test that multiple plugins compose in the correct order
    const Plugin1 = struct {
        pub fn transformCommand(comptime next: anytype) type {
            return struct {
                pub fn execute(ctx: anytype, args: anytype) !void {
                    try ctx.order.append(1);
                    try next.execute(ctx, args);
                    try ctx.order.append(4);
                }
            };
        }
    };
    
    const Plugin2 = struct {
        pub fn transformCommand(comptime next: anytype) type {
            return struct {
                pub fn execute(ctx: anytype, args: anytype) !void {
                    try ctx.order.append(2);
                    try next.execute(ctx, args);
                    try ctx.order.append(3);
                }
            };
        }
    };
    
    // Compose pipeline: Plugin1 wraps Plugin2 wraps Base
    const Pipeline2 = Plugin2.transformCommand(execution.BaseCommandExecutor);
    const Pipeline1 = Plugin1.transformCommand(Pipeline2);
    
    var order = std.ArrayList(u8).init(std.testing.allocator);
    defer order.deinit();
    
    const ctx = struct {
        order: *std.ArrayList(u8),
        io: struct {
            stderr: std.io.AnyWriter,
        },
    }{
        .order = &order,
        .io = .{
            .stderr = std.io.null_writer.any(),
        },
    };
    
    const TestCommand = struct {
        pub fn execute(context: anytype, args: anytype) !void {
            _ = args;
            try context.order.append(0); // Base execution
        }
    };
    
    try Pipeline1.execute(ctx, TestCommand{});
    
    // Verify execution order: 1 -> 2 -> 0 (base) -> 3 -> 4
    try std.testing.expectEqual(@as(usize, 5), order.items.len);
    try std.testing.expectEqual(@as(u8, 1), order.items[0]);
    try std.testing.expectEqual(@as(u8, 2), order.items[1]);
    try std.testing.expectEqual(@as(u8, 0), order.items[2]); // Base execution
    try std.testing.expectEqual(@as(u8, 3), order.items[3]);
    try std.testing.expectEqual(@as(u8, 4), order.items[4]);
}

test "context extension lifecycle" {
    const allocator = std.testing.allocator;
    
    // Test initialization
    var ext = try MockPlugin.ContextExtension.init(allocator);
    try std.testing.expect(ext.initialized == true);
    try std.testing.expectEqual(@as(i32, 42), ext.value);
    
    // Test deinit
    ext.deinit();
    try std.testing.expect(ext.initialized == false);
}

test "plugin command discovery simulation" {
    // Simulate how commands would be discovered
    const PluginCommands = struct {
        pub const mock_plugin = MockPlugin.commands;
    };
    
    // Check that we can access plugin commands
    try std.testing.expect(@hasDecl(PluginCommands.mock_plugin, "mock_cmd"));
    try std.testing.expect(@hasDecl(PluginCommands.mock_plugin.mock_cmd, "execute"));
    try std.testing.expect(@hasDecl(PluginCommands.mock_plugin.mock_cmd, "meta"));
}

test "error pipeline with multiple transformers" {
    const allocator = std.testing.allocator;
    
    const Plugin1 = struct {
        pub fn transformError(comptime next: anytype) type {
            return struct {
                pub fn handle(err: anyerror, ctx: anytype) !void {
                    try ctx.messages.append("Plugin1: before");
                    try next.handle(err, ctx);
                    try ctx.messages.append("Plugin1: after");
                }
            };
        }
    };
    
    const Plugin2 = struct {
        pub fn transformError(comptime next: anytype) type {
            return struct {
                pub fn handle(err: anyerror, ctx: anytype) !void {
                    try ctx.messages.append("Plugin2: before");
                    try next.handle(err, ctx);
                    try ctx.messages.append("Plugin2: after");
                }
            };
        }
    };
    
    // Create base handler that just logs
    const TestBaseHandler = struct {
        pub fn handle(err: anyerror, ctx: anytype) !void {
            switch (err) {
                error.TestError => try ctx.messages.append("Base: handled"),
                else => return err,
            }
        }
    };
    
    // Compose pipeline
    const Pipeline2 = Plugin2.transformError(TestBaseHandler);
    const Pipeline1 = Plugin1.transformError(Pipeline2);
    
    var messages = std.ArrayList([]const u8).init(allocator);
    defer messages.deinit();
    
    const ctx = struct {
        messages: *std.ArrayList([]const u8),
    }{
        .messages = &messages,
    };
    
    try Pipeline1.handle(error.TestError, ctx);
    
    // Verify message order
    try std.testing.expectEqual(@as(usize, 5), messages.items.len);
    try std.testing.expectEqualStrings("Plugin1: before", messages.items[0]);
    try std.testing.expectEqualStrings("Plugin2: before", messages.items[1]);
    try std.testing.expectEqualStrings("Base: handled", messages.items[2]);
    try std.testing.expectEqualStrings("Plugin2: after", messages.items[3]);
    try std.testing.expectEqualStrings("Plugin1: after", messages.items[4]);
}

test "help pipeline transformation" {
    const allocator = std.testing.allocator;
    
    const Plugin1 = struct {
        pub fn transformHelp(comptime next: anytype) type {
            return struct {
                pub fn generate(ctx: anytype, command_name: ?[]const u8) ![]const u8 {
                    const base = try next.generate(ctx, command_name);
                    defer ctx.allocator.free(base);
                    return try std.fmt.allocPrint(ctx.allocator, "{s}\n[Plugin1 Help]", .{base});
                }
            };
        }
    };
    
    const Plugin2 = struct {
        pub fn transformHelp(comptime next: anytype) type {
            return struct {
                pub fn generate(ctx: anytype, command_name: ?[]const u8) ![]const u8 {
                    const base = try next.generate(ctx, command_name);
                    defer ctx.allocator.free(base);
                    return try std.fmt.allocPrint(ctx.allocator, "{s}\n[Plugin2 Help]", .{base});
                }
            };
        }
    };
    
    const BaseGenerator = struct {
        pub fn generate(ctx: anytype, command_name: ?[]const u8) ![]const u8 {
            _ = command_name;
            return ctx.allocator.dupe(u8, "Base Help");
        }
    };
    
    // Compose pipeline
    const Pipeline2 = Plugin2.transformHelp(BaseGenerator);
    const Pipeline1 = Plugin1.transformHelp(Pipeline2);
    
    const ctx = struct {
        allocator: std.mem.Allocator,
    }{
        .allocator = allocator,
    };
    
    const help = try Pipeline1.generate(ctx, null);
    defer allocator.free(help);
    
    // Verify help includes all transformations
    try std.testing.expect(std.mem.indexOf(u8, help, "Base Help") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "[Plugin2 Help]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "[Plugin1 Help]") != null);
}

test "plugin with no transformers" {
    // Plugin that only provides commands, no transformers
    const CommandOnlyPlugin = struct {
        pub const commands = struct {
            pub const simple = struct {
                pub fn execute(ctx: anytype, args: anytype) !void {
                    _ = ctx;
                    _ = args;
                }
            };
        };
    };
    
    // Verify we can check for transformers
    try std.testing.expect(!@hasDecl(CommandOnlyPlugin, "transformCommand"));
    try std.testing.expect(!@hasDecl(CommandOnlyPlugin, "transformError"));
    try std.testing.expect(!@hasDecl(CommandOnlyPlugin, "transformHelp"));
    try std.testing.expect(@hasDecl(CommandOnlyPlugin, "commands"));
}

test "plugin with partial features" {
    // Plugin with only some features
    const PartialPlugin = struct {
        pub fn transformCommand(comptime next: anytype) type {
            return struct {
                pub fn execute(ctx: anytype, args: anytype) !void {
                    try next.execute(ctx, args);
                }
            };
        }
        
        pub const ContextExtension = struct {
            data: []const u8,
            
            pub fn init(allocator: std.mem.Allocator) !@This() {
                _ = allocator;
                return .{ .data = "partial" };
            }
        };
        // No error transformer, no help transformer, no commands
    };
    
    try std.testing.expect(@hasDecl(PartialPlugin, "transformCommand"));
    try std.testing.expect(!@hasDecl(PartialPlugin, "transformError"));
    try std.testing.expect(!@hasDecl(PartialPlugin, "transformHelp"));
    try std.testing.expect(@hasDecl(PartialPlugin, "ContextExtension"));
    try std.testing.expect(!@hasDecl(PartialPlugin, "commands"));
}

test "generated code structure validation" {
    const allocator = std.testing.allocator;
    
    // Create test plugin info
    var plugins = std.ArrayList(build_utils.PluginInfo).init(allocator);
    defer plugins.deinit();
    
    try plugins.append(.{
        .name = try allocator.dupe(u8, "test-plugin"),
        .import_name = try allocator.dupe(u8, "plugins/test"),
        .is_local = true,
        .dependency = null,
    });
    defer allocator.free(plugins.items[0].name);
    defer allocator.free(plugins.items[0].import_name);
    
    // Create empty commands for simplicity
    var commands = build_utils.DiscoveredCommands{
        .allocator = allocator,
        .root = std.StringHashMap(build_utils.CommandInfo).init(allocator),
    };
    defer commands.deinit();
    
    const config = build_utils.BuildConfig{
        .commands_dir = "src/commands",
        .plugins_dir = "src/plugins",
        .plugins = plugins.items,
        .app_name = "testapp",
        .app_version = "1.0.0",
        .app_description = "Test app",
    };
    
    // Generate registry source
    const source = try build_utils.generatePluginRegistrySource(
        allocator,
        commands,
        config,
        plugins.items,
    );
    defer allocator.free(source);
    
    // Validate key structures are present in new registry format
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const Context = @TypeOf(registry).Context;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const registry = zcli.Registry.init") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".build();") != null);
    
    // Verify plugins are registered
    try std.testing.expect(std.mem.indexOf(u8, source, ".registerPlugin(") != null);
    
    // Validate plugin is referenced
    try std.testing.expect(std.mem.indexOf(u8, source, "test_plugin") != null);
}

test "memory management in pipelines" {
    const allocator = std.testing.allocator;
    
    // Plugin that allocates memory
    const MemoryPlugin = struct {
        pub fn transformCommand(comptime next: anytype) type {
            return struct {
                pub fn execute(ctx: anytype, args: anytype) !void {
                    // Allocate and free memory properly
                    const buffer = try ctx.allocator.alloc(u8, 100);
                    defer ctx.allocator.free(buffer);
                    
                    @memset(buffer, 'A');
                    try next.execute(ctx, args);
                }
            };
        }
    };
    
    const BaseExecutor = struct {
        pub fn execute(ctx: anytype, args: anytype) !void {
            _ = ctx;
            _ = args;
        }
    };
    
    const Pipeline = MemoryPlugin.transformCommand(BaseExecutor);
    
    const ctx = struct {
        allocator: std.mem.Allocator,
        io: struct {
            stderr: std.io.AnyWriter,
        },
    }{
        .allocator = allocator,
        .io = .{
            .stderr = std.io.null_writer.any(),
        },
    };
    
    // Execute and ensure no memory leaks
    try Pipeline.execute(ctx, .{});
}

test "plugin error propagation" {
    const FailingPlugin = struct {
        pub fn transformCommand(comptime next: anytype) type {
            return struct {
                pub fn execute(ctx: anytype, args: anytype) !void {
                    _ = ctx;
                    _ = args;
                    _ = next;
                    return error.PluginFailure;
                }
            };
        }
    };
    
    const BaseExecutor = struct {
        pub fn execute(ctx: anytype, args: anytype) !void {
            _ = ctx;
            _ = args;
        }
    };
    
    const Pipeline = FailingPlugin.transformCommand(BaseExecutor);
    
    const ctx = struct {
        io: struct {
            stderr: std.io.AnyWriter,
        },
    }{
        .io = .{
            .stderr = std.io.null_writer.any(),
        },
    };
    
    // Verify error is propagated
    const result = Pipeline.execute(ctx, .{});
    try std.testing.expectError(error.PluginFailure, result);
}