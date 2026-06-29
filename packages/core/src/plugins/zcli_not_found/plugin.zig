const std = @import("std");
const zcli = @import("zcli");
const levenshtein = @import("levenshtein.zig");

/// zcli-not-found Plugin
///
/// Handles command-not-found errors with intelligent "did you mean" suggestions
/// using Levenshtein distance algorithm to find similar commands.
/// Error hook - handles command not found errors with suggestions
pub fn onError(
    context: anytype,
    err: anyerror,
) !bool {
    if (err == error.CommandNotFound) {
        // Get available commands and filter out hidden ones
        const all_command_info = context.getAvailableCommandInfo();
        var visible_commands = std.ArrayList([]const []const u8){};
        defer visible_commands.deinit(context.allocator);

        for (all_command_info) |cmd_info| {
            if (!cmd_info.hidden) {
                try visible_commands.append(context.allocator, cmd_info.path);
            }
        }

        const attempted_command = if (context.command_path.len > 0)
            try std.mem.join(context.allocator, " ", context.command_path)
        else
            try context.allocator.dupe(u8, "unknown");
        defer context.allocator.free(attempted_command);
        try generateCommandNotFoundHelp(context, attempted_command, visible_commands.items);

        // We've shown helpful suggestions, but let the error continue to propagate
        // This allows other plugins or the default handler to also respond if needed
        return false;
    }

    return false; // Error not handled
}

/// Generate help text for command not found errors
fn generateCommandNotFoundHelp(
    context: anytype,
    attempted_command: []const u8,
    available_commands: []const []const []const u8,
) !void {
    var writer = context.stderr();

    // Error header
    try writer.print("Error: Unknown command '{s}'\n\n", .{attempted_command});

    // Safety check for available_commands
    if (available_commands.len == 0) {
        try writer.print("No commands available for suggestions.\n", .{});
        try writer.print("\nRun '{s} --help' to see all available commands.\n", .{context.app_name});
        return;
    }

    // Convert hierarchical commands to flat strings for suggestion processing
    var flat_commands = std.ArrayList([]const u8){};
    defer {
        for (flat_commands.items) |cmd| {
            context.allocator.free(cmd);
        }
        flat_commands.deinit(context.allocator);
    }

    for (available_commands) |cmd_parts| {
        const joined_cmd = try std.mem.join(context.allocator, " ", cmd_parts);
        try flat_commands.append(context.allocator, joined_cmd);
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

// Tests
test "not-found plugin structure" {
    try std.testing.expect(@hasDecl(@This(), "onError"));
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
