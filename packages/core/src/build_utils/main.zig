const std = @import("std");
const logging = @import("../logging.zig");
const types = @import("types.zig");
const module_creation = @import("module_creation.zig");
const plugin_system = @import("plugin_system.zig");
const command_discovery = @import("command_discovery.zig");
const code_generation = @import("code_generation.zig");

const CommandInfo = types.CommandInfo;
const BuildConfig = types.BuildConfig;
const DiscoveredCommands = types.DiscoveredCommands;
const ExternalPluginBuildConfig = types.ExternalPluginBuildConfig;

// ============================================================================
// VERSION MANAGEMENT - Read version from build.zig.zon
// ============================================================================

/// Read version from the project's build.zig.zon file
fn readVersionFromZon(b: *std.Build) []const u8 {
    const zon_path = b.pathFromRoot("build.zig.zon");

    // Read the file
    const zon_file = std.fs.cwd().openFile(zon_path, .{}) catch |err| {
        logging.logBuildWarning("Could not read build.zig.zon at '{s}', using default version 0.0.0: {any}", .{ zon_path, err });
        return "0.0.0";
    };
    defer zon_file.close();

    const content = zon_file.readToEndAlloc(b.allocator, 1024 * 1024) catch |err| {
        logging.logBuildWarning("Could not read build.zig.zon at '{s}', using default version 0.0.0: {any}", .{ zon_path, err });
        return "0.0.0";
    };
    // Don't defer free - we're returning a slice of this content

    // Parse the .version = "x.y.z" line
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, ".version")) {
            // Extract version string between quotes
            if (std.mem.indexOf(u8, trimmed, "\"")) |start| {
                const after_first = trimmed[start + 1..];
                if (std.mem.indexOf(u8, after_first, "\"")) |end| {
                    // Duplicate the version string so we can free the content
                    const version = b.allocator.dupe(u8, after_first[0..end]) catch "0.0.0";
                    b.allocator.free(content);
                    return version;
                }
            }
        }
    }

    b.allocator.free(content);
    logging.logBuildWarning("Could not parse version from build.zig.zon at '{s}', using default version 0.0.0", .{zon_path});
    return "0.0.0";
}

// ============================================================================
// HIGH-LEVEL BUILD FUNCTIONS - Main entry points for build.zig
// ============================================================================

/// Build function with plugin support that accepts zcli module
fn buildWithPlugins(b: *std.Build, exe: *std.Build.Step.Compile, zcli_module: *std.Build.Module, config: BuildConfig) *std.Build.Module {
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
fn generatePluginRegistry(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zcli_module: *std.Build.Module,
    config: BuildConfig,
    plugins: []const types.PluginInfo,
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

/// Build function for external plugins with explicit plugin configuration
pub fn generate(b: *std.Build, exe: *std.Build.Step.Compile, zcli_module: *std.Build.Module, config: anytype) *std.Build.Module {
    // Validate required fields
    if (!@hasField(@TypeOf(config), "commands_dir")) @compileError("config must have 'commands_dir' field");
    if (!@hasField(@TypeOf(config), "app_name")) @compileError("config must have 'app_name' field");
    if (!@hasField(@TypeOf(config), "app_description")) @compileError("config must have 'app_description' field");
    if (!@hasField(@TypeOf(config), "plugins")) @compileError("config must have 'plugins' field");

    // Always read version from build.zig.zon - single source of truth
    const app_version = readVersionFromZon(b);

    // Convert plugin configs to PluginInfo array
    var plugins = std.ArrayList(types.PluginInfo){};
    defer plugins.deinit(b.allocator);

    inline for (config.plugins) |plugin_config| {
        // Validate plugin config has required fields
        if (!@hasField(@TypeOf(plugin_config), "name")) @compileError("plugin config must have 'name' field");
        if (!@hasField(@TypeOf(plugin_config), "path")) @compileError("plugin config must have 'path' field");

        // Create a dependency for each external plugin
        const plugin_dep = b.dependency(plugin_config.name, .{});

        const import_name = std.fmt.allocPrint(b.allocator, "plugins/{s}/plugin", .{plugin_config.name}) catch {
            logging.buildError("Plugin System", "memory allocation", "Failed to allocate memory for plugin import name", "Out of memory while processing external plugin. Reduce number of plugins or increase available memory");
            std.debug.print("Plugin name: {s}\n", .{plugin_config.name});
            std.process.exit(1);
        };

        // Check if plugin has config and generate init code
        const init_code = if (@hasField(@TypeOf(plugin_config), "config"))
            configToInitString(b.allocator, plugin_config.config)
        else
            null;

        const plugin_info = types.PluginInfo{
            .name = plugin_config.name,
            .import_name = import_name,
            .is_local = false,
            .dependency = plugin_dep,
            .init = init_code,
        };
        plugins.append(b.allocator, plugin_info) catch {
            logging.buildError("Plugin System", "memory allocation", "Failed to add plugin to plugin list", "Out of memory while adding external plugin. Reduce number of plugins or increase available memory");
            std.debug.print("Plugin name: {s}\n", .{plugin_config.name});
            std.process.exit(1);
        };
    }

    // Create BuildConfig
    const build_config = BuildConfig{
        .commands_dir = config.commands_dir,
        .plugins_dir = null,
        .plugins = plugins.items,
        .app_name = config.app_name,
        .app_version = app_version,
        .app_description = config.app_description,
    };

    return buildWithPlugins(b, exe, zcli_module, build_config);
}

/// Convert a comptime config struct to an init string
fn configToInitString(allocator: std.mem.Allocator, comptime config: anytype) []const u8 {
    const T = @TypeOf(config);
    const type_info = @typeInfo(T);

    const fields = switch (type_info) {
        .@"struct" => |s| s.fields,
        else => @compileError("Plugin config must be a struct, got: " ++ @typeName(T)),
    };

    var result = std.ArrayList(u8){};
    const writer = result.writer(allocator);

    writer.writeAll(".init(.{") catch unreachable;

    inline for (fields, 0..) |field, i| {
        if (i > 0) writer.writeAll(", ") catch unreachable;

        writer.print(".{s} = ", .{field.name}) catch unreachable;

        const value = @field(config, field.name);
        switch (@typeInfo(field.type)) {
            .pointer => |ptr_info| {
                // Handle string slices and array pointers
                const child_info = @typeInfo(ptr_info.child);
                const is_string = switch (child_info) {
                    .int => |int_info| int_info.bits == 8 and int_info.signedness == .unsigned,
                    .array => |arr_info| arr_info.child == u8,
                    else => false,
                };

                if (is_string) {
                    writer.print("\"{s}\"", .{value}) catch unreachable;
                } else {
                    @compileError("Unsupported pointer type in plugin config: " ++ @typeName(field.type));
                }
            },
            .bool => {
                writer.print("{}", .{value}) catch unreachable;
            },
            .int, .comptime_int => {
                writer.print("{d}", .{value}) catch unreachable;
            },
            else => {
                @compileError("Unsupported type in plugin config: " ++ @typeName(field.type));
            },
        }
    }

    writer.writeAll("})") catch unreachable;

    return result.toOwnedSlice(allocator) catch unreachable;
}

// ============================================================================
// TESTS - Include tests from submodules
// ============================================================================

/// Tests for the plugin system foundation
/// These tests verify plugin discovery, registry generation, and pipeline composition

// Test helper for creating plugin structures
const PluginTestHelper = struct {
    allocator: std.mem.Allocator,
    plugins: std.ArrayList(types.PluginInfo),

    fn init(allocator: std.mem.Allocator) PluginTestHelper {
        return .{
            .allocator = allocator,
            .plugins = std.ArrayList(types.PluginInfo){},
        };
    }

    fn deinit(self: *PluginTestHelper) void {
        for (self.plugins.items) |plugin_info| {
            self.allocator.free(plugin_info.name);
            self.allocator.free(plugin_info.import_name);
        }
        self.plugins.deinit(self.allocator);
    }

    fn addLocal(self: *PluginTestHelper, name: []const u8, import_name: []const u8) !void {
        try self.plugins.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .import_name = try self.allocator.dupe(u8, import_name),
            .is_local = true,
            .dependency = null,
        });
    }

    fn addExternal(self: *PluginTestHelper, name: []const u8) !void {
        try self.plugins.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .import_name = try self.allocator.dupe(u8, name),
            .is_local = false,
            .dependency = null, // In real scenario, this would be from b.lazyDependency
        });
    }
};

test "PluginInfo struct creation" {
    // Test local plugin
    const local_plugin = types.PluginInfo{
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
    const external_plugin = types.PluginInfo{
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
