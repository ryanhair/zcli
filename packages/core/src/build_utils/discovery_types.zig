const std = @import("std");

// ============================================================================
// DISCOVERY TYPES — the command-discovery data model
//
// Runtime-safe: nothing here references std.Build. These types are shared by
// the build-time scanner and runtime discovery (zcli tree, zcli dev), so they
// live apart from build_utils/types.zig, which holds std.Build-only types —
// runtime code must never need to import that file.
// ============================================================================

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
