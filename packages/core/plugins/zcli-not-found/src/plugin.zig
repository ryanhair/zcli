const std = @import("std");
const zcli = @import("zcli");
const levenshtein = @import("levenshtein.zig");

/// zcli-not-found Plugin
///
/// Handles command-not-found errors with intelligent "did you mean" suggestions
/// using Levenshtein distance algorithm to find similar commands.
/// Error hook - handles command not found errors with suggestions
pub fn onError(
    context: *zcli.Context,
    err: anyerror,
) !bool {
    if (err == error.CommandNotFound) {
        // Get available commands directly from context
        const attempted_command = if (context.command_path.len > 0) context.command_path[0] else "unknown";
        try generateCommandNotFoundHelp(context, attempted_command, context.available_commands);

        // We've shown helpful suggestions, but let the error continue to propagate
        // This allows other plugins or the default handler to also respond if needed
        return false;
    }

    return false; // Error not handled
}

/// Generate help text for command not found errors
fn generateCommandNotFoundHelp(
    context: *zcli.Context,
    attempted_command: []const u8,
    available_commands: []const []const []const u8,
) !void {
    const writer = context.stderr();

    // Error header
    try writer.print("Error: Unknown command '{s}'\n\n", .{attempted_command});

    // Safety check for available_commands
    if (available_commands.len == 0) {
        try writer.print("No commands available for suggestions.\n", .{});
        try writer.print("\nRun '{s} --help' to see all available commands.\n", .{context.app_name});
        return;
    }

    // Convert hierarchical commands to flat strings for suggestion processing
    var flat_commands = std.ArrayList([]const u8).init(context.allocator);
    defer {
        for (flat_commands.items) |cmd| {
            context.allocator.free(cmd);
        }
        flat_commands.deinit();
    }

    for (available_commands) |cmd_parts| {
        const joined_cmd = try std.mem.join(context.allocator, " ", cmd_parts);
        try flat_commands.append(joined_cmd);
    }

    // Find similar commands
    const suggestions = findBestSuggestions(
        attempted_command,
        flat_commands.items,
        context.allocator,
        3, // max suggestions
        3, // max edit distance
    ) catch null;

    if (suggestions) |suggs| {
        defer context.allocator.free(suggs);

        if (suggs.len > 0) {
            if (suggs.len == 1) {
                try writer.print("Did you mean '{s}'?\n\n", .{suggs[0]});
            } else {
                try writer.print("Did you mean one of these?\n", .{});
                for (suggs) |suggestion| {
                    try writer.print("    {s}\n", .{suggestion});
                }
                try writer.print("\n", .{});
            }
        }
    }

    // Show available commands
    try writer.print("Available commands:\n", .{});
    for (flat_commands.items) |cmd| {
        try writer.print("    {s}\n", .{cmd});
    }

    try writer.print("\nRun '{s} --help' to see all available commands.\n", .{context.app_name});
}

/// Find best command suggestions using Levenshtein distance
fn findBestSuggestions(
    input: []const u8,
    commands: []const []const u8,
    allocator: std.mem.Allocator,
    max_suggestions: usize,
    max_distance: usize,
) ![][]const u8 {
    // Safety checks
    if (commands.len == 0 or input.len == 0) {
        return allocator.alloc([]const u8, 0);
    }

    // Structure to hold command and its distance
    const ScoredCommand = struct {
        command: []const u8,
        distance: usize,

        fn lessThan(_: void, a: @This(), b: @This()) bool {
            return a.distance < b.distance;
        }
    };

    var scored = try allocator.alloc(ScoredCommand, commands.len);
    defer allocator.free(scored);

    var valid_count: usize = 0;

    // Calculate distances for all commands
    for (commands) |cmd| {
        // Safety check for each command
        if (cmd.len == 0) continue;

        const distance = levenshtein.editDistance(input, cmd);
        if (distance <= max_distance) {
            scored[valid_count] = .{
                .command = cmd,
                .distance = distance,
            };
            valid_count += 1;
        }
    }

    if (valid_count == 0) {
        return allocator.alloc([]const u8, 0);
    }

    // Sort by distance
    std.sort.pdq(ScoredCommand, scored[0..valid_count], {}, ScoredCommand.lessThan);

    // Return top suggestions
    const result_count = @min(valid_count, max_suggestions);
    var result = try allocator.alloc([]const u8, result_count);

    for (0..result_count) |i| {
        result[i] = scored[i].command;
    }

    return result;
}

// Context extension - stores configuration for suggestions
pub const ContextExtension = struct {
    max_suggestions: usize = 3,
    max_distance: usize = 3,
    color_output: bool = true,
    command_list: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) !@This() {
        return .{
            .max_suggestions = 3,
            .max_distance = 3,
            .color_output = std.io.tty.detectConfig(std.io.getStdErr()) != .no_color,
            .command_list = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.command_list.deinit();
    }

    pub fn addCommand(self: *@This(), command: []const u8) !void {
        try self.command_list.append(command);
    }
};

// Tests
test "not-found plugin structure" {
    try std.testing.expect(@hasDecl(@This(), "onError"));
    try std.testing.expect(@hasDecl(@This(), "ContextExtension"));
}

test "onError handles CommandNotFound" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a temporary file to capture stderr output
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var output_file = try tmp_dir.dir.createFile("test_output.txt", .{ .read = true });
    defer output_file.close();

    // Create context with the temporary file as stderr
    var context = zcli.Context{
        .allocator = allocator,
        .io = .{
            .stdout = std.io.getStdOut().writer(),
            .stderr = output_file.writer(),
            .stdin = std.io.getStdIn().reader(),
        },
        .environment = zcli.Environment.init(),
        .plugin_extensions = zcli.ContextExtensions.init(allocator),
    };
    defer context.deinit();

    // Store available commands in context
    const commands = [_][]const u8{ "list", "search", "create" };
    try context.setGlobalData("available_commands", @ptrCast(&commands));

    // Test command not found error - should not return error, just print suggestions
    const handled = try onError(&context, error.CommandNotFound);
    _ = handled;

    // Read back the captured output
    try output_file.seekTo(0);
    const captured_output = try output_file.readToEndAlloc(allocator, 4096);
    defer allocator.free(captured_output);

    // Validate the captured output
    try std.testing.expect(captured_output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, captured_output, "Error: Unknown command") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured_output, "Run 'app --help'") != null);
}

test "find best suggestions" {
    const allocator = std.testing.allocator;

    const commands = [_][]const u8{ "list", "search", "create", "delete", "status" };

    // Test with typo "serach" -> should suggest "search"
    const suggestions = try findBestSuggestions("serach", &commands, allocator, 3, 3);
    defer allocator.free(suggestions);

    try std.testing.expect(suggestions.len > 0);
    try std.testing.expectEqualStrings("search", suggestions[0]);
}

test "find best suggestions with empty input" {
    const allocator = std.testing.allocator;

    const commands = [_][]const u8{ "list", "search", "create" };

    // Test with empty input
    const suggestions = try findBestSuggestions("", &commands, allocator, 3, 3);
    defer allocator.free(suggestions);

    try std.testing.expect(suggestions.len == 0);
}

test "find best suggestions with no commands" {
    const allocator = std.testing.allocator;

    const commands = [_][]const u8{};

    // Test with no available commands
    const suggestions = try findBestSuggestions("test", &commands, allocator, 3, 3);
    defer allocator.free(suggestions);

    try std.testing.expect(suggestions.len == 0);
}
