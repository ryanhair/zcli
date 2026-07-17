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
    /// Optional command group - directory with index.zig; may execute and may
    /// declare positional Args (exact subcommand names win over positionals)
    optional_group,
};

/// Information about a discovered command
pub const DiscoveredCommand = struct {
    name: []const u8,
    path: []const []const u8, // Array of command path components
    file_path: []const u8, // Filesystem path for module loading
    command_type: CommandType,
    hidden: bool = false, // Whether this command should be hidden from help/completions
    subcommands: ?std.StringHashMap(DiscoveredCommand),

    pub fn deinit(self: *DiscoveredCommand, allocator: std.mem.Allocator) void {
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

/// A command map's entries as a slice sorted alphabetically by name.
///
/// Discovery stores each directory level in an (unordered) `StringHashMap`.
/// Routing the code that *emits* commands through this one helper is what makes
/// command order deterministic and alphabetical: the generated registry — and
/// therefore everything downstream that reads it in registration order, like
/// completions — lists commands by name rather than by filesystem-iteration
/// order. `zcli tree` sorts its own display nodes; help re-buckets command info
/// through its own map and sorts there. Caller owns the returned slice.
pub fn sortedByName(allocator: std.mem.Allocator, map: *const std.StringHashMap(DiscoveredCommand)) ![]DiscoveredCommand {
    const entries = try allocator.alloc(DiscoveredCommand, map.count());
    errdefer allocator.free(entries);

    var it = map.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        entries[i] = entry.value_ptr.*;
    }

    std.mem.sort(DiscoveredCommand, entries, {}, lessByName);
    return entries;
}

fn lessByName(_: void, a: DiscoveredCommand, b: DiscoveredCommand) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Container for all discovered commands
pub const DiscoveredCommands = struct {
    allocator: std.mem.Allocator,
    root: std.StringHashMap(DiscoveredCommand),
    /// The root group's own index: a top-level `index.zig` in commands_dir.
    /// The root of the command tree is a group like any other (ADR-0029) —
    /// this is its `optional_group` command, registered at the empty path.
    /// An executable root index with no sibling commands is a single-command
    /// CLI. Null when commands_dir has no top-level index.zig (a pure root).
    root_index: ?DiscoveredCommand = null,

    pub fn init(allocator: std.mem.Allocator) DiscoveredCommands {
        return DiscoveredCommands{
            .allocator = allocator,
            .root = std.StringHashMap(DiscoveredCommand).init(allocator),
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
        if (self.root_index) |*ri| ri.deinit(self.allocator);
    }
};

// ============================================================================
// Tests — sortedByName is the pure helper that makes generated command order
// deterministic; discovery stores entries in an unordered StringHashMap.
// ============================================================================

const testing = std.testing;

fn putBare(map: *std.StringHashMap(DiscoveredCommand), allocator: std.mem.Allocator, name: []const u8) !void {
    try map.put(try allocator.dupe(u8, name), .{
        .name = try allocator.dupe(u8, name),
        .path = &.{},
        .file_path = try allocator.dupe(u8, name),
        .command_type = .leaf,
        .subcommands = null,
    });
}

test "sortedByName returns entries alphabetically regardless of insertion order" {
    const allocator = testing.allocator;
    var commands = DiscoveredCommands.init(allocator);
    defer commands.deinit();

    // Insert deliberately out of alphabetical order.
    try putBare(&commands.root, allocator, "delta");
    try putBare(&commands.root, allocator, "alpha");
    try putBare(&commands.root, allocator, "charlie");
    try putBare(&commands.root, allocator, "bravo");

    const sorted = try sortedByName(allocator, &commands.root);
    defer allocator.free(sorted);

    try testing.expectEqual(@as(usize, 4), sorted.len);
    try testing.expectEqualStrings("alpha", sorted[0].name);
    try testing.expectEqualStrings("bravo", sorted[1].name);
    try testing.expectEqualStrings("charlie", sorted[2].name);
    try testing.expectEqualStrings("delta", sorted[3].name);
}

test "sortedByName on an empty map yields an empty slice" {
    const allocator = testing.allocator;
    var commands = DiscoveredCommands.init(allocator);
    defer commands.deinit();

    const sorted = try sortedByName(allocator, &commands.root);
    defer allocator.free(sorted);

    try testing.expectEqual(@as(usize, 0), sorted.len);
}
