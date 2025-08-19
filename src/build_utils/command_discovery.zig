const std = @import("std");
const logging = @import("../logging.zig");
const types = @import("types.zig");

const CommandInfo = types.CommandInfo;
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
    try scanDirectory(allocator, dir, &commands.root, "", 0, max_depth);
    
    return commands;
}

/// Recursively scan a directory for commands
fn scanDirectory(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    commands: *std.StringHashMap(CommandInfo),
    current_path: []const u8,
    depth: u32,
    max_depth: u32,
) !void {
    // Prevent excessive nesting
    if (depth >= max_depth) {
        logging.maxNestingDepthReached(max_depth, current_path);
        return;
    }
    var iterator = dir.iterate();
    
    while (try iterator.next()) |entry| {
        switch (entry.kind) {
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".zig")) {
                    const name_without_ext = entry.name[0 .. entry.name.len - 4];
                    
                    // Skip invalid command names
                    if (!isValidCommandName(name_without_ext)) {
                        logging.invalidCommandName(name_without_ext, "contains invalid characters or patterns");
                        continue;
                    }
                    
                    const full_path = if (current_path.len == 0) 
                        try allocator.dupe(u8, entry.name)
                    else 
                        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current_path, entry.name });
                    
                    const command_info = CommandInfo{
                        .name = try allocator.dupe(u8, name_without_ext),
                        .path = full_path,
                        .is_group = false,
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
                
                const new_path = if (current_path.len == 0) 
                    try allocator.dupe(u8, entry.name)
                else 
                    try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current_path, entry.name });
                
                // Recursively scan subdirectory
                try scanDirectory(allocator, subdir, &subcommands, new_path, depth + 1, max_depth);
                
                // Only create group if it has subcommands or an index file
                if (subcommands.count() > 0 or hasIndexFile(subdir)) {
                    const command_info = CommandInfo{
                        .name = try allocator.dupe(u8, entry.name),
                        .path = new_path,
                        .is_group = true,
                        .subcommands = subcommands,
                    };
                    
                    try commands.put(try allocator.dupe(u8, entry.name), command_info);
                } else {
                    // No subcommands and no index file, cleanup and skip
                    subcommands.deinit();
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
        "con", "prn", "aux", "nul",
        "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
        "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
        ".", "..",
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