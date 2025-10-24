const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Add a new command to your zcli project",
    .examples = &.{
        "add command deploy",
        "add command users/create",
        "add command deploy --description \"Deploy your app\"",
    },
    .args = .{
        .path = "Command path (e.g., 'deploy' or 'users/create')",
    },
    .options = .{
        .description = .{ .description = "Description of the command", .short = 'd' },
    },
};

pub const Args = struct {
    path: []const u8,
};

pub const Options = struct {
    description: ?[]const u8 = null,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    const allocator = context.allocator;
    var stdout = context.stdout();
    var stderr = context.stderr();

    const command_path = args.path;
    const description = options.description orelse "TODO: Add description";

    // Parse the command path
    var path_parts = std.ArrayList([]const u8){};
    defer path_parts.deinit(allocator);

    var iter = std.mem.splitScalar(u8, command_path, '/');
    while (iter.next()) |part| {
        if (part.len > 0) {
            try path_parts.append(allocator, part);
        }
    }

    if (path_parts.items.len == 0) {
        try stderr.print("Error: Invalid command path: '{s}'\n", .{command_path});
        return error.InvalidCommandPath;
    }

    // Verify we're in a zcli project (check for src/commands directory)
    const cwd = std.fs.cwd();
    cwd.access("src/commands", .{}) catch {
        try stderr.print("Error: Not in a zcli project directory\n", .{});
        try stderr.print("Run this command from the root of your zcli project (where build.zig is)\n", .{});
        return error.NotInZcliProject;
    };

    // Build the file path
    var file_path = std.ArrayList(u8){};
    defer file_path.deinit(allocator);

    try file_path.appendSlice(allocator, "src/commands");

    // Create intermediate directories if needed
    var current_path = std.ArrayList(u8){};
    defer current_path.deinit(allocator);
    try current_path.appendSlice(allocator, "src/commands");

    if (path_parts.items.len > 1) {
        for (path_parts.items[0 .. path_parts.items.len - 1]) |dir| {
            try file_path.append(allocator, '/');
            try file_path.appendSlice(allocator, dir);

            try current_path.append(allocator, '/');
            try current_path.appendSlice(allocator, dir);

            // Create directory if it doesn't exist
            cwd.makeDir(current_path.items) catch |err| switch (err) {
                error.PathAlreadyExists => {}, // OK
                else => return err,
            };
        }
    }

    // Add the final command file
    const command_name = path_parts.items[path_parts.items.len - 1];
    try file_path.append(allocator, '/');
    try file_path.appendSlice(allocator, command_name);
    try file_path.appendSlice(allocator, ".zig");

    // Check if file already exists
    cwd.access(file_path.items, .{}) catch |err| switch (err) {
        error.FileNotFound => {}, // Good, file doesn't exist
        else => {
            try stderr.print("Error: Command already exists: {s}\n", .{file_path.items});
            return err;
        },
    };

    // Generate command content
    try stdout.print("Creating command: {s}\n", .{command_path});

    const command_content = try std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\const zcli = @import("zcli");
        \\
        \\pub const meta = .{{
        \\    .description = "{s}",
        \\    .examples = &.{{
        \\        "{s}",
        \\    }},
        \\}};
        \\
        \\pub const Args = struct {{
        \\    // TODO: Add your positional arguments here
        \\    // Example:
        \\    // name: []const u8,
        \\}};
        \\
        \\pub const Options = struct {{
        \\    // TODO: Add your options here
        \\    // Example:
        \\    // verbose: bool = false,
        \\}};
        \\
        \\pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {{
        \\    _ = args;
        \\    _ = options;
        \\
        \\    const stdout = context.stdout();
        \\
        \\    try stdout.print("TODO: Implement this command\n", .{{}});
        \\}}
        \\
    , .{ description, command_path });
    defer allocator.free(command_content);

    var command_file = try cwd.createFile(file_path.items, .{});
    defer command_file.close();
    try command_file.writeAll(command_content);

    try stdout.print("✓ Created {s}\n\n", .{file_path.items});
    try stdout.print("Next steps:\n", .{});
    try stdout.print("  1. Edit {s} to implement your command\n", .{file_path.items});
    try stdout.print("  2. Run: zig build\n", .{});
    try stdout.print("  3. Try: ./zig-out/bin/<app> {s} --help\n", .{command_path});
}
