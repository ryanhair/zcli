const std = @import("std");
const logging = @import("../logging.zig");
const types = @import("types.zig");

const PluginInfo = types.PluginInfo;
const PluginConfig = types.PluginConfig;

// ============================================================================
// PLUGIN SYSTEM - Discovery, management, and configuration
// ============================================================================

/// Helper function to create external plugin references
pub fn plugin(b: *std.Build, name: []const u8) PluginInfo {
    return PluginInfo{
        .name = name,
        .import_name = name,
        .is_local = false,
        .dependency = b.lazyDependency(name, .{}),
    };
}

/// Scan local plugins directory and return plugin info
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

                    if (!isValidPluginName(plugin_name)) {
                        logging.invalidCommandName(plugin_name, "invalid plugin name");
                        continue;
                    }

                    const import_name = try std.fmt.allocPrint(b.allocator, "plugins/{s}", .{plugin_name});

                    try plugins.append(PluginInfo{
                        .name = plugin_name,
                        .import_name = import_name,
                        .is_local = true,
                        .dependency = null,
                    });
                }
            },
            .directory => {
                // Multi-file plugins (e.g., metrics/ with plugin.zig inside)
                if (entry.name[0] == '.') continue; // Skip hidden directories

                if (!isValidPluginName(entry.name)) {
                    logging.invalidCommandName(entry.name, "invalid plugin directory name");
                    continue;
                }

                // Check if directory has a plugin.zig file
                var subdir = dir.openDir(entry.name, .{}) catch continue;
                defer subdir.close();

                _ = subdir.statFile("plugin.zig") catch continue; // Skip if no plugin.zig

                const import_name = try std.fmt.allocPrint(b.allocator, "plugins/{s}/plugin", .{entry.name});

                try plugins.append(PluginInfo{
                    .name = entry.name,
                    .import_name = import_name,
                    .is_local = true,
                    .dependency = null,
                });
            },
            else => continue,
        }
    }

    return plugins.toOwnedSlice();
}

/// Combine local and external plugins into a single array
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

/// Add plugin modules to the executable
pub fn addPluginModules(b: *std.Build, exe: *std.Build.Step.Compile, plugins: []const PluginInfo) void {
    // Get zcli module from the executable's imports to pass to plugins
    const zcli_module = exe.root_module.import_table.get("zcli") orelse {
        std.debug.panic("zcli module not found in executable imports. Add zcli import before calling addPluginModules.", .{});
    };

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
            plugin_module.addImport("zcli", zcli_module);
            exe.root_module.addImport(plugin_info.import_name, plugin_module);
        } else {
            // For external plugins, get from dependency and add zcli import
            if (plugin_info.dependency) |dep| {
                const plugin_module = dep.module("plugin");
                plugin_module.addImport("zcli", zcli_module);
                exe.root_module.addImport(plugin_info.name, plugin_module);
            }
        }
    }
}

/// Validate plugin name according to same rules as command names
fn isValidPluginName(name: []const u8) bool {
    if (name.len == 0) return false;
    
    // Check for forbidden patterns
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    if (std.mem.indexOf(u8, name, "/") != null) return false;
    if (std.mem.indexOf(u8, name, "\\") != null) return false;
    
    // Check first character
    const first = name[0];
    if (!std.ascii.isAlphabetic(first) and first != '_') return false;
    
    // Check remaining characters
    for (name[1..]) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_' and char != '-') return false;
    }
    
    return true;
}