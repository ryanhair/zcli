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

pub const generatePluginRegistrySource = code_generation.generatePluginRegistrySource;
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
    const registry_source = code_generation.generatePluginRegistrySource(b.allocator, discovered_commands, config, plugins) catch |err| {
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
    module_creation.addPluginModulesToRegistry(b, registry_module, plugins);

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
            logging.buildError("Plugin System", "memory allocation", "Failed to allocate memory for plugin import name", 
                "Out of memory while processing external plugin. Reduce number of plugins or increase available memory");
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
            logging.buildError("Plugin System", "memory allocation", "Failed to add plugin to plugin list", 
                "Out of memory while adding external plugin. Reduce number of plugins or increase available memory");
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

test {
    // Import all test modules
    _ = @import("types.zig");
    _ = @import("command_discovery.zig"); // Has the isValidCommandName test
}