const std = @import("std");
const build_utils = @import("build_utils.zig");

/// Tests for the plugin system foundation
/// These tests verify plugin discovery, registry generation, and pipeline composition

// Test helper for creating plugin structures
const TestPlugin = struct {
    allocator: std.mem.Allocator,
    plugins: std.ArrayList(build_utils.PluginInfo),

    fn init(allocator: std.mem.Allocator) TestPlugin {
        return .{
            .allocator = allocator,
            .plugins = std.ArrayList(build_utils.PluginInfo).init(allocator),
        };
    }

    fn deinit(self: *TestPlugin) void {
        for (self.plugins.items) |plugin_info| {
            self.allocator.free(plugin_info.name);
            self.allocator.free(plugin_info.import_name);
        }
        self.plugins.deinit();
    }

    fn addLocal(self: *TestPlugin, name: []const u8, import_name: []const u8) !void {
        try self.plugins.append(.{
            .name = try self.allocator.dupe(u8, name),
            .import_name = try self.allocator.dupe(u8, import_name),
            .is_local = true,
            .dependency = null,
        });
    }

    fn addExternal(self: *TestPlugin, name: []const u8) !void {
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
    const local_plugin = build_utils.PluginInfo{
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
    const external_plugin = build_utils.PluginInfo{
        .name = "zcli-auth",
        .import_name = "zcli-auth",
        .is_local = false,
        .dependency = null,
    };
    try std.testing.expectEqualStrings(external_plugin.name, "zcli-auth");
    try std.testing.expectEqualStrings(external_plugin.import_name, "zcli-auth");
    try std.testing.expect(external_plugin.is_local == false);
}

// Note: combinePlugins requires a real std.Build object which we can't easily mock in tests
// This functionality is tested through integration tests when the build system runs

test "BuildConfig with plugins" {
    const config = build_utils.BuildConfig{
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
    var test_plugins = TestPlugin.init(allocator);
    defer test_plugins.deinit();

    try test_plugins.addLocal("logger", "plugins/logger");
    try test_plugins.addExternal("zcli-auth");

    // Create mock discovered commands
    var commands = build_utils.DiscoveredCommands{
        .allocator = allocator,
        .root = std.StringHashMap(build_utils.CommandInfo).init(allocator),
    };
    defer commands.deinit();

    const config = build_utils.BuildConfig{
        .commands_dir = "src/commands",
        .plugins_dir = null,
        .plugins = test_plugins.plugins.items,
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test app",
    };

    // Generate registry source
    const source = try build_utils.generatePluginRegistrySource(
        allocator,
        commands,
        config,
        test_plugins.plugins.items,
    );
    defer allocator.free(source);

    // Verify generated content includes plugin imports
    try std.testing.expect(std.mem.indexOf(u8, source, "const logger = @import(\"plugins/logger\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const zcli_auth = @import(\"zcli-auth\");") != null);

    // Verify Context generation
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const Context = struct {") != null);

    // Verify pipeline generation
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const CommandPipeline = blk:") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const ErrorPipeline = blk:") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const HelpPipeline = blk:") != null);

    // Verify Commands struct generation
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const Commands = struct {") != null);
}

test "plugin name sanitization for imports" {
    const allocator = std.testing.allocator;
    var test_plugins = TestPlugin.init(allocator);
    defer test_plugins.deinit();

    // Add plugin with dash in name (should be converted to underscore)
    try test_plugins.addExternal("zcli-help");
    try test_plugins.addExternal("my-custom-plugin");

    var commands = build_utils.DiscoveredCommands{
        .allocator = allocator,
        .root = std.StringHashMap(build_utils.CommandInfo).init(allocator),
    };
    defer commands.deinit();

    const config = build_utils.BuildConfig{
        .commands_dir = "src/commands",
        .plugins_dir = null,
        .plugins = test_plugins.plugins.items,
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test app",
    };

    const source = try build_utils.generatePluginRegistrySource(
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
    var test_plugins = TestPlugin.init(allocator);
    defer test_plugins.deinit();

    try test_plugins.addLocal("auth", "plugins/auth");
    try test_plugins.addLocal("logger", "plugins/logger");

    var commands = build_utils.DiscoveredCommands{
        .allocator = allocator,
        .root = std.StringHashMap(build_utils.CommandInfo).init(allocator),
    };
    defer commands.deinit();

    const config = build_utils.BuildConfig{
        .commands_dir = "src/commands",
        .plugins_dir = null,
        .plugins = test_plugins.plugins.items,
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test app",
    };

    const source = try build_utils.generatePluginRegistrySource(
        allocator,
        commands,
        config,
        test_plugins.plugins.items,
    );
    defer allocator.free(source);

    // Verify Context has extension fields
    try std.testing.expect(std.mem.indexOf(u8, source, "auth: if (@hasDecl(auth, \"ContextExtension\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "logger: if (@hasDecl(logger, \"ContextExtension\"))") != null);

    // Verify init function
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn init(allocator: std.mem.Allocator) !@This()") != null);
    
    // Verify deinit function
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn deinit(self: *@This()) void") != null);
}

test "pipeline composition ordering" {
    const allocator = std.testing.allocator;
    var test_plugins = TestPlugin.init(allocator);
    defer test_plugins.deinit();

    // Order matters - last plugin wraps first
    try test_plugins.addLocal("plugin1", "plugins/plugin1");
    try test_plugins.addLocal("plugin2", "plugins/plugin2");
    try test_plugins.addLocal("plugin3", "plugins/plugin3");

    var commands = build_utils.DiscoveredCommands{
        .allocator = allocator,
        .root = std.StringHashMap(build_utils.CommandInfo).init(allocator),
    };
    defer commands.deinit();

    const config = build_utils.BuildConfig{
        .commands_dir = "src/commands",
        .plugins_dir = null,
        .plugins = test_plugins.plugins.items,
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test app",
    };

    const source = try build_utils.generatePluginRegistrySource(
        allocator,
        commands,
        config,
        test_plugins.plugins.items,
    );
    defer allocator.free(source);

    // Find the CommandPipeline section
    const pipeline_start = std.mem.indexOf(u8, source, "pub const CommandPipeline = blk:").?;
    const pipeline_end = std.mem.indexOf(u8, source[pipeline_start..], "};").? + pipeline_start;
    const pipeline_section = source[pipeline_start..pipeline_end];

    // Verify plugins are checked in order
    const plugin1_pos = std.mem.indexOf(u8, pipeline_section, "if (@hasDecl(plugin1").?;
    const plugin2_pos = std.mem.indexOf(u8, pipeline_section, "if (@hasDecl(plugin2").?;
    const plugin3_pos = std.mem.indexOf(u8, pipeline_section, "if (@hasDecl(plugin3").?;

    // They should appear in the order they were added
    try std.testing.expect(plugin1_pos < plugin2_pos);
    try std.testing.expect(plugin2_pos < plugin3_pos);
}

test "Commands struct with plugin commands" {
    const allocator = std.testing.allocator;
    var test_plugins = TestPlugin.init(allocator);
    defer test_plugins.deinit();

    try test_plugins.addLocal("auth", "plugins/auth");
    try test_plugins.addExternal("zcli-help");

    var commands = build_utils.DiscoveredCommands{
        .allocator = allocator,
        .root = std.StringHashMap(build_utils.CommandInfo).init(allocator),
    };
    defer commands.deinit();

    // Add a native command
    const hello_cmd = build_utils.CommandInfo{
        .name = try allocator.dupe(u8, "hello"),
        .path = try allocator.dupe(u8, "src/commands/hello.zig"),
        .is_group = false,
        .subcommands = null,
    };
    try commands.root.put(try allocator.dupe(u8, "hello"), hello_cmd);

    const config = build_utils.BuildConfig{
        .commands_dir = "src/commands",
        .plugins_dir = null,
        .plugins = test_plugins.plugins.items,
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test app",
    };

    const source = try build_utils.generatePluginRegistrySource(
        allocator,
        commands,
        config,
        test_plugins.plugins.items,
    );
    defer allocator.free(source);

    // Verify Commands struct includes native commands
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const hello = @import(\"cmd_hello\");") != null);

    // Verify PluginCommands struct is generated for plugin commands (no more usingnamespace)
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const PluginCommands = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const auth_commands = if (@hasDecl(auth, \"commands\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const zcli_help_commands = if (@hasDecl(zcli_help, \"commands\"))") != null);
    
    // Verify getCommand function is generated
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn getCommand(comptime name: []const u8) ?type") != null);
    
    // Verify getAllCommandNames function is generated
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn getAllCommandNames() []const []const u8") != null);
}

test "empty plugin list handling" {
    const allocator = std.testing.allocator;

    var commands = build_utils.DiscoveredCommands{
        .allocator = allocator,
        .root = std.StringHashMap(build_utils.CommandInfo).init(allocator),
    };
    defer commands.deinit();

    const config = build_utils.BuildConfig{
        .commands_dir = "src/commands",
        .plugins_dir = null,
        .plugins = null, // No plugins
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test app",
    };

    const source = try build_utils.generatePluginRegistrySource(
        allocator,
        commands,
        config,
        &.{}, // Empty plugin array
    );
    defer allocator.free(source);

    // Should still generate valid code with no plugins
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const Context = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const CommandPipeline = blk:") != null);
    
    // Base types should be used when no plugins
    try std.testing.expect(std.mem.indexOf(u8, source, "var pipeline_type = zcli.BaseCommandExecutor;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var pipeline_type = zcli.BaseErrorHandler;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var pipeline_type = RegistryHelpGenerator;") != null);
}