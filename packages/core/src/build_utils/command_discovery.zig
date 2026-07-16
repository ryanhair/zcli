const std = @import("std");
const logging = @import("../logging.zig");
const types = @import("discovery_types.zig");

// Re-exported so runtime consumers (e.g. the `zcli tree` tool) can name the
// types returned by discovery. discovery_types.zig is runtime-safe — the
// std.Build-only build_utils/types.zig never enters the runtime module graph.
pub const DiscoveredCommand = types.DiscoveredCommand;
pub const CommandType = types.CommandType;
pub const DiscoveredCommands = types.DiscoveredCommands;

/// Reasonable maximum nesting depth.
const default_max_depth = 6;

// ============================================================================
// COMMAND DISCOVERY - Filesystem scanning and command structure analysis
// ============================================================================

/// Discover commands by scanning an already-open directory. This is the shared
/// core used by both the build (via discoverCommands) and runtime tooling such
/// as `zcli tree`, so the two never drift. `dir` must be opened with iteration.
pub fn discoverInDir(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !DiscoveredCommands {
    var commands = DiscoveredCommands.init(allocator);
    errdefer commands.deinit();

    try scanDirectory(allocator, io, dir, &commands.root, &.{}, 0, default_max_depth);

    return commands;
}

/// Build-time command discovery - opens commands_dir under the build root and scans it.
pub fn discoverCommands(b: *std.Build, commands_dir: []const u8) !DiscoveredCommands {
    // Security check: prevent directory traversal
    if (std.mem.indexOf(u8, commands_dir, "..") != null) {
        return error.InvalidPath;
    }

    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, commands_dir, .{ .iterate = true }) catch |err| {
        return err;
    };
    defer dir.close(io);

    return discoverInDir(b.allocator, io, dir);
}

/// Recursively scan a directory for commands
fn scanDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    commands: *std.StringHashMap(DiscoveredCommand),
    current_path: []const []const u8, // Array of path components
    depth: u32,
    max_depth: u32,
) !void {
    // Prevent excessive nesting. Exceeding the cap is a hard error rather
    // than a silent truncation: the old behavior logged one build-log line
    // and made the whole subtree vanish from the CLI, which is trivial to
    // miss. The cap also doubles as a symlink-loop guard now that symlinked
    // directories are followed (see below).
    if (depth >= max_depth) {
        // Convert path array to string for logging. On OOM log without the
        // path — the old `catch "unknown"` fallback flowed into the free
        // below, which is UB on a string literal.
        const joined: ?[]u8 = if (current_path.len == 0) null else std.mem.join(allocator, "/", current_path) catch null;
        defer if (joined) |p| allocator.free(p);
        logging.maxNestingDepthExceeded(max_depth, joined orelse "");
        return error.MaxCommandDepthExceeded;
    }
    var iterator = dir.iterate();

    while (try iterator.next(io)) |entry| {
        // Resolve symlinks to their target kind so symlinked command files
        // and directories are discovered exactly like real ones — a monorepo
        // may symlink a shared command tree into commands/. Without this the
        // .sym_link entry fell through to the `else` arm and was silently
        // dropped. statFile follows symlinks, so its reported kind is the
        // target's; openDir/statFile below likewise follow the link.
        const kind = switch (entry.kind) {
            .sym_link => blk: {
                const stat = dir.statFile(io, entry.name, .{}) catch {
                    logging.invalidCommandName(entry.name, "cannot resolve symlink target");
                    continue;
                };
                break :blk stat.kind;
            },
            else => entry.kind,
        };

        switch (kind) {
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".zig")) {
                    const name_without_ext = entry.name[0 .. entry.name.len - 4];

                    // Skip index.zig files - they are handled as group defaults
                    if (std.mem.eql(u8, name_without_ext, "index")) {
                        continue;
                    }

                    // Underscore-prefixed files are helpers a command file
                    // imports (e.g. `_wizard.zig`), not commands.
                    if (entry.name[0] == '_') continue;

                    // Skip invalid command names
                    if (!isValidCommandName(name_without_ext)) {
                        logging.invalidCommandName(name_without_ext, "contains invalid characters or patterns");
                        continue;
                    }

                    // Build command path as array of components
                    var path_list = std.ArrayList([]const u8).empty;
                    defer path_list.deinit(allocator);

                    // Add current path components
                    for (current_path) |component| {
                        try path_list.append(allocator, try allocator.dupe(u8, component));
                    }
                    // Add current command name
                    try path_list.append(allocator, try allocator.dupe(u8, name_without_ext));

                    // Build filesystem path
                    var fs_path_list = std.ArrayList([]const u8).empty;
                    defer fs_path_list.deinit(allocator);
                    for (current_path) |component| {
                        try fs_path_list.append(allocator, component);
                    }
                    try fs_path_list.append(allocator, entry.name);
                    const file_path = try std.mem.join(allocator, "/", fs_path_list.items);

                    const command_info = DiscoveredCommand{
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
                // Skip hidden directories, and underscore-prefixed helper
                // directories (same convention as `_helper.zig` files).
                if (entry.name[0] == '.' or entry.name[0] == '_') continue;

                // Skip invalid command names
                if (!isValidCommandName(entry.name)) {
                    logging.invalidCommandName(entry.name, "contains invalid characters or patterns");
                    continue;
                }

                // Open subdirectory
                var subdir = dir.openDir(io, entry.name, .{ .iterate = true }) catch {
                    logging.invalidCommandName(entry.name, "cannot access directory");
                    continue;
                };
                defer subdir.close(io);

                // Create subcommand map
                var subcommands = std.StringHashMap(DiscoveredCommand).init(allocator);

                // Build new path as array of components
                var new_path_list = std.ArrayList([]const u8).empty;
                defer new_path_list.deinit(allocator);

                // Add current path components
                for (current_path) |component| {
                    try new_path_list.append(allocator, try allocator.dupe(u8, component));
                }
                // Add current directory name
                try new_path_list.append(allocator, try allocator.dupe(u8, entry.name));

                const new_path = try new_path_list.toOwnedSlice(allocator);

                // Recursively scan subdirectory
                try scanDirectory(allocator, io, subdir, &subcommands, new_path, depth + 1, max_depth);

                const has_index = hasIndexFile(io, subdir);

                // Only create group if it has subcommands or an index file
                if (subcommands.count() > 0 or has_index) {
                    // Build filesystem path for group - point to index.zig if it exists
                    var group_fs_path_list = std.ArrayList([]const u8).empty;
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

                    const command_info = DiscoveredCommand{
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
fn hasIndexFile(io: std.Io, dir: std.Io.Dir) bool {
    _ = dir.statFile(io, "index.zig", .{}) catch return false;
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

test "discovery skips underscore-prefixed helper files and directories" {
    const testing = std.testing;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // deploy.zig is a command; _generate.zig is a helper it imports; _helpers/
    // holds more helpers. Only the command may be discovered — helper files
    // becoming commands is exactly how a split command file would leak
    // `myapp add _wizard` into the CLI.
    try tmp.dir.writeFile(io, .{ .sub_path = "deploy.zig", .data = "pub fn execute() void {}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "_generate.zig", .data = "pub fn helper() void {}" });
    try tmp.dir.createDir(io, "_helpers", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "_helpers/render.zig", .data = "pub fn helper() void {}" });

    var dir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);

    var commands = try discoverInDir(testing.allocator, io, dir);
    defer commands.deinit();

    try testing.expectEqual(@as(usize, 1), commands.root.count());
    try testing.expect(commands.root.get("deploy") != null);
    try testing.expect(commands.root.get("_generate") == null);
    try testing.expect(commands.root.get("_helpers") == null);
}

test "discovery follows symlinked command files and directories" {
    const testing = std.testing;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A real command, plus a shared command file and a shared command
    // directory that a monorepo symlinks into commands/. All must be
    // discovered — previously the symlink entries fell through to the
    // `else => continue` arm and vanished from the CLI with no warning.
    try tmp.dir.writeFile(io, .{ .sub_path = "deploy.zig", .data = "pub fn execute() void {}" });

    try tmp.dir.createDir(io, "shared_src", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "shared_src/status.zig", .data = "pub fn execute() void {}" });
    try tmp.dir.createDir(io, "shared_group_src", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "shared_group_src/list.zig", .data = "pub fn execute() void {}" });

    // status.zig symlinks a shared command file; group/ symlinks a shared dir.
    try tmp.dir.symLink(io, "shared_src/status.zig", "status.zig", .{});
    try tmp.dir.symLink(io, "shared_group_src", "group", .{ .is_directory = true });

    var dir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);

    var commands = try discoverInDir(testing.allocator, io, dir);
    defer commands.deinit();

    try testing.expect(commands.root.get("deploy") != null);
    // The symlinked file resolves to a leaf command.
    try testing.expect(commands.root.get("status") != null);
    // The symlinked directory resolves to a group whose subcommand is found.
    const group = commands.root.get("group") orelse return error.TestUnexpectedResult;
    try testing.expect(group.subcommands != null);
    try testing.expect(group.subcommands.?.get("list") != null);
}

test "discovery errors loudly when nesting exceeds the depth cap" {
    const testing = std.testing;
    const io = testing.io;

    // Deliberately hitting the hard-error path leaks the partial subtree
    // allocations (fine in production: b.allocator is an arena and the build
    // aborts). Use an arena here so the leak detector doesn't flag it.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "group", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "group/leaf.zig", .data = "pub fn execute() void {}" });

    var dir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);

    var commands = std.StringHashMap(DiscoveredCommand).init(allocator);

    // max_depth = 1: recursing into group/ reaches the cap. This must be a
    // hard error, not a silent drop that would hide `group leaf` from the CLI.
    try testing.expectError(
        error.MaxCommandDepthExceeded,
        scanDirectory(allocator, io, dir, &commands, &.{}, 0, 1),
    );
}

test "sortedByName yields alphabetical order regardless of discovery order" {
    const testing = std.testing;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Names chosen so filesystem/hash order is unlikely to be alphabetical.
    try tmp.dir.writeFile(io, .{ .sub_path = "zebra.zig", .data = "pub fn execute() void {}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "apple.zig", .data = "pub fn execute() void {}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mango.zig", .data = "pub fn execute() void {}" });

    var dir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);

    var commands = try discoverInDir(testing.allocator, io, dir);
    defer commands.deinit();

    const sorted = try types.sortedByName(testing.allocator, &commands.root);
    defer testing.allocator.free(sorted);

    try testing.expectEqual(@as(usize, 3), sorted.len);
    try testing.expectEqualStrings("apple", sorted[0].name);
    try testing.expectEqualStrings("mango", sorted[1].name);
    try testing.expectEqualStrings("zebra", sorted[2].name);
}

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
