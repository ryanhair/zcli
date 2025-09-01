const std = @import("std");

// ============================================================================
// SHARED TYPES - Used across build utility modules
// ============================================================================

/// Information about a plugin (local or external)
pub const PluginInfo = struct {
    name: []const u8,
    import_name: []const u8,
    is_local: bool,
    dependency: ?*std.Build.Dependency,
};

/// Command type classification
pub const CommandType = enum {
    /// Leaf command - regular .zig file that can have Args and Options
    leaf,
    /// Pure command group - directory without index.zig, always shows help
    pure_group,
    /// Optional command group - directory with index.zig, can execute but no Args allowed
    optional_group,
};

/// Information about a discovered command
pub const CommandInfo = struct {
    name: []const u8,
    path: []const []const u8, // Array of command path components
    file_path: []const u8, // Filesystem path for module loading
    command_type: CommandType,
    subcommands: ?std.StringHashMap(CommandInfo),

    pub fn deinit(self: *CommandInfo, allocator: std.mem.Allocator) void {
        // Free allocated strings
        allocator.free(self.name);
        allocator.free(self.file_path);
        // Free path components
        for (self.path) |component| {
            allocator.free(component);
        }
        allocator.free(self.path);

        // Free subcommands if they exist
        if (self.subcommands) |*subcmds| {
            var iterator = subcmds.iterator();
            while (iterator.next()) |entry| {
                // Free subcommand keys
                allocator.free(entry.key_ptr.*);
                // Free subcommand values
                entry.value_ptr.deinit(allocator);
            }
            subcmds.deinit();
        }
    }
};

/// Container for all discovered commands
pub const DiscoveredCommands = struct {
    allocator: std.mem.Allocator,
    root: std.StringHashMap(CommandInfo),

    pub fn init(allocator: std.mem.Allocator) DiscoveredCommands {
        return DiscoveredCommands{
            .allocator = allocator,
            .root = std.StringHashMap(CommandInfo).init(allocator),
        };
    }

    pub fn deinit(self: *DiscoveredCommands) void {
        var iterator = self.root.iterator();
        while (iterator.next()) |entry| {
            // Free the HashMap key (allocated string)
            self.allocator.free(entry.key_ptr.*);
            // Free the command info
            entry.value_ptr.deinit(self.allocator);
        }
        self.root.deinit();
    }
};

/// Enhanced build configuration for plugin support
pub const BuildConfig = struct {
    commands_dir: []const u8,
    plugins_dir: ?[]const u8,
    plugins: ?[]const PluginInfo,
    app_name: []const u8,
    app_version: []const u8,
    app_description: []const u8,
};

/// Plugin configuration for external plugins
pub const PluginConfig = struct {
    name: []const u8,
    path: []const u8,
};

/// External plugin build configuration
pub const ExternalPluginBuildConfig = struct {
    commands_dir: []const u8,
    plugins: []const PluginConfig,
    app_name: []const u8,
    app_version: []const u8,
    app_description: []const u8,
};
