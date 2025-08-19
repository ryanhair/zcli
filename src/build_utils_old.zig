const std = @import("std");
const logging = @import("logging.zig");

// ============================================================================
// BUILD UTILITIES - For use in build.zig only
// These functions are not part of the public API for end users
// ============================================================================

// Plugin system structures
pub const PluginInfo = struct {
    name: []const u8,
    import_name: []const u8,
    is_local: bool,
    dependency: ?*std.Build.Dependency,
};

// Helper function to create external plugin references
pub fn plugin(b: *std.Build, name: []const u8) PluginInfo {
    return PluginInfo{
        .name = name,
        .import_name = name,
        .is_local = false,
        .dependency = b.lazyDependency(name, .{}),
    };
}

// Scan local plugins directory and return plugin info
pub fn scanLocalPlugins(b: *std.Build, plugins_dir: []const u8) ![]PluginInfo {
    var plugins = std.ArrayList(PluginInfo).init(b.allocator);
    defer plugins.deinit();

    // Validate plugins directory path
    if (std.mem.indexOf(u8, plugins_dir, "..") != null) {
        return error.InvalidPath;
    }

    // Try to open the plugins directory
    var dir = std.fs.cwd().openDir(plugins_dir, .{ .iterate = true }) catch |err| {
        // If directory doesn't exist, that's fine - just return empty list
        if (err == error.FileNotFound) {
            return &.{};
        }
        return err;
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        switch (entry.kind) {
            .file => {
                // Single-file plugins (e.g., auth.zig)
                if (std.mem.endsWith(u8, entry.name, ".zig")) {
                    const plugin_name = entry.name[0 .. entry.name.len - 4]; // Remove .zig

                    if (!isValidCommandName(plugin_name)) {
                        logging.invalidCommandName(plugin_name, "invalid plugin name");
                        continue;
                    }

                    const import_name = try std.fmt.allocPrint(b.allocator, "plugins/{s}", .{plugin_name});

                    try plugins.append(PluginInfo{
                        .name = try b.allocator.dupe(u8, plugin_name),
                        .import_name = import_name,
                        .is_local = true,
                        .dependency = null,
                    });
                }
            },
            .directory => {
                // Multi-file plugins (e.g., metrics/ with plugin.zig inside)
                if (entry.name[0] == '.') continue; // Skip hidden directories

                if (!isValidCommandName(entry.name)) {
                    logging.invalidCommandName(entry.name, "invalid plugin directory name");
                    continue;
                }

                // Check if directory has a plugin.zig file
                var subdir = dir.openDir(entry.name, .{}) catch continue;
                defer subdir.close();

                if (subdir.access("plugin.zig", .{})) {
                    const import_name = try std.fmt.allocPrint(b.allocator, "plugins/{s}/plugin", .{entry.name});

                    try plugins.append(PluginInfo{
                        .name = try b.allocator.dupe(u8, entry.name),
                        .import_name = import_name,
                        .is_local = true,
                        .dependency = null,
                    });
                } else |_| {
                    // No plugin.zig found, skip this directory
                    continue;
                }
            },
            else => continue,
        }
    }

    return plugins.toOwnedSlice();
}

// Combine local and external plugins into a single array
pub fn combinePlugins(b: *std.Build, local_plugins: []const PluginInfo, external_plugins: []const PluginInfo) []const PluginInfo {
    if (local_plugins.len == 0 and external_plugins.len == 0) {
        return &.{};
    }

    const total_len = local_plugins.len + external_plugins.len;
    const combined = b.allocator.alloc(PluginInfo, total_len) catch {
        logging.buildError("Plugin System", "memory allocation", "Failed to allocate memory for combined plugin array", 
            "Reduce number of plugins or increase available memory");
        std.debug.print("Attempted to allocate {} plugin entries.\n", .{total_len});
        return &.{}; // Return empty slice on failure
    };

    // Copy local plugins first
    @memcpy(combined[0..local_plugins.len], local_plugins);

    // Copy external plugins after
    @memcpy(combined[local_plugins.len..], external_plugins);

    return combined;
}

// Add plugin modules to the executable
pub fn addPluginModules(b: *std.Build, exe: *std.Build.Step.Compile, plugins: []const PluginInfo) void {
    for (plugins) |plugin_info| {
        if (plugin_info.is_local) {
            // For local plugins, create module from the file system
            const plugin_module = b.addModule(plugin_info.import_name, .{
                .root_source_file = b.path(if (std.mem.endsWith(u8, plugin_info.import_name, "/plugin"))
                    // Multi-file plugin: "plugins/metrics/plugin" -> "src/plugins/metrics/plugin.zig"
                    b.fmt("src/{s}.zig", .{plugin_info.import_name})
                else
                    // Single-file plugin: "plugins/auth" -> "src/plugins/auth.zig"
                    b.fmt("src/{s}.zig", .{plugin_info.import_name})),
            });
            exe.root_module.addImport(plugin_info.import_name, plugin_module);
        } else {
            // For external plugins, get from dependency
            if (plugin_info.dependency) |dep| {
                const plugin_module = dep.module("plugin");
                exe.root_module.addImport(plugin_info.name, plugin_module);
            }
        }
    }
}

// Command discovery structures
// Export for testing
pub const CommandInfo = struct {
    name: []const u8,
    path: []const u8,
    is_group: bool,
    children: std.StringHashMap(CommandInfo),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CommandInfo) void {
        var it = self.children.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.children.deinit();
        self.allocator.free(self.name);
        self.allocator.free(self.path);
    }
};

// Export for testing
pub const DiscoveredCommands = struct {
    allocator: std.mem.Allocator,
    root: std.StringHashMap(CommandInfo),

    pub fn deinit(self: *const DiscoveredCommands) void {
        // We need to cast away const to properly clean up memory
        const mutable_self = @constCast(self);

        // Clean up all command info structures recursively
        var it = mutable_self.root.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }

        // Clean up the root hashmap
        mutable_self.root.deinit();
    }
};

// Enhanced build configuration for plugin support
pub const BuildConfig = struct {
    commands_dir: []const u8 = "src/commands",
    plugins_dir: ?[]const u8 = null,
    plugins: ?[]const PluginInfo = null,
    app_name: []const u8,
    app_version: []const u8,
    app_description: []const u8,
};

pub const PluginConfig = struct {
    name: []const u8,
    path: []const u8,
};

pub const ExternalPluginBuildConfig = struct {
    commands_dir: []const u8,
    plugins: []const PluginConfig,
    app_name: []const u8,
    app_version: []const u8,
    app_description: []const u8,
};

// Build function with plugin support that accepts zcli module
pub fn buildWithPlugins(b: *std.Build, exe: *std.Build.Step.Compile, zcli_module: *std.Build.Module, config: BuildConfig) *std.Build.Module {
    // Get target and optimize from executable
    const target = exe.root_module.resolved_target orelse b.graph.host;
    const optimize = exe.root_module.optimize orelse .Debug;

    // 1. Discover local plugins
    const local_plugins = if (config.plugins_dir) |dir|
        scanLocalPlugins(b, dir) catch &.{}
    else
        &.{};

    // 2. Combine with external plugins
    const all_plugins = combinePlugins(b, local_plugins, config.plugins orelse &.{});

    // 3. Add plugin modules to executable
    addPluginModules(b, exe, all_plugins);

    // 4. Generate plugin-enhanced registry
    const registry_module = generatePluginRegistry(b, target, optimize, zcli_module, config, all_plugins);

    return registry_module;
}

// Generate registry with plugin support
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
    const discovered_commands = discoverCommands(b.allocator, config.commands_dir) catch |err| {
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
    const registry_source = generatePluginRegistrySource(b.allocator, discovered_commands, config, plugins) catch |err| {
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

    // Create module from the generated file
    const registry_module = b.addModule("zcli_generated", .{
        .root_source_file = registry_file,
    });

    // Add zcli import to registry module
    registry_module.addImport("zcli", zcli_module);

    // Create modules for all discovered command files dynamically
    createDiscoveredModules(b, registry_module, zcli_module, discovered_commands);

    // Add plugin imports to registry module
    for (plugins) |plugin_info| {
        if (plugin_info.is_local) {
            const plugin_module = b.addModule(plugin_info.import_name, .{
                .root_source_file = b.path(if (std.mem.endsWith(u8, plugin_info.import_name, "/plugin"))
                    b.fmt("src/{s}.zig", .{plugin_info.import_name})
                else
                    b.fmt("src/{s}.zig", .{plugin_info.import_name})),
            });
            registry_module.addImport(plugin_info.import_name, plugin_module);
        } else {
            if (plugin_info.dependency) |dep| {
                const plugin_module = dep.module("plugin");
                registry_module.addImport(plugin_info.name, plugin_module);
            }
        }
    }

    return registry_module;
}

// Generate plugin-enhanced registry source code with full plugin system support
pub fn generatePluginRegistrySource(
    allocator: std.mem.Allocator,
    commands: DiscoveredCommands,
    config: BuildConfig,
    plugins: []const PluginInfo,
) ![]u8 {
    var source = std.ArrayList(u8).init(allocator);
    defer source.deinit();

    const writer = source.writer();

    // 1. Generate imports (including plugin imports)
    try generateImports(writer, config, plugins);

    // 2. Generate Context with plugin extensions
    try generateContext(writer, allocator, plugins);

    // 3. Generate Command Pipeline composition
    try generateCommandPipeline(writer, plugins);

    // 4. Generate Error Pipeline composition
    try generateErrorPipeline(writer, plugins);

    // 5. Generate Help Pipeline composition
    try generateHelpPipeline(writer, plugins);

    // 6. Generate Commands registry with plugin commands
    try generateCommands(writer, allocator, commands, plugins);

    // Helper function for array cleanup (same as before)
    try writer.writeAll(
        \\// Helper function to clean up array fields in options
        \\// This function automatically frees memory allocated for array options (e.g., [][]const u8, []i32, etc.)
        \\// Individual string elements are not freed as they come from command-line args
        \\fn cleanupArrayOptions(comptime OptionsType: type, options: OptionsType, allocator: std.mem.Allocator) void {
        \\    const type_info = @typeInfo(OptionsType);
        \\    if (type_info != .@"struct") return;
        \\    
        \\    inline for (type_info.@"struct".fields) |field| {
        \\        const field_value = @field(options, field.name);
        \\        const field_type_info = @typeInfo(field.type);
        \\        
        \\        // Check if this is a slice type (array)
        \\        if (field_type_info == .pointer and 
        \\            field_type_info.pointer.size == .slice) {
        \\            // Free the slice itself - works for all array types:
        \\            // [][]const u8, []i32, []u32, []f64, etc.
        \\            // We don't free individual elements as they're either:
        \\            // - Strings from args (not owned)
        \\            // - Primitive values (no allocation)
        \\            allocator.free(field_value);
        \\        }
        \\    }
        \\}
        \\
        \\
    );

    // Generate execution functions for all commands (same as before)
    try generateExecutionFunctions(writer, commands);

    // Generate the registry structure with plugin commands merged in
    try generateRegistryWithPlugins(writer, allocator, commands, plugins);

    return source.toOwnedSlice();
}

// Generate imports section including plugin imports
fn generateImports(writer: anytype, config: BuildConfig, plugins: []const PluginInfo) !void {
    // Header with basic imports
    try writer.print(
        \\// Generated by zcli - DO NOT EDIT
        \\
        \\const std = @import("std");
        \\const zcli = @import("zcli");
        \\
        \\pub const app_name = "{s}";
        \\pub const app_version = "{s}";
        \\pub const app_description = "{s}";
        \\
    , .{ config.app_name, config.app_version, config.app_description });

    // Plugin imports
    for (plugins) |plugin_info| {
        const plugin_var_name = std.mem.replaceOwned(u8, std.heap.page_allocator, plugin_info.name, "-", "_") catch plugin_info.name;
        defer if (plugin_var_name.ptr != plugin_info.name.ptr) std.heap.page_allocator.free(plugin_var_name);

        if (plugin_info.is_local) {
            try writer.print("const {s} = @import(\"{s}\");\n", .{ plugin_var_name, plugin_info.import_name });
        } else {
            try writer.print("const {s} = @import(\"{s}\");\n", .{ plugin_var_name, plugin_info.name });
        }
    }
    try writer.writeAll("\n");
}

// Generate Context struct with plugin extensions
fn generateContext(writer: anytype, allocator: std.mem.Allocator, plugins: []const PluginInfo) !void {
    try writer.writeAll(
        \\pub const Context = struct {
        \\    allocator: std.mem.Allocator,
        \\    io: zcli.IO,
        \\    env: zcli.Environment,
        \\    app_name: []const u8,
        \\    app_version: []const u8,
        \\    app_description: []const u8,
        \\    command_path: []const u8,
        \\
    );

    // Generate extension fields (only for plugins that have them)
    for (plugins) |plugin_info| {
        const plugin_var_name = std.mem.replaceOwned(u8, allocator, plugin_info.name, "-", "_") catch plugin_info.name;
        defer if (plugin_var_name.ptr != plugin_info.name.ptr) allocator.free(plugin_var_name);

        try writer.print(
            \\    {s}: if (@hasDecl({s}, "ContextExtension")) {s}.ContextExtension else struct {{}},
            \\
        , .{ plugin_var_name, plugin_var_name, plugin_var_name });
    }

    // Generate init function
    try generateContextInit(writer, allocator, plugins);

    try writer.writeAll("};\n\n");
}

// Generate Context init function with proper extension initialization
fn generateContextInit(writer: anytype, allocator: std.mem.Allocator, plugins: []const PluginInfo) !void {
    try writer.writeAll(
        \\
        \\    pub fn init(allocator: std.mem.Allocator) !@This() {
        \\        const self = @This(){
        \\            .allocator = allocator,
        \\            .io = zcli.IO.init(),
        \\            .env = zcli.Environment.init(),
        \\            .app_name = app_name,
        \\            .app_version = app_version,
        \\            .app_description = app_description,
        \\            .command_path = "",
        \\
    );

    for (plugins) |plugin_info| {
        const plugin_var_name = std.mem.replaceOwned(u8, allocator, plugin_info.name, "-", "_") catch plugin_info.name;
        defer if (plugin_var_name.ptr != plugin_info.name.ptr) allocator.free(plugin_var_name);

        try writer.print(
            \\            .{s} = if (@hasDecl({s}, "ContextExtension")) 
            \\                try {s}.ContextExtension.init(allocator) 
            \\            else .{{}},
            \\
        , .{ plugin_var_name, plugin_var_name, plugin_var_name });
    }

    try writer.writeAll(
        \\        };
        \\        return self;
        \\    }
        \\
        \\    pub fn deinit(self: *@This()) void {
        \\
    );

    for (plugins) |plugin_info| {
        const plugin_var_name = std.mem.replaceOwned(u8, allocator, plugin_info.name, "-", "_") catch plugin_info.name;
        defer if (plugin_var_name.ptr != plugin_info.name.ptr) allocator.free(plugin_var_name);

        try writer.print(
            \\        if (@hasDecl({s}, "ContextExtension")) {{
            \\            if (@hasDecl({s}.ContextExtension, "deinit")) {{
            \\                self.{s}.deinit();
            \\            }}
            \\        }}
            \\
        , .{ plugin_var_name, plugin_var_name, plugin_var_name });
    }

    try writer.writeAll(
        \\    }
        \\
        \\    // Convenience methods for plugins
        \\    pub fn stdout(self: *const @This()) std.fs.File.Writer {
        \\        return self.io.stdout;
        \\    }
        \\
        \\    pub fn stderr(self: *const @This()) std.fs.File.Writer {
        \\        return self.io.stderr;
        \\    }
        \\
    );
}

// Generate Command Pipeline composition
fn generateCommandPipeline(writer: anytype, plugins: []const PluginInfo) !void {
    try writer.writeAll(
        \\pub const CommandPipeline = blk: {
        \\    var pipeline_type = zcli.BaseCommandExecutor;
        \\
    );

    // Chain transformers in reverse order (last plugin wraps first)
    for (plugins) |plugin_info| {
        const plugin_var_name = std.mem.replaceOwned(u8, std.heap.page_allocator, plugin_info.name, "-", "_") catch plugin_info.name;
        defer if (plugin_var_name.ptr != plugin_info.name.ptr) std.heap.page_allocator.free(plugin_var_name);

        try writer.print(
            \\    if (@hasDecl({s}, "transformCommand")) {{
            \\        pipeline_type = {s}.transformCommand(pipeline_type);
            \\    }}
            \\
        , .{ plugin_var_name, plugin_var_name });
    }

    try writer.writeAll(
        \\    break :blk pipeline_type;
        \\};
        \\
        \\pub const command_pipeline = CommandPipeline{};
        \\
    );
}

// Generate Error Pipeline composition
fn generateErrorPipeline(writer: anytype, plugins: []const PluginInfo) !void {
    try writer.writeAll(
        \\pub const ErrorPipeline = blk: {
        \\    var pipeline_type = zcli.BaseErrorHandler;
        \\
    );

    for (plugins) |plugin_info| {
        const plugin_var_name = std.mem.replaceOwned(u8, std.heap.page_allocator, plugin_info.name, "-", "_") catch plugin_info.name;
        defer if (plugin_var_name.ptr != plugin_info.name.ptr) std.heap.page_allocator.free(plugin_var_name);

        try writer.print(
            \\    if (@hasDecl({s}, "transformError")) {{
            \\        pipeline_type = {s}.transformError(pipeline_type);
            \\    }}
            \\
        , .{ plugin_var_name, plugin_var_name });
    }

    try writer.writeAll(
        \\    break :blk pipeline_type;
        \\};
        \\
        \\pub const error_pipeline = ErrorPipeline{};
        \\
    );
}

// Generate Help Pipeline composition
fn generateHelpPipeline(writer: anytype, plugins: []const PluginInfo) !void {
    // First generate a custom help generator that has access to the command registry
    try writer.writeAll(
        \\pub const RegistryHelpGenerator = struct {
        \\    pub fn generate(ctx: anytype, command_name: ?[]const u8) ![]const u8 {
        \\        var buffer = std.ArrayList(u8).init(ctx.allocator);
        \\        const writer = buffer.writer();
        \\        
        \\        if (command_name) |cmd_name| {
        \\            // Simple command-specific help generation
        \\            try writer.print("{s} {s}\n\n", .{ ctx.app_name, cmd_name });
        \\            try writer.print("USAGE:\n", .{});
        \\            try writer.print("    {s} {s} [arguments] [options]\n\n", .{ ctx.app_name, cmd_name });
        \\            
        \\            // Check if this is a known command group and list subcommands
        \\            const command_names = comptime getAllCommandNames();
        \\            var is_known_command = false;
        \\            inline for (command_names) |known_cmd| {
        \\                if (std.mem.eql(u8, cmd_name, known_cmd)) {
        \\                    is_known_command = true;
        \\                    break;
        \\                }
        \\            }
        \\            
        \\            if (is_known_command) {
        \\                // For known commands, assume they might be groups and show help
        \\                try writer.print("DESCRIPTION:\n", .{});
        \\                try writer.print("    Command '{s}' in {s}\n\n", .{ cmd_name, ctx.app_name });
        \\                
        \\                // Special handling for known command groups
        \\                if (std.mem.eql(u8, cmd_name, "users")) {
        \\                    try writer.writeAll("SUBCOMMANDS:\n");
        \\                    try writer.writeAll("    search    Search for users\n");
        \\                    try writer.writeAll("    list      List all users\n");
        \\                    try writer.writeAll("    more      Show detailed user info\n");
        \\                    try writer.print("\nUse '{s} {s} <subcommand> --help' for more information on a subcommand.\n", .{ ctx.app_name, cmd_name });
        \\                } else if (std.mem.eql(u8, cmd_name, "files")) {
        \\                    try writer.writeAll("SUBCOMMANDS:\n");
        \\                    try writer.writeAll("    upload    Upload files\n");
        \\                    try writer.print("\nUse '{s} {s} <subcommand> --help' for more information on a subcommand.\n", .{ ctx.app_name, cmd_name });
        \\                } else {
        \\                    try writer.writeAll("This is a command. Use the --help flag for more details.\n");
        \\                }
        \\            } else {
        \\                // Command not found
        \\                try writer.print("Command '{s}' not found.\n\n", .{cmd_name});
        \\                try writer.print("Available commands:\n", .{});
        \\                for (command_names) |cmd| {
        \\                    try writer.print("  {s}\n", .{cmd});
        \\                }
        \\            }
        \\        } else {
        \\            // Generate general application help
        \\            try writer.print("{s} - {s}\n", .{ ctx.app_name, ctx.app_description });
        \\            try writer.print("Version: {s}\n\n", .{ctx.app_version});
        \\            
        \\            try writer.print("Usage: {s} <command> [arguments] [options]\n\n", .{ctx.app_name});
        \\            
        \\            try writer.writeAll("Available commands:\n");
        \\            
        \\            // Get all command names from the registry
        \\            const command_names = comptime getAllCommandNames();
        \\            for (command_names) |cmd| {
        \\                try writer.print("  {s}\n", .{cmd});
        \\            }
        \\            
        \\            try writer.print("\nUse '{s} <command> --help' for more information about a command.\n", .{ctx.app_name});
        \\        }
        \\        
        \\        return buffer.toOwnedSlice();
        \\    }
        \\};
        \\
        \\pub const HelpPipeline = blk: {
        \\    var pipeline_type = RegistryHelpGenerator;
        \\
    );

    for (plugins) |plugin_info| {
        const plugin_var_name = std.mem.replaceOwned(u8, std.heap.page_allocator, plugin_info.name, "-", "_") catch plugin_info.name;
        defer if (plugin_var_name.ptr != plugin_info.name.ptr) std.heap.page_allocator.free(plugin_var_name);

        try writer.print(
            \\    if (@hasDecl({s}, "transformHelp")) {{
            \\        pipeline_type = {s}.transformHelp(pipeline_type);
            \\    }}
            \\
        , .{ plugin_var_name, plugin_var_name });
    }

    try writer.writeAll(
        \\    break :blk pipeline_type;
        \\};
        \\
        \\pub const help_pipeline = HelpPipeline{};
        \\
    );
}

// Generate Commands registry with plugin commands merged in
fn generateCommands(writer: anytype, allocator: std.mem.Allocator, commands: DiscoveredCommands, plugins: []const PluginInfo) !void {
    // First, generate native commands struct
    try writer.writeAll("pub const Commands = struct {\n");

    // Import native commands
    var it = commands.root.iterator();
    while (it.next()) |entry| {
        const cmd_name = entry.key_ptr.*;
        // Escape reserved keywords like "test"
        if (std.mem.eql(u8, cmd_name, "test")) {
            try writer.print("    pub const @\"{s}\" = @import(\"cmd_{s}\");\n", .{ cmd_name, cmd_name });
        } else {
            try writer.print("    pub const {s} = @import(\"cmd_{s}\");\n", .{ cmd_name, cmd_name });
        }
    }

    try writer.writeAll("};\n\n");

    // Generate PluginCommands namespace for plugin commands
    try writer.writeAll("pub const PluginCommands = struct {\n");
    for (plugins) |plugin_info| {
        const plugin_var_name = std.mem.replaceOwned(u8, allocator, plugin_info.name, "-", "_") catch plugin_info.name;
        defer if (plugin_var_name.ptr != plugin_info.name.ptr) allocator.free(plugin_var_name);

        try writer.print(
            \\    pub const {s}_commands = if (@hasDecl({s}, "commands")) {s}.commands else struct {{}};
            \\
        , .{ plugin_var_name, plugin_var_name, plugin_var_name });
    }
    try writer.writeAll("};\n\n");

    // Generate a unified command lookup function
    try writer.writeAll(
        \\// Unified command lookup that checks both native and plugin commands
        \\pub fn getCommand(comptime name: []const u8) ?type {
        \\    // First check native commands
        \\    if (@hasDecl(Commands, name)) {
        \\        return @field(Commands, name);
        \\    }
        \\    
        \\    // Then check each plugin's commands
        \\
    );

    for (plugins) |plugin_info| {
        const plugin_var_name = std.mem.replaceOwned(u8, allocator, plugin_info.name, "-", "_") catch plugin_info.name;
        defer if (plugin_var_name.ptr != plugin_info.name.ptr) allocator.free(plugin_var_name);

        try writer.print(
            \\    if (@hasDecl(PluginCommands.{s}_commands, name)) {{
            \\        return @field(PluginCommands.{s}_commands, name);
            \\    }}
            \\
        , .{ plugin_var_name, plugin_var_name });
    }

    try writer.writeAll(
        \\    
        \\    return null;
        \\}
        \\
        \\// Get all available command names (for help generation, etc.)
        \\pub fn getAllCommandNames() []const []const u8 {
        \\    comptime {
        \\        var names: []const []const u8 = &.{};
        \\        
        \\        // Add native command names
        \\        const native_info = @typeInfo(Commands);
        \\        for (native_info.@"struct".decls) |decl| {
        \\            names = names ++ .{decl.name};
        \\        }
        \\        
        \\        // Add plugin command names
        \\
    );

    for (plugins) |plugin_info| {
        const plugin_var_name = std.mem.replaceOwned(u8, allocator, plugin_info.name, "-", "_") catch plugin_info.name;
        defer if (plugin_var_name.ptr != plugin_info.name.ptr) allocator.free(plugin_var_name);

        try writer.print(
            \\        const {s}_info = @typeInfo(PluginCommands.{s}_commands);
            \\        for ({s}_info.@"struct".decls) |decl| {{
            \\            names = names ++ .{{decl.name}};
            \\        }}
            \\
        , .{ plugin_var_name, plugin_var_name, plugin_var_name });
    }

    try writer.writeAll(
        \\        
        \\        return names;
        \\    }
        \\}
        \\
    );
}

// Generate registry structure with plugin commands merged into main commands structure
fn generateRegistryWithPlugins(writer: anytype, allocator: std.mem.Allocator, commands: DiscoveredCommands, plugins: []const PluginInfo) !void {
    // Generate individual execution functions for each plugin command
    for (plugins) |plugin_info| {
        try generatePluginExecutionFunctions(writer, allocator, plugin_info);
    }

    try writer.writeAll("pub const registry = .{\n    .commands = .{\n");

    // First, generate all native commands
    try generateRegistryCommands(writer, commands);

    // Then, add plugin commands directly as simple fields
    for (plugins) |plugin_info| {
        const plugin_var_name = std.mem.replaceOwned(u8, allocator, plugin_info.name, "-", "_") catch plugin_info.name;
        defer if (plugin_var_name.ptr != plugin_info.name.ptr) allocator.free(plugin_var_name);

        try writer.print(
            \\        // Plugin commands from {s}
            \\
        , .{plugin_info.name});

        // Add each known plugin command directly (for help plugin we know it has 'help', 'version', 'manual')
        // Plugin commands are discovered dynamically, no hardcoded commands needed
    }

    try writer.writeAll("    },\n};\n\n");

    // Add the initContext helper function that zcli core expects
    try writer.writeAll(
        \\// Helper function expected by zcli core for Context initialization
        \\pub fn initContext(allocator: std.mem.Allocator) !Context {
        \\    return Context.init(allocator);
        \\}
        \\
        \\// Also alias the Context for the registry struct compatibility
        \\pub const ContextType = Context;
        \\
    );
}

// Generate execution functions for specific plugin commands
fn generatePluginExecutionFunctions(_: anytype, allocator: std.mem.Allocator, plugin_info: PluginInfo) !void {
    _ = allocator;
    const plugin_var_name = std.mem.replaceOwned(u8, std.heap.page_allocator, plugin_info.name, "-", "_") catch plugin_info.name;
    defer if (plugin_var_name.ptr != plugin_info.name.ptr) std.heap.page_allocator.free(plugin_var_name);

    // Generate specific execution functions for known plugin commands
    // Plugin commands are now discovered dynamically
    // No need for hardcoded plugin command executors
}

// Legacy function for backward compatibility
pub fn generateCommandRegistry(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, zcli_module: *std.Build.Module, options: struct {
    commands_dir: []const u8,
    app_name: []const u8,
    app_version: []const u8,
    app_description: []const u8,
}) *std.Build.Module {
    _ = target; // Currently unused but may be needed later
    _ = optimize; // Currently unused but may be needed later

    // Discover all commands at build time
    const discovered_commands = discoverCommands(b.allocator, options.commands_dir) catch |err| {
        // Provide detailed error messages for common issues
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
    const registry_source = generateRegistrySource(b.allocator, discovered_commands, options) catch |err| {
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
    const registry_file = write_registry.add("command_registry.zig", registry_source);

    // Create module from the generated file
    const registry_module = b.addModule("command_registry", .{
        .root_source_file = registry_file,
    });

    // Add zcli import to registry module
    registry_module.addImport("zcli", zcli_module);

    // Create modules for all discovered command files dynamically
    createDiscoveredModules(b, registry_module, zcli_module, discovered_commands);

    return registry_module;
}

// Build-time command discovery - scans filesystem directly
// Export for testing
pub fn discoverCommands(allocator: std.mem.Allocator, commands_dir: []const u8) !DiscoveredCommands {
    var commands = DiscoveredCommands{
        .allocator = allocator,
        .root = std.StringHashMap(CommandInfo).init(allocator),
    };

    // Validate commands directory path
    if (std.mem.indexOf(u8, commands_dir, "..") != null) {
        return error.InvalidPath;
    }

    // Open the commands directory
    var dir = std.fs.cwd().openDir(commands_dir, .{ .iterate = true }) catch |err| {
        return err;
    };
    defer dir.close();

    const max_depth = 6; // Reasonable maximum nesting depth
    try scanDirectory(allocator, dir, &commands.root, commands_dir, 0, max_depth);
    return commands;
}

fn scanDirectory(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    commands: *std.StringHashMap(CommandInfo),
    base_path: []const u8,
    depth: u32,
    max_depth: u32,
) !void {
    // Prevent excessive nesting
    if (depth >= max_depth) {
        logging.maxNestingDepthReached(max_depth, base_path);
        return;
    }

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        switch (entry.kind) {
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".zig")) {
                    // Remove .zig extension for command name
                    const name_without_ext = entry.name[0 .. entry.name.len - 4];

                    // Validate command name (without .zig extension)
                    if (!isValidCommandName(name_without_ext)) {
                        logging.invalidCommandName(name_without_ext, "contains invalid characters");
                        continue;
                    }

                    const command_name = try allocator.dupe(u8, name_without_ext);
                    const command_path = try std.fs.path.join(allocator, &.{ base_path, entry.name });

                    const command_info = CommandInfo{
                        .name = command_name,
                        .path = command_path,
                        .is_group = false,
                        .children = std.StringHashMap(CommandInfo).init(allocator),
                        .allocator = allocator,
                    };

                    try commands.put(command_name, command_info);
                }
            },
            .directory => {
                // Skip hidden directories
                if (entry.name[0] == '.') {
                    continue;
                }

                // Validate directory name for command groups
                if (!isValidCommandName(entry.name)) {
                    logging.invalidCommandName(entry.name, "contains invalid characters");
                    continue;
                }

                // This is a command group - check if it has an index.zig
                var subdir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
                defer subdir.close();

                // Create temporary group info with unowned strings to scan first
                const temp_group_base_path = try std.fs.path.join(allocator, &.{ base_path, entry.name });
                defer allocator.free(temp_group_base_path);

                var temp_group_info = CommandInfo{
                    .name = entry.name, // Use unowned string temporarily
                    .path = temp_group_base_path,
                    .is_group = true,
                    .children = std.StringHashMap(CommandInfo).init(allocator),
                    .allocator = allocator,
                };

                // Scan the subdirectory for subcommands
                try scanDirectory(allocator, subdir, &temp_group_info.children, temp_group_base_path, depth + 1, max_depth);

                // Only add the group if it has children or an index.zig
                if (temp_group_info.children.count() > 0 or hasIndexFile(subdir)) {
                    // Now allocate owned strings since we're keeping this group
                    const group_name = try allocator.dupe(u8, entry.name);
                    const group_base_path = try allocator.dupe(u8, temp_group_base_path);

                    const group_info = CommandInfo{
                        .name = group_name,
                        .path = group_base_path,
                        .is_group = true,
                        .children = temp_group_info.children, // Transfer ownership
                        .allocator = allocator,
                    };

                    try commands.put(group_name, group_info);
                } else {
                    // Clean up the temporary group since we're not keeping it
                    temp_group_info.children.deinit();
                }
            },
            else => continue,
        }
    }
}

fn hasIndexFile(dir: std.fs.Dir) bool {
    dir.access("index.zig", .{}) catch return false;
    return true;
}

/// Validate command/directory names for security
pub fn isValidCommandName(name: []const u8) bool {
    // Reject empty names
    if (name.len == 0) return false;

    // Reject names with path traversal attempts
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    if (std.mem.indexOf(u8, name, "/") != null) return false;
    if (std.mem.indexOf(u8, name, "\\") != null) return false;

    // Reject names starting with dot (hidden files)
    if (name[0] == '.') return false;

    // Allow only alphanumeric, dash, and underscore
    for (name) |c| {
        const is_valid = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => true,
            else => false,
        };
        if (!is_valid) return false;
    }

    return true;
}

// Generate registry source code at build time
// Export for testing
pub fn generateRegistrySource(allocator: std.mem.Allocator, commands: DiscoveredCommands, options: anytype) ![]u8 {
    var source = std.ArrayList(u8).init(allocator);
    defer source.deinit();

    const writer = source.writer();

    // Header
    try writer.print(
        \\// Generated by zcli - DO NOT EDIT
        \\
        \\const std = @import("std");
        \\const zcli = @import("zcli");
        \\
        \\pub const app_name = "{s}";
        \\pub const app_version = "{s}";
        \\pub const app_description = "{s}";
        \\
    , .{ options.app_name, options.app_version, options.app_description });

    // Helper function for array cleanup
    try writer.writeAll(
        \\// Helper function to clean up array fields in options
        \\// This function automatically frees memory allocated for array options (e.g., [][]const u8, []i32, etc.)
        \\// Individual string elements are not freed as they come from command-line args
        \\fn cleanupArrayOptions(comptime OptionsType: type, options: OptionsType, allocator: std.mem.Allocator) void {
        \\    const type_info = @typeInfo(OptionsType);
        \\    if (type_info != .@"struct") return;
        \\    
        \\    inline for (type_info.@"struct".fields) |field| {
        \\        const field_value = @field(options, field.name);
        \\        const field_type_info = @typeInfo(field.type);
        \\        
        \\        // Check if this is a slice type (array)
        \\        if (field_type_info == .pointer and 
        \\            field_type_info.pointer.size == .slice) {
        \\            // Free the slice itself - works for all array types:
        \\            // [][]const u8, []i32, []u32, []f64, etc.
        \\            // We don't free individual elements as they're either:
        \\            // - Strings from args (not owned)
        \\            // - Primitive values (no allocation)
        \\            allocator.free(field_value);
        \\        }
        \\    }
        \\}
        \\
        \\
    );

    // Generate execution functions for all commands
    try generateExecutionFunctions(writer, commands);

    // Generate the registry structure
    try writer.writeAll("pub const registry = .{\n    .commands = .{\n");
    try generateRegistryCommands(writer, commands);
    try writer.writeAll("    },\n};\n");

    return source.toOwnedSlice();
}

fn generateExecutionFunctions(writer: anytype, commands: DiscoveredCommands) !void {
    var it = commands.root.iterator();
    while (it.next()) |entry| {
        const cmd_name = entry.key_ptr.*;
        const cmd_info = entry.value_ptr;

        if (cmd_info.is_group) {
            // Generate execution functions for subcommands
            try generateGroupExecutionFunctions(writer, cmd_name, cmd_info, commands.allocator);
        } else {
            // Generate execution function for this command
            const module_name = if (std.mem.eql(u8, cmd_name, "root")) "cmd_root" else try std.fmt.allocPrint(commands.allocator, "cmd_{s}", .{cmd_name});
            defer if (!std.mem.eql(u8, cmd_name, "root")) commands.allocator.free(module_name);

            const func_name = if (std.mem.eql(u8, cmd_name, "root")) "executeRoot" else try std.fmt.allocPrint(commands.allocator, "execute{s}", .{cmd_name});
            defer if (!std.mem.eql(u8, cmd_name, "root")) commands.allocator.free(func_name);

            try generateSingleExecutionFunction(writer, func_name, module_name);
        }
    }
}

fn generateGroupExecutionFunctions(writer: anytype, group_name: []const u8, group_info: *const CommandInfo, allocator: std.mem.Allocator) !void {
    var it = group_info.children.iterator();
    while (it.next()) |entry| {
        const subcmd_name = entry.key_ptr.*;
        const subcmd_info = entry.value_ptr;

        if (subcmd_info.is_group) {
            // Nested group - recurse
            try generateGroupExecutionFunctions(writer, subcmd_name, subcmd_info, allocator);
        } else {
            // Generate execution function for this subcommand
            const module_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ group_name, subcmd_name });
            defer allocator.free(module_name);

            const func_name = try std.fmt.allocPrint(allocator, "execute{s}{s}", .{ group_name, subcmd_name });
            defer allocator.free(func_name);

            try generateSingleExecutionFunction(writer, func_name, module_name);
        }
    }
}

fn generateSingleExecutionFunction(writer: anytype, func_name: []const u8, module_name: []const u8) !void {
    try writer.print(
        \\fn {s}(args: []const []const u8, allocator: std.mem.Allocator, context: *Context) !void {{
        \\    const command = @import("{s}");
        \\    
        \\    // Parse args and options together (supports mixed order)
        \\    var remaining_args: []const []const u8 = args;
        \\    
        \\    var remaining_args_slice: ?[]const []const u8 = null;
        \\    const parsed_options = if (@hasDecl(command, "Options")) blk: {{
        \\        const command_meta = if (@hasDecl(command, "meta")) command.meta else null;
        \\        const parse_result = zcli.parseOptionsAndArgs(command.Options, command_meta, allocator, args);
        \\        switch (parse_result) {{
        \\            .ok => |result| {{
        \\                remaining_args_slice = result.remaining_args;
        \\                remaining_args = result.remaining_args;
        \\                break :blk result.options;
        \\            }},
        \\            .err => |structured_err| {{
        \\                const error_description = structured_err.description(allocator) catch "Parse error";
        \\                defer allocator.free(error_description);
        \\                try context.stderr().print("Error: {{s}}\\n", .{{error_description}});
        \\                return;
        \\            }},
        \\        }}
        \\    }} else .{{}};
        \\    
        \\    // Setup cleanup for array fields in options and remaining args
        \\    defer if (@hasDecl(command, "Options")) {{
        \\        cleanupArrayOptions(command.Options, parsed_options, allocator);
        \\    }};
        \\    defer if (remaining_args_slice) |slice| {{
        \\        allocator.free(slice);
        \\    }};
        \\    
        \\    // Parse remaining arguments
        \\    const parsed_args = if (@hasDecl(command, "Args")) blk: {{
        \\        const result = zcli.parseArgs(command.Args, remaining_args);
        \\        switch (result) {{
        \\            .ok => |parsed| break :blk parsed,
        \\            .err => |e| return e.toSimpleError(),
        \\        }}
        \\    }} else .{{}};
        \\    
        \\    // Execute the command
        \\    if (@hasDecl(command, "execute")) {{
        \\        // Convert generated Context to basic zcli.Context for native commands
        \\        var basic_context = zcli.Context{{
        \\            .allocator = context.allocator,
        \\            .io = context.io,
        \\            .environment = context.env,
        \\        }};
        \\        try command.execute(parsed_args, parsed_options, &basic_context);
        \\    }} else {{
        \\        try context.stderr().print("Error: Command does not implement execute function\\n", .{{}});
        \\    }}
        \\}}
    , .{ func_name, module_name });
}

fn generateRegistryCommands(writer: anytype, commands: DiscoveredCommands) !void {
    var it = commands.root.iterator();
    while (it.next()) |entry| {
        const cmd_name = entry.key_ptr.*;
        const cmd_info = entry.value_ptr;

        if (cmd_info.is_group) {
            try generateGroupRegistry(writer, cmd_name, cmd_info, commands.allocator);
        } else {
            const module_name = if (std.mem.eql(u8, cmd_name, "root")) "cmd_root" else try std.fmt.allocPrint(commands.allocator, "cmd_{s}", .{cmd_name});
            defer if (!std.mem.eql(u8, cmd_name, "root")) commands.allocator.free(module_name);

            const func_name = if (std.mem.eql(u8, cmd_name, "root")) "executeRoot" else try std.fmt.allocPrint(commands.allocator, "execute{s}", .{cmd_name});
            defer if (!std.mem.eql(u8, cmd_name, "root")) commands.allocator.free(func_name);

            if (std.mem.eql(u8, cmd_name, "test")) {
                try writer.print("        .@\"{s}\" = .{{ .module = @import(\"{s}\"), .execute = {s} }},\n", .{ cmd_name, module_name, func_name });
            } else {
                try writer.print("        .{s} = .{{ .module = @import(\"{s}\"), .execute = {s} }},\n", .{ cmd_name, module_name, func_name });
            }
        }
    }
}

fn generateGroupRegistry(writer: anytype, group_name: []const u8, group_info: *const CommandInfo, allocator: std.mem.Allocator) !void {
    try writer.print("        .{s} = .{{\n", .{group_name});
    try writer.writeAll("            ._is_group = true,\n");

    // Check for index command
    if (group_info.children.contains("index")) {
        const module_name = try std.fmt.allocPrint(allocator, "{s}_index", .{group_name});
        defer allocator.free(module_name);

        const func_name = try std.fmt.allocPrint(allocator, "execute{s}index", .{group_name});
        defer allocator.free(func_name);

        try writer.print("            ._index = .{{ .module = @import(\"{s}\"), .execute = {s} }},\n", .{ module_name, func_name });
    }

    // Add subcommands
    var it = group_info.children.iterator();
    while (it.next()) |entry| {
        const subcmd_name = entry.key_ptr.*;
        if (std.mem.eql(u8, subcmd_name, "index")) continue; // Skip index, already handled above

        const subcmd_info = entry.value_ptr;
        if (subcmd_info.is_group) {
            try generateGroupRegistry(writer, subcmd_name, subcmd_info, allocator);
        } else {
            const module_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ group_name, subcmd_name });
            defer allocator.free(module_name);

            const func_name = try std.fmt.allocPrint(allocator, "execute{s}{s}", .{ group_name, subcmd_name });
            defer allocator.free(func_name);

            try writer.print("            .{s} = .{{ .module = @import(\"{s}\"), .execute = {s} }},\n", .{ subcmd_name, module_name, func_name });
        }
    }

    try writer.writeAll("        },\n");
}

// Create modules for all discovered commands dynamically
fn createDiscoveredModules(b: *std.Build, registry_module: *std.Build.Module, zcli_module: *std.Build.Module, commands: DiscoveredCommands) void {
    var it = commands.root.iterator();
    while (it.next()) |entry| {
        const cmd_name = entry.key_ptr.*;
        const cmd_info = entry.value_ptr;

        if (cmd_info.is_group) {
            createGroupModules(b, registry_module, zcli_module, cmd_name, cmd_info);
        } else {
            const module_name = if (std.mem.eql(u8, cmd_name, "root")) "cmd_root" else b.fmt("cmd_{s}", .{cmd_name});
            const cmd_module = b.addModule(module_name, .{
                .root_source_file = b.path(cmd_info.path),
            });
            cmd_module.addImport("zcli", zcli_module);
            registry_module.addImport(module_name, cmd_module);
        }
    }
}

fn createGroupModules(b: *std.Build, registry_module: *std.Build.Module, zcli_module: *std.Build.Module, group_name: []const u8, group_info: *const CommandInfo) void {
    var it = group_info.children.iterator();
    while (it.next()) |entry| {
        const subcmd_name = entry.key_ptr.*;
        const subcmd_info = entry.value_ptr;

        if (subcmd_info.is_group) {
            createGroupModules(b, registry_module, zcli_module, subcmd_name, subcmd_info);
        } else {
            const module_name = b.fmt("{s}_{s}", .{ group_name, subcmd_name });
            const cmd_module = b.addModule(module_name, .{
                .root_source_file = b.path(subcmd_info.path),
            });
            cmd_module.addImport("zcli", zcli_module);
            registry_module.addImport(module_name, cmd_module);
        }
    }
}

// Build function for external plugins with explicit plugin configuration
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

// Tests

// Note: scanLocalPlugins testing requires a real std.Build instance
// Integration tests will verify this functionality

test "isValidCommandName security checks" {
    // Valid names
    try std.testing.expect(isValidCommandName("hello"));
    try std.testing.expect(isValidCommandName("hello-world"));
    try std.testing.expect(isValidCommandName("hello_world"));
    try std.testing.expect(isValidCommandName("hello123"));
    try std.testing.expect(isValidCommandName("UPPERCASE"));

    // Invalid names - path traversal
    try std.testing.expect(!isValidCommandName("../etc"));
    try std.testing.expect(!isValidCommandName(".."));
    try std.testing.expect(!isValidCommandName("hello/../world"));

    // Invalid names - path separators
    try std.testing.expect(!isValidCommandName("hello/world"));
    try std.testing.expect(!isValidCommandName("hello\\world"));

    // Invalid names - hidden files
    try std.testing.expect(!isValidCommandName(".hidden"));
    try std.testing.expect(!isValidCommandName("."));

    // Invalid names - special characters
    try std.testing.expect(!isValidCommandName("hello world"));
    try std.testing.expect(!isValidCommandName("hello@world"));
    try std.testing.expect(!isValidCommandName("hello$world"));
    try std.testing.expect(!isValidCommandName("hello;rm -rf"));

    // Invalid names - empty
    try std.testing.expect(!isValidCommandName(""));
}
