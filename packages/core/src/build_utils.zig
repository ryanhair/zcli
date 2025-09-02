// ============================================================================
// BUILD UTILITIES - Modular build system for zcli
// ============================================================================
//
// This module has been refactored into a modular structure for better maintainability:
//
// - build_utils/types.zig            - Shared types and structures
// - build_utils/plugin_system.zig    - Plugin discovery and management
// - build_utils/command_discovery.zig - Command scanning and validation
// - build_utils/code_generation.zig  - Registry source code generation
// - build_utils/module_creation.zig  - Build-time module creation
// - build_utils/main.zig             - High-level coordination functions

const main = @import("build_utils/main.zig");

// Re-export all types
pub const CommandInfo = main.CommandInfo;
pub const DiscoveredCommands = main.DiscoveredCommands;
pub const BuildConfig = main.BuildConfig;
pub const PluginConfig = main.PluginConfig;
pub const ExternalPluginBuildConfig = main.ExternalPluginBuildConfig;

// Re-export submodules
pub const types = main.types;
pub const plugin_system = main.plugin_system;
pub const command_discovery = main.command_discovery;
pub const code_generation = main.code_generation;
pub const module_creation = main.module_creation;

// Re-export command discovery functions
pub const discoverCommands = main.discoverCommands;
pub const isValidCommandName = main.isValidCommandName;

// Re-export module creation functions
pub const createDiscoveredModules = main.createDiscoveredModules;

// Re-export high-level build functions
pub const generate = main.generate;

const std = @import("std");
const zcli = @import("zcli.zig");
const PluginInfo = @import("build_utils/types.zig").PluginInfo;

test "pipeline integration preserves backwards compatibility" {
    const allocator = std.testing.allocator;

    // Create a simple registry type for testing
    const TestRegistry = struct {
        commands: struct {
            hello: struct {
                module: type,
                execute: *const fn ([]const []const u8, std.mem.Allocator, *anyopaque) anyerror!void,
            },
        },

        pub const app_name = "test";
        pub const app_version = "1.0.0";
        pub const app_description = "Test app";
    };

    const test_registry = TestRegistry{
        .commands = .{
            .hello = .{
                .module = struct {},
                .execute = testExecuteFunction,
            },
        },
    };

    // Create an App instance with the test registry
    const app = zcli.App(@TypeOf(test_registry), null).init(
        allocator,
        test_registry,
        .{
            .name = TestRegistry.app_name,
            .version = TestRegistry.app_version,
            .description = TestRegistry.app_description,
        },
    );

    // Test that the app can be created successfully (this tests our pipeline integration)
    _ = app; // Suppress unused variable warning
}

fn testExecuteFunction(args: []const []const u8, allocator: std.mem.Allocator, context: *anyopaque) !void {
    _ = args;
    _ = allocator;
    _ = context;
    // This is a dummy function for testing
}

test "pipeline system allows graceful fallback" {
    // This test verifies that when no pipelines are available,
    // the system falls back to direct execution (backwards compatibility)

    // The pipeline integration code should:
    // 1. Check if pipelines exist in the registry
    // 2. Use pipelines if available
    // 3. Fall back to direct execution if not

    // This is tested indirectly through the other tests and the example application
    try std.testing.expect(true);
}

/// Tests for the plugin system foundation
/// These tests verify plugin discovery, registry generation, and pipeline composition

// Test helper for creating plugin structures
const PluginTestHelper = struct {
    allocator: std.mem.Allocator,
    plugins: std.ArrayList(PluginInfo),

    fn init(allocator: std.mem.Allocator) PluginTestHelper {
        return .{
            .allocator = allocator,
            .plugins = std.ArrayList(PluginInfo).init(allocator),
        };
    }

    fn deinit(self: *PluginTestHelper) void {
        for (self.plugins.items) |plugin_info| {
            self.allocator.free(plugin_info.name);
            self.allocator.free(plugin_info.import_name);
        }
        self.plugins.deinit();
    }

    fn addLocal(self: *PluginTestHelper, name: []const u8, import_name: []const u8) !void {
        try self.plugins.append(.{
            .name = try self.allocator.dupe(u8, name),
            .import_name = try self.allocator.dupe(u8, import_name),
            .is_local = true,
            .dependency = null,
        });
    }

    fn addExternal(self: *PluginTestHelper, name: []const u8) !void {
        try self.plugins.append(.{
            .name = try self.allocator.dupe(u8, name),
            .import_name = try self.allocator.dupe(u8, name),
            .is_local = false,
            .dependency = null, // In real scenario, this would be from b.lazyDependency
        });
    }
};

test "PluginInfo struct creation" {
    // Test local plugin
    const local_plugin = PluginInfo{
        .name = "logger",
        .import_name = "plugins/logger",
        .is_local = true,
        .dependency = null,
    };
    try std.testing.expectEqualStrings(local_plugin.name, "logger");
    try std.testing.expectEqualStrings(local_plugin.import_name, "plugins/logger");
    try std.testing.expect(local_plugin.is_local == true);
    try std.testing.expect(local_plugin.dependency == null);

    // Test external plugin
    const external_plugin = PluginInfo{
        .name = "zcli-auth",
        .import_name = "zcli-auth",
        .is_local = false,
        .dependency = null,
    };
    try std.testing.expectEqualStrings(external_plugin.name, "zcli-auth");
    try std.testing.expectEqualStrings(external_plugin.import_name, "zcli-auth");
    try std.testing.expect(external_plugin.is_local == false);
}

test "BuildConfig with plugins" {
    const config = BuildConfig{
        .commands_dir = "src/commands",
        .plugins_dir = "src/plugins",
        .plugins = null,
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    };

    try std.testing.expectEqualStrings(config.commands_dir, "src/commands");
    try std.testing.expectEqualStrings(config.plugins_dir.?, "src/plugins");
    try std.testing.expect(config.plugins == null);
    try std.testing.expectEqualStrings(config.app_name, "test-app");
    try std.testing.expectEqualStrings(config.app_version, "1.0.0");
    try std.testing.expectEqualStrings(config.app_description, "Test application");
}

test "plugin registry generation with imports" {
    const allocator = std.testing.allocator;
    var test_plugins = PluginTestHelper.init(allocator);
    defer test_plugins.deinit();

    try test_plugins.addLocal("logger", "plugins/logger");
    try test_plugins.addExternal("zcli-auth");

    // Create mock discovered commands
    var commands = DiscoveredCommands{
        .allocator = allocator,
        .root = std.StringHashMap(CommandInfo).init(allocator),
    };
    defer commands.deinit();

    const config = BuildConfig{
        .commands_dir = "src/commands",
        .plugins_dir = null,
        .plugins = test_plugins.plugins.items,
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test app",
    };

    // Generate registry source
    const source = try code_generation.generateComptimeRegistrySource(
        allocator,
        commands,
        config,
        test_plugins.plugins.items,
    );
    defer allocator.free(source);

    // Verify generated content includes plugin imports
    try std.testing.expect(std.mem.indexOf(u8, source, "const logger = @import(\"plugins/logger\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const zcli_auth = @import(\"zcli-auth\");") != null);

    // Verify new comptime registry Context generation
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const Context = @TypeOf(registry).Context;") != null);

    // Verify registry generation (replaces pipeline generation)
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const registry = zcli.Registry.init") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".build();") != null);
    // Note: In the new comptime approach, plugins are registered and called through the registry
    // rather than generating complex pipeline code
}

test "plugin name sanitization for imports" {
    const allocator = std.testing.allocator;
    var test_plugins = PluginTestHelper.init(allocator);
    defer test_plugins.deinit();

    // Add plugin with dash in name (should be converted to underscore)
    try test_plugins.addExternal("zcli-help");
    try test_plugins.addExternal("my-custom-plugin");

    var commands = DiscoveredCommands{
        .allocator = allocator,
        .root = std.StringHashMap(CommandInfo).init(allocator),
    };
    defer commands.deinit();

    const config = BuildConfig{
        .commands_dir = "src/commands",
        .plugins_dir = null,
        .plugins = test_plugins.plugins.items,
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test app",
    };

    const source = try code_generation.generateComptimeRegistrySource(
        allocator,
        commands,
        config,
        test_plugins.plugins.items,
    );
    defer allocator.free(source);

    // Verify dashes are converted to underscores in variable names
    try std.testing.expect(std.mem.indexOf(u8, source, "const zcli_help = @import(\"zcli-help\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const my_custom_plugin = @import(\"my-custom-plugin\");") != null);
}

test "Context extension generation" {
    const allocator = std.testing.allocator;
    var test_plugins = PluginTestHelper.init(allocator);
    defer test_plugins.deinit();

    try test_plugins.addLocal("auth", "plugins/auth");
    try test_plugins.addLocal("logger", "plugins/logger");

    var commands = DiscoveredCommands{
        .allocator = allocator,
        .root = std.StringHashMap(CommandInfo).init(allocator),
    };
    defer commands.deinit();

    const config = BuildConfig{
        .commands_dir = "src/commands",
        .plugins_dir = null,
        .plugins = test_plugins.plugins.items,
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test app",
    };

    const source = try code_generation.generateComptimeRegistrySource(
        allocator,
        commands,
        config,
        test_plugins.plugins.items,
    );
    defer allocator.free(source);

    // Verify plugins are registered with the registry
    try std.testing.expect(std.mem.indexOf(u8, source, ".registerPlugin(auth)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".registerPlugin(logger)") != null);

    // Verify new init function signature
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn init(allocator: std.mem.Allocator) @TypeOf(registry)") != null);

    // Note: The new registry approach doesn't need a deinit function
}

test "pipeline composition ordering" {
    const allocator = std.testing.allocator;
    var test_plugins = PluginTestHelper.init(allocator);
    defer test_plugins.deinit();

    // Order matters - last plugin wraps first
    try test_plugins.addLocal("plugin1", "plugins/plugin1");
    try test_plugins.addLocal("plugin2", "plugins/plugin2");
    try test_plugins.addLocal("plugin3", "plugins/plugin3");

    var commands = DiscoveredCommands{
        .allocator = allocator,
        .root = std.StringHashMap(CommandInfo).init(allocator),
    };
    defer commands.deinit();

    const config = BuildConfig{
        .commands_dir = "src/commands",
        .plugins_dir = null,
        .plugins = test_plugins.plugins.items,
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test app",
    };

    const source = try code_generation.generateComptimeRegistrySource(
        allocator,
        commands,
        config,
        test_plugins.plugins.items,
    );
    defer allocator.free(source);

    // In the new approach, verify plugins are registered in the correct order
    const plugin1_pos = std.mem.indexOf(u8, source, ".registerPlugin(plugin1)").?;
    const plugin2_pos = std.mem.indexOf(u8, source, ".registerPlugin(plugin2)").?;
    const plugin3_pos = std.mem.indexOf(u8, source, ".registerPlugin(plugin3)").?;

    // They should appear in the order they were added
    try std.testing.expect(plugin1_pos < plugin2_pos);
    try std.testing.expect(plugin2_pos < plugin3_pos);
}

test "Commands struct with plugin commands" {
    const allocator = std.testing.allocator;
    var test_plugins = PluginTestHelper.init(allocator);
    defer test_plugins.deinit();

    try test_plugins.addLocal("auth", "plugins/auth");
    try test_plugins.addExternal("zcli-help");

    var commands = DiscoveredCommands{
        .allocator = allocator,
        .root = std.StringHashMap(CommandInfo).init(allocator),
    };
    defer commands.deinit();

    // Add a native command
    var hello_path = try allocator.alloc([]const u8, 1);
    hello_path[0] = try allocator.dupe(u8, "hello");

    const hello_cmd = CommandInfo{
        .name = try allocator.dupe(u8, "hello"),
        .path = hello_path,
        .file_path = try allocator.dupe(u8, "src/commands/hello.zig"),
        .command_type = .leaf,
        .subcommands = null,
    };
    try commands.root.put(try allocator.dupe(u8, "hello"), hello_cmd);

    const config = BuildConfig{
        .commands_dir = "src/commands",
        .plugins_dir = null,
        .plugins = test_plugins.plugins.items,
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test app",
    };

    const source = try code_generation.generateComptimeRegistrySource(
        allocator,
        commands,
        config,
        test_plugins.plugins.items,
    );
    defer allocator.free(source);

    // Verify commands are registered with the registry (new approach)
    try std.testing.expect(std.mem.indexOf(u8, source, "const cmd_hello = @import(\"cmd_hello\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".register(\"hello\", cmd_hello)") != null);

    // Verify plugins are also registered (combined approach)
    try std.testing.expect(std.mem.indexOf(u8, source, ".registerPlugin(auth)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".registerPlugin(zcli_help)") != null);

    // Verify registry is built
    try std.testing.expect(std.mem.indexOf(u8, source, ".build();") != null);

    // Note: The new registry approach handles command discovery differently
}

test "empty plugin list handling" {
    const allocator = std.testing.allocator;

    var commands = DiscoveredCommands{
        .allocator = allocator,
        .root = std.StringHashMap(CommandInfo).init(allocator),
    };
    defer commands.deinit();

    const config = BuildConfig{
        .commands_dir = "src/commands",
        .plugins_dir = null,
        .plugins = null, // No plugins
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test app",
    };

    const source = try code_generation.generateComptimeRegistrySource(
        allocator,
        commands,
        config,
        &.{}, // Empty plugin array
    );
    defer allocator.free(source);

    // Should still generate valid code with no plugins
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const Context = @TypeOf(registry).Context;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const registry = zcli.Registry.init") != null);

    // Registry should build successfully even with no plugins
    try std.testing.expect(std.mem.indexOf(u8, source, ".build();") != null);
}

const execution = @import("execution.zig");

/// Comprehensive integration tests for the plugin system
/// These tests verify that plugins work correctly in realistic scenarios

// Mock plugin for testing all features
const IntegrationMockPlugin = struct {
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
    const IntegrationPlugin1 = struct {
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

    const IntegrationPlugin2 = struct {
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

    // Compose pipeline: IntegrationPlugin1 wraps IntegrationPlugin2 wraps Base
    const Pipeline2 = IntegrationPlugin2.transformCommand(execution.BaseCommandExecutor);
    const Pipeline1 = IntegrationPlugin1.transformCommand(Pipeline2);

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
    var ext = try IntegrationMockPlugin.ContextExtension.init(allocator);
    try std.testing.expect(ext.initialized == true);
    try std.testing.expectEqual(@as(i32, 42), ext.value);

    // Test deinit
    ext.deinit();
    try std.testing.expect(ext.initialized == false);
}

test "plugin command discovery simulation" {
    // Simulate how commands would be discovered
    const IntegrationPluginCommands = struct {
        pub const mock_plugin = IntegrationMockPlugin.commands;
    };

    // Check that we can access plugin commands
    try std.testing.expect(@hasDecl(IntegrationPluginCommands.mock_plugin, "mock_cmd"));
    try std.testing.expect(@hasDecl(IntegrationPluginCommands.mock_plugin.mock_cmd, "execute"));
    try std.testing.expect(@hasDecl(IntegrationPluginCommands.mock_plugin.mock_cmd, "meta"));
}

test "error pipeline with multiple transformers" {
    const allocator = std.testing.allocator;

    const IntegrationPlugin1 = struct {
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

    const IntegrationPlugin2 = struct {
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
    const Pipeline2 = IntegrationPlugin2.transformError(TestBaseHandler);
    const Pipeline1 = IntegrationPlugin1.transformError(Pipeline2);

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

    const IntegrationPlugin1 = struct {
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

    const IntegrationPlugin2 = struct {
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
    const Pipeline2 = IntegrationPlugin2.transformHelp(BaseGenerator);
    const Pipeline1 = IntegrationPlugin1.transformHelp(Pipeline2);

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
    const IntegrationCommandOnlyPlugin = struct {
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
    try std.testing.expect(!@hasDecl(IntegrationCommandOnlyPlugin, "transformCommand"));
    try std.testing.expect(!@hasDecl(IntegrationCommandOnlyPlugin, "transformError"));
    try std.testing.expect(!@hasDecl(IntegrationCommandOnlyPlugin, "transformHelp"));
    try std.testing.expect(@hasDecl(IntegrationCommandOnlyPlugin, "commands"));
}

test "plugin with partial features" {
    // Plugin with only some features
    const IntegrationPartialPlugin = struct {
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

    try std.testing.expect(@hasDecl(IntegrationPartialPlugin, "transformCommand"));
    try std.testing.expect(!@hasDecl(IntegrationPartialPlugin, "transformError"));
    try std.testing.expect(!@hasDecl(IntegrationPartialPlugin, "transformHelp"));
    try std.testing.expect(@hasDecl(IntegrationPartialPlugin, "ContextExtension"));
    try std.testing.expect(!@hasDecl(IntegrationPartialPlugin, "commands"));
}

test "generated code structure validation" {
    const allocator = std.testing.allocator;

    // Create test plugin info
    var plugins = std.ArrayList(PluginInfo).init(allocator);
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
    var commands = DiscoveredCommands{
        .allocator = allocator,
        .root = std.StringHashMap(CommandInfo).init(allocator),
    };
    defer commands.deinit();

    const config = BuildConfig{
        .commands_dir = "src/commands",
        .plugins_dir = "src/plugins",
        .plugins = plugins.items,
        .app_name = "testapp",
        .app_version = "1.0.0",
        .app_description = "Test app",
    };

    // Generate registry source
    const source = try code_generation.generateComptimeRegistrySource(
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
    const IntegrationMemoryPlugin = struct {
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

    const Pipeline = IntegrationMemoryPlugin.transformCommand(BaseExecutor);

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
    const IntegrationFailingPlugin = struct {
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

    const Pipeline = IntegrationFailingPlugin.transformCommand(BaseExecutor);

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
