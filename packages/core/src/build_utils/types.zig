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
    /// Optional initialization code (from PluginConfig)
    init: ?[]const u8 = null,
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
    hidden: bool = false, // Whether this command should be hidden from help/completions
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

/// Shared module that should be available to all commands
pub const SharedModule = struct {
    name: []const u8,
    module: *std.Build.Module,
};

/// Configuration to apply to a command module for native dependencies
pub const CommandModuleConfig = struct {
    /// C source files needed by this module
    c_sources: ?[]const []const u8 = null,

    /// C compiler flags
    c_flags: ?[]const []const u8 = null,

    /// C++ source files needed by this module
    cpp_sources: ?[]const []const u8 = null,

    /// C++ compiler flags
    cpp_flags: ?[]const []const u8 = null,

    /// Include paths for C/C++ headers
    include_paths: ?[]const []const u8 = null,

    /// System libraries to link (e.g., "curl", "sqlite3")
    system_libs: ?[]const []const u8 = null,

    /// Whether to link libc (default: auto-detect based on c_sources/system_libs)
    link_libc: ?bool = null,

    /// Whether to link libc++ (default: auto-detect based on cpp_sources)
    link_libcpp: ?bool = null,
};

/// Per-command module with optional build configuration
pub const CommandModule = struct {
    /// Module name for import in the command
    name: []const u8,

    /// The module itself
    module: *std.Build.Module,

    /// Optional build configuration to apply to the command module
    config: ?CommandModuleConfig = null,
};

/// Configuration for a specific command with per-command modules
pub const CommandConfig = struct {
    /// Command path (e.g., &.{"container", "ls"} for "container ls" command)
    command_path: []const []const u8,

    /// Modules specific to this command with their configurations
    modules: []const CommandModule = &.{},
};

/// Enhanced build configuration for plugin support
pub const BuildConfig = struct {
    commands_dir: []const u8,
    plugins_dir: ?[]const u8,
    plugins: ?[]const PluginInfo,
    shared_modules: ?[]const SharedModule = null,
    command_configs: ?[]const CommandConfig = null,
    app_name: []const u8,
    app_version: []const u8,
    app_description: []const u8,
};

/// Plugin configuration for external plugins
pub const PluginConfig = struct {
    name: []const u8,
    path: []const u8,
    /// Optional initialization code to call on the plugin
    /// Example: ".init(.{ .repo = \"user/repo\", .command_name = \"upgrade\" })"
    /// Will generate: const plugin = @import("name")<init_code>;
    init: ?[]const u8 = null,
};

/// External plugin build configuration
pub const ExternalPluginBuildConfig = struct {
    commands_dir: []const u8,
    plugins: []const PluginConfig,
    app_name: []const u8,
    app_version: []const u8,
    app_description: []const u8,
};
