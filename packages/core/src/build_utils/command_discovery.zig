const std = @import("std");
const logging = @import("../logging.zig");
const types = @import("types.zig");

const CommandInfo = types.CommandInfo;
const CommandType = types.CommandType;
const DiscoveredCommands = types.DiscoveredCommands;

// ============================================================================
// COMMAND DISCOVERY - Filesystem scanning and command structure analysis
// ============================================================================

/// Build-time command discovery - scans filesystem directly
pub fn discoverCommands(allocator: std.mem.Allocator, commands_dir: []const u8) !DiscoveredCommands {
    // Security check: prevent directory traversal
    if (std.mem.indexOf(u8, commands_dir, "..") != null) {
        return error.InvalidPath;
    }

    var commands = DiscoveredCommands.init(allocator);
    errdefer commands.deinit();

    // Try to open the commands directory
    var dir = std.fs.cwd().openDir(commands_dir, .{ .iterate = true }) catch |err| {
        return err;
    };
    defer dir.close();

    const max_depth = 6; // Reasonable maximum nesting depth
    try scanDirectory(allocator, dir, &commands.root, &.{}, 0, max_depth);

    return commands;
}

/// Recursively scan a directory for commands
fn scanDirectory(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    commands: *std.StringHashMap(CommandInfo),
    current_path: []const []const u8, // Array of path components
    depth: u32,
    max_depth: u32,
) !void {
    // Prevent excessive nesting
    if (depth >= max_depth) {
        // Convert path array to string for logging
        const path_string = if (current_path.len == 0) "" else std.mem.join(std.heap.page_allocator, "/", current_path) catch "unknown";
        defer if (current_path.len > 0) std.heap.page_allocator.free(path_string);
        logging.maxNestingDepthReached(max_depth, path_string);
        return;
    }
    var iterator = dir.iterate();

    while (try iterator.next()) |entry| {
        switch (entry.kind) {
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".zig")) {
                    const name_without_ext = entry.name[0 .. entry.name.len - 4];

                    // Skip index.zig files - they are handled as group defaults
                    if (std.mem.eql(u8, name_without_ext, "index")) {
                        continue;
                    }

                    // Skip invalid command names
                    if (!isValidCommandName(name_without_ext)) {
                        logging.invalidCommandName(name_without_ext, "contains invalid characters or patterns");
                        continue;
                    }

                    // Build command path as array of components
                    var path_list = std.ArrayList([]const u8){};
                    defer path_list.deinit(allocator);

                    // Add current path components
                    for (current_path) |component| {
                        try path_list.append(allocator, try allocator.dupe(u8, component));
                    }
                    // Add current command name
                    try path_list.append(allocator, try allocator.dupe(u8, name_without_ext));

                    // Build filesystem path
                    var fs_path_list = std.ArrayList([]const u8){};
                    defer fs_path_list.deinit(allocator);
                    for (current_path) |component| {
                        try fs_path_list.append(allocator, component);
                    }
                    try fs_path_list.append(allocator, entry.name);
                    const file_path = try std.mem.join(allocator, "/", fs_path_list.items);

                    const command_info = CommandInfo{
                        .name = try allocator.dupe(u8, name_without_ext),
                        .path = try path_list.toOwnedSlice(allocator),
                        .file_path = file_path,
                        .command_type = .leaf,
                        .subcommands = null,
                    };

                    try commands.put(try allocator.dupe(u8, name_without_ext), command_info);
                }
            },
            .directory => {
                // Skip hidden directories
                if (entry.name[0] == '.') continue;

                // Skip invalid command names
                if (!isValidCommandName(entry.name)) {
                    logging.invalidCommandName(entry.name, "contains invalid characters or patterns");
                    continue;
                }

                // Open subdirectory
                var subdir = dir.openDir(entry.name, .{ .iterate = true }) catch {
                    logging.invalidCommandName(entry.name, "cannot access directory");
                    continue;
                };
                defer subdir.close();

                // Create subcommand map
                var subcommands = std.StringHashMap(CommandInfo).init(allocator);

                // Build new path as array of components
                var new_path_list = std.ArrayList([]const u8){};
                defer new_path_list.deinit(allocator);

                // Add current path components
                for (current_path) |component| {
                    try new_path_list.append(allocator, try allocator.dupe(u8, component));
                }
                // Add current directory name
                try new_path_list.append(allocator, try allocator.dupe(u8, entry.name));

                const new_path = try new_path_list.toOwnedSlice(allocator);

                // Recursively scan subdirectory
                try scanDirectory(allocator, subdir, &subcommands, new_path, depth + 1, max_depth);

                const has_index = hasIndexFile(subdir);

                // Only create group if it has subcommands or an index file
                if (subcommands.count() > 0 or has_index) {
                    // Build filesystem path for group - point to index.zig if it exists
                    var group_fs_path_list = std.ArrayList([]const u8){};
                    defer group_fs_path_list.deinit(allocator);
                    for (current_path) |component| {
                        try group_fs_path_list.append(allocator, component);
                    }
                    try group_fs_path_list.append(allocator, entry.name);
                    if (has_index) {
                        try group_fs_path_list.append(allocator, "index.zig");
                    }
                    const group_file_path = try std.mem.join(allocator, "/", group_fs_path_list.items);

                    // Determine command type based on presence of index.zig
                    const command_type: CommandType = if (has_index) .optional_group else .pure_group;

                    const command_info = CommandInfo{
                        .name = try allocator.dupe(u8, entry.name),
                        .path = new_path,
                        .file_path = group_file_path,
                        .command_type = command_type,
                        .subcommands = subcommands,
                    };

                    try commands.put(try allocator.dupe(u8, entry.name), command_info);
                } else {
                    // No subcommands and no index file, cleanup and skip
                    subcommands.deinit();
                    // Free path components
                    for (new_path) |component| {
                        allocator.free(component);
                    }
                    allocator.free(new_path);
                }
            },
            else => continue,
        }
    }
}

/// Check if directory has an index.zig file
fn hasIndexFile(dir: std.fs.Dir) bool {
    _ = dir.statFile("index.zig") catch return false;
    return true;
}

/// Validate command name according to security and naming rules
pub fn isValidCommandName(name: []const u8) bool {
    if (name.len == 0) return false;

    // Security checks: prevent directory traversal and other dangerous patterns
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    if (std.mem.indexOf(u8, name, "/") != null) return false;
    if (std.mem.indexOf(u8, name, "\\") != null) return false;
    if (std.mem.indexOf(u8, name, "\x00") != null) return false;

    // Basic naming rules
    const first = name[0];
    if (!std.ascii.isAlphabetic(first) and first != '_') return false;

    for (name[1..]) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_' and char != '-') return false;
    }

    // Reserved names that could conflict with system operations
    const reserved_names = [_][]const u8{
        "con",  "prn",  "aux",  "nul",
        "com1", "com2", "com3", "com4",
        "com5", "com6", "com7", "com8",
        "com9", "lpt1", "lpt2", "lpt3",
        "lpt4", "lpt5", "lpt6", "lpt7",
        "lpt8", "lpt9", ".",    "..",
    };

    for (reserved_names) |reserved| {
        if (std.ascii.eqlIgnoreCase(name, reserved)) return false;
    }

    return true;
}

// ============================================================================
// TESTS
// ============================================================================

test "isValidCommandName security checks" {
    const testing = std.testing;

    // Valid names
    try testing.expect(isValidCommandName("hello"));
    try testing.expect(isValidCommandName("user_list"));
    try testing.expect(isValidCommandName("get-data"));
    try testing.expect(isValidCommandName("cmd123"));
    try testing.expect(isValidCommandName("_private"));

    // Invalid names - security issues
    try testing.expect(!isValidCommandName("../../../etc/passwd"));
    try testing.expect(!isValidCommandName(".."));
    try testing.expect(!isValidCommandName("cmd/../other"));
    try testing.expect(!isValidCommandName("path/to/cmd"));
    try testing.expect(!isValidCommandName("cmd\\win"));
    try testing.expect(!isValidCommandName("cmd\x00"));

    // Invalid names - naming rules
    try testing.expect(!isValidCommandName(""));
    try testing.expect(!isValidCommandName("123cmd"));
    try testing.expect(!isValidCommandName("cmd!"));
    try testing.expect(!isValidCommandName("cmd@"));
    try testing.expect(!isValidCommandName("cmd#"));

    // Reserved names
    try testing.expect(!isValidCommandName("con"));
    try testing.expect(!isValidCommandName("PRN"));
    try testing.expect(!isValidCommandName("aux"));
    try testing.expect(!isValidCommandName("COM1"));
    try testing.expect(!isValidCommandName("lpt9"));
}
