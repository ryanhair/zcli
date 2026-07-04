const std = @import("std");
const logging = @import("../logging.zig");
const types = @import("types.zig");

const PluginInfo = types.PluginInfo;

// ============================================================================
// PLUGIN SYSTEM - Discovery, management, and configuration
// ============================================================================

/// Scan local plugins directory and return plugin info
pub fn scanLocalPlugins(b: *std.Build, plugins_dir: []const u8) ![]PluginInfo {
    var plugins = std.ArrayList(PluginInfo).empty;
    defer plugins.deinit(b.allocator);

    // Validate plugins directory path
    if (std.mem.indexOf(u8, plugins_dir, "..") != null) {
        return error.InvalidPath;
    }

    // Try to open the plugins directory
    var dir = b.build_root.handle.openDir(b.graph.io, plugins_dir, .{ .iterate = true }) catch |err| {
        // If directory doesn't exist, that's fine - just return empty list
        if (err == error.FileNotFound) {
            return &.{};
        }
        return err;
    };
    defer dir.close(b.graph.io);

    var iterator = dir.iterate();
    while (try iterator.next(b.graph.io)) |entry| {
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
                    // `entry.name` aliases the iterator's buffer, reused on the
                    // next `next()`, so `plugin_name` must be duped to outlive the
                    // scan (import_name/project_path already copy via allocPrint).
                    const project_path = try std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ plugins_dir, entry.name });

                    try plugins.append(b.allocator, PluginInfo{
                        .name = try b.allocator.dupe(u8, plugin_name),
                        .import_name = import_name,
                        .is_local = true,
                        .dependency = null,
                        .project_path = project_path,
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
                var subdir = dir.openDir(b.graph.io, entry.name, .{}) catch continue;
                defer subdir.close(b.graph.io);

                _ = subdir.statFile(b.graph.io, "plugin.zig", .{}) catch continue; // Skip if no plugin.zig

                const import_name = try std.fmt.allocPrint(b.allocator, "plugins/{s}/plugin", .{entry.name});
                // Dupe entry.name — it aliases the iterator's reused buffer.
                const project_path = try std.fmt.allocPrint(b.allocator, "{s}/{s}/plugin.zig", .{ plugins_dir, entry.name });

                try plugins.append(b.allocator, PluginInfo{
                    .name = try b.allocator.dupe(u8, entry.name),
                    .import_name = import_name,
                    .is_local = true,
                    .dependency = null,
                    .project_path = project_path,
                });
            },
            else => continue,
        }
    }

    return plugins.toOwnedSlice(b.allocator);
}

/// Combine local and external plugins into a single array
pub fn combinePlugins(b: *std.Build, local_plugins: []const PluginInfo, external_plugins: []const PluginInfo) []const PluginInfo {
    if (local_plugins.len == 0 and external_plugins.len == 0) {
        return &.{};
    }

    const total_len = local_plugins.len + external_plugins.len;
    const combined = b.allocator.alloc(PluginInfo, total_len) catch {
        logging.buildError("Plugin System", "memory allocation", "Failed to allocate memory for combined plugin array", "Reduce number of plugins or increase available memory");
        std.debug.print("Attempted to allocate {} plugin entries.\n", .{total_len});
        return &.{}; // Return empty slice on failure
    };

    // Copy local plugins first
    @memcpy(combined[0..local_plugins.len], local_plugins);

    // Copy external plugins after
    @memcpy(combined[local_plugins.len..], external_plugins);

    return combined;
}

/// Validate a plugin file/directory name: identifier-style first char,
/// then alphanumeric/underscore/dash; path separators and traversal
/// rejected. (Looser than isValidCommandName — no reserved-name list.)
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

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "isValidPluginName: accepts plugin-ish names, rejects traversal and junk" {
    try testing.expect(isValidPluginName("auth"));
    try testing.expect(isValidPluginName("_internal"));
    try testing.expect(isValidPluginName("zcli-help"));
    try testing.expect(isValidPluginName("metrics2"));

    try testing.expect(!isValidPluginName(""));
    try testing.expect(!isValidPluginName("2fast"));
    try testing.expect(!isValidPluginName("has space"));
    try testing.expect(!isValidPluginName("../escape"));
    try testing.expect(!isValidPluginName("a/b"));
    try testing.expect(!isValidPluginName("a\\b"));
}
