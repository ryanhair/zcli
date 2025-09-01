const std = @import("std");
const logging = @import("../logging.zig");

// Import all specialized modules
pub const types = @import("types.zig");
pub const plugin_system = @import("plugin_system.zig");
pub const command_discovery = @import("command_discovery.zig");
pub const code_generation = @import("code_generation.zig");
pub const module_creation = @import("module_creation.zig");

// Re-export commonly used types
pub const PluginInfo = types.PluginInfo;
pub const CommandInfo = types.CommandInfo;
pub const DiscoveredCommands = types.DiscoveredCommands;
pub const BuildConfig = types.BuildConfig;
pub const PluginConfig = types.PluginConfig;
pub const ExternalPluginBuildConfig = types.ExternalPluginBuildConfig;

// Re-export main functions for backward compatibility
pub const plugin = plugin_system.plugin;
pub const scanLocalPlugins = plugin_system.scanLocalPlugins;
pub const combinePlugins = plugin_system.combinePlugins;
pub const addPluginModules = plugin_system.addPluginModules;

pub const discoverCommands = command_discovery.discoverCommands;
pub const isValidCommandName = command_discovery.isValidCommandName;

pub const generatePluginRegistrySource = code_generation.generateComptimeRegistrySource;
pub const generateRegistrySource = code_generation.generateRegistrySource;

pub const createDiscoveredModules = module_creation.createDiscoveredModules;

// ============================================================================
// HIGH-LEVEL BUILD FUNCTIONS - Main entry points for build.zig
// ============================================================================

/// Build function with plugin support that accepts zcli module
pub fn buildWithPlugins(b: *std.Build, exe: *std.Build.Step.Compile, zcli_module: *std.Build.Module, config: BuildConfig) *std.Build.Module {
    // Get target and optimize from executable
    const target = exe.root_module.resolved_target orelse b.graph.host;
    const optimize = exe.root_module.optimize orelse .Debug;

    // 1. Discover local plugins
    const local_plugins = if (config.plugins_dir) |dir|
        plugin_system.scanLocalPlugins(b, dir) catch &.{}
    else
        &.{};

    // 2. Combine with external plugins
    const all_plugins = plugin_system.combinePlugins(b, local_plugins, config.plugins orelse &.{});

    // 3. Add plugin modules to executable
    plugin_system.addPluginModules(b, exe, all_plugins);

    // 4. Generate plugin-enhanced registry
    const registry_module = generatePluginRegistry(b, target, optimize, zcli_module, config, all_plugins);

    return registry_module;
}

/// Generate registry with plugin support
pub fn generatePluginRegistry(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zcli_module: *std.Build.Module,
    config: BuildConfig,
    plugins: []const PluginInfo,
) *std.Build.Module {
    _ = target; // Will be used for plugin compilation
    _ = optimize; // Will be used for plugin compilation

    // Discover all commands at build time (same as before)
    var discovered_commands = command_discovery.discoverCommands(b.allocator, config.commands_dir) catch |err| {
        // Same error handling as before
        switch (err) {
            error.InvalidPath => {
                logging.buildError("Command Discovery Error", config.commands_dir, "Invalid commands directory path.\nPath contains '..' which is not allowed for security reasons", "Please use a relative path without '..' or an absolute path");
            },
            error.FileNotFound => {
                logging.buildError("Command Discovery Error", config.commands_dir, "Commands directory not found", "Please ensure the directory exists and the path is correct");
            },
            error.AccessDenied => {
                logging.buildError("Command Discovery Error", config.commands_dir, "Access denied to commands directory", "Please check file permissions for the directory");
            },
            error.OutOfMemory => {
                logging.buildError("Build Error", "memory allocation", "Out of memory during command discovery", "Try reducing the number of commands or increasing available memory");
            },
            else => {
                logging.buildError("Command Discovery Error", config.commands_dir, "Failed to discover commands", "Check the command directory structure and file permissions");
                std.debug.print("Error details: {any}\n", .{err});
            },
        }
        std.process.exit(1);
    };
    defer discovered_commands.deinit();

    // Generate plugin-enhanced registry source code
    const registry_source = code_generation.generateComptimeRegistrySource(b.allocator, discovered_commands, config, plugins) catch |err| {
        switch (err) {
            error.OutOfMemory => {
                logging.registryGenerationOutOfMemory();
            },
        }
        std.process.exit(1);
    };
    defer b.allocator.free(registry_source);

    // Create a write file step to write the generated source
    const write_registry = b.addWriteFiles();
    const registry_file = write_registry.add("zcli_generated.zig", registry_source);

    // Create a module from the generated file
    const registry_module = b.addModule("command_registry", .{
        .root_source_file = registry_file,
    });

    // Add zcli import to registry module
    registry_module.addImport("zcli", zcli_module);

    // Create modules for all discovered command files dynamically
    module_creation.createDiscoveredModules(b, registry_module, zcli_module, discovered_commands, config.commands_dir);

    // Add plugin imports to registry module
    module_creation.addPluginModulesToRegistry(b, registry_module, zcli_module, plugins);

    return registry_module;
}

/// Legacy function for backward compatibility
pub fn generateCommandRegistry(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, zcli_module: *std.Build.Module, options: struct {
    commands_dir: []const u8,
    app_name: []const u8,
    app_version: []const u8,
    app_description: []const u8,
}) *std.Build.Module {
    _ = target; // Currently unused but may be needed later
    _ = optimize; // Currently unused but may be needed later

    // Discover all commands at build time
    var discovered_commands = command_discovery.discoverCommands(b.allocator, options.commands_dir) catch |err| {
        switch (err) {
            error.InvalidPath => {
                logging.buildError("Command Discovery Error", options.commands_dir, "Invalid commands directory path.\nPath contains '..' which is not allowed for security reasons", "Please use a relative path without '..' or an absolute path");
            },
            error.FileNotFound => {
                logging.buildError("Command Discovery Error", options.commands_dir, "Commands directory not found", "Please ensure the directory exists and the path is correct");
            },
            error.AccessDenied => {
                logging.buildError("Command Discovery Error", options.commands_dir, "Access denied to commands directory", "Please check file permissions for the directory");
            },
            error.OutOfMemory => {
                logging.buildError("Build Error", "memory allocation", "Out of memory during command discovery", "Try reducing the number of commands or increasing available memory");
            },
            else => {
                logging.buildError("Command Discovery Error", options.commands_dir, "Failed to discover commands", "Check the command directory structure and file permissions");
                std.debug.print("Error details: {any}\n", .{err});
            },
        }
        // Use a generic exit since we've already logged details
        std.process.exit(1);
    };
    defer discovered_commands.deinit();

    // Generate registry source code
    const registry_source = code_generation.generateRegistrySource(b.allocator, discovered_commands, options) catch |err| {
        switch (err) {
            error.OutOfMemory => {
                logging.registryGenerationOutOfMemory();
            },
        }
        std.process.exit(1);
    };
    defer b.allocator.free(registry_source);

    // Create a write file step to write the generated source
    const write_registry = b.addWriteFiles();
    const registry_file = write_registry.add("zcli_generated.zig", registry_source);

    // Create a module from the generated file
    const registry_module = b.addModule("command_registry", .{
        .root_source_file = registry_file,
    });

    // Add zcli import to registry module
    registry_module.addImport("zcli", zcli_module);

    // Create modules for all discovered command files dynamically
    module_creation.createDiscoveredModules(b, registry_module, zcli_module, discovered_commands, options.commands_dir);

    return registry_module;
}

/// Build function for external plugins with explicit plugin configuration
pub fn buildWithExternalPlugins(b: *std.Build, exe: *std.Build.Step.Compile, zcli_module: *std.Build.Module, config: ExternalPluginBuildConfig) *std.Build.Module {
    // Variables needed for potential future use
    _ = exe.root_module.resolved_target orelse b.graph.host;
    _ = exe.root_module.optimize orelse .Debug;

    // Convert PluginConfig array to PluginInfo array
    var plugins = std.ArrayList(PluginInfo).init(b.allocator);
    defer plugins.deinit();

    for (config.plugins) |plugin_config| {
        // Create a dependency for each external plugin
        const plugin_dep = b.dependency(plugin_config.name, .{});

        const import_name = std.fmt.allocPrint(b.allocator, "plugins/{s}/plugin", .{plugin_config.name}) catch {
            logging.buildError("Plugin System", "memory allocation", "Failed to allocate memory for plugin import name", "Out of memory while processing external plugin. Reduce number of plugins or increase available memory");
            std.debug.print("Plugin name: {s}\n", .{plugin_config.name});
            std.process.exit(1);
        };

        const plugin_info = PluginInfo{
            .name = plugin_config.name,
            .import_name = import_name,
            .is_local = false, // External plugins are not local
            .dependency = plugin_dep,
        };
        plugins.append(plugin_info) catch {
            logging.buildError("Plugin System", "memory allocation", "Failed to add plugin to plugin list", "Out of memory while adding external plugin. Reduce number of plugins or increase available memory");
            std.debug.print("Plugin name: {s}\n", .{plugin_config.name});
            std.process.exit(1);
        };
    }

    // Create BuildConfig from ExternalPluginBuildConfig
    const build_config = BuildConfig{
        .commands_dir = config.commands_dir,
        .plugins_dir = null, // No local plugins directory
        .plugins = plugins.items,
        .app_name = config.app_name,
        .app_version = config.app_version,
        .app_description = config.app_description,
    };

    // Use the existing buildWithPlugins function
    return buildWithPlugins(b, exe, zcli_module, build_config);
}

// ============================================================================
// TESTS - Include tests from submodules
// ============================================================================

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

// Note: combinePlugins requires a real std.Build object which we can't easily mock in tests
// This functionality is tested through integration tests when the build system runs

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
    const source = try generatePluginRegistrySource(
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

    const source = try generatePluginRegistrySource(
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

    const source = try generatePluginRegistrySource(
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

    const source = try generatePluginRegistrySource(
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

    const source = try generatePluginRegistrySource(
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

    const source = try generatePluginRegistrySource(
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
