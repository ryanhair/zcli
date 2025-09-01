const std = @import("std");
const logging = @import("logging.zig");

pub fn handleCommandNotFound(
    writer: anytype,
    command: []const u8,
    available_commands: []const []const u8,
    app_name: []const u8,
    allocator: std.mem.Allocator,
) !void {
    _ = allocator; // Unused since suggestions moved to plugin
    try writer.print("Error: Unknown command '{s}'\n\n", .{command});

    // Suggestions are now handled by the zcli-suggestions plugin

    try writer.print("Available commands:\n", .{});
    for (available_commands) |cmd| {
        try writer.print("    {s}\n", .{cmd});
    }
    try writer.print("\n", .{});

    try writer.print("Run '{s} --help' to see all available commands.\n", .{app_name});
}

pub fn handleSubcommandNotFound(
    writer: anytype,
    parent_command: []const u8,
    subcommand: []const u8,
    available_subcommands: []const []const u8,
    app_name: []const u8,
    allocator: std.mem.Allocator,
) !void {
    _ = allocator; // Unused since suggestions moved to plugin
    try writer.print("Error: Unknown subcommand '{s}' for '{s}'\n\n", .{ subcommand, parent_command });

    // Suggestions are now handled by the zcli-suggestions plugin

    try writer.print("Available subcommands for '{s}':\n", .{parent_command});
    for (available_subcommands) |cmd| {
        try writer.print("    {s}\n", .{cmd});
    }
    try writer.print("\n", .{});

    try writer.print("Run '{s} {s} --help' for more information.\n", .{ app_name, parent_command });
}

/// Handle missing required argument error
pub fn handleMissingArgument(
    writer: anytype,
    command_path: []const []const u8,
    missing_arg: []const u8,
    position: usize,
    app_name: []const u8,
) !void {
    try writer.print("Error: Missing required argument '{s}' (argument {})\n\n", .{ missing_arg, position + 1 });

    try writer.print("USAGE:\n", .{});
    try writer.print("    {s}", .{app_name});
    for (command_path) |part| {
        try writer.print(" {s}", .{part});
    }
    try writer.print(" <{s}> ...\n\n", .{missing_arg});

    try writer.print("Run '{s}", .{app_name});
    for (command_path) |part| {
        try writer.print(" {s}", .{part});
    }
    try writer.print(" --help' for more information.\n", .{});
}

/// Handle too many arguments error
pub fn handleTooManyArguments(
    writer: anytype,
    command_path: []const []const u8,
    expected: usize,
    provided: usize,
    app_name: []const u8,
) !void {
    try writer.print("Error: Too many arguments provided. Expected {}, got {}\n\n", .{ expected, provided });

    try writer.print("Run '{s}", .{app_name});
    for (command_path) |part| {
        try writer.print(" {s}", .{part});
    }
    try writer.print(" --help' for more information.\n", .{});
}

/// Handle unknown option error
pub fn handleUnknownOption(
    writer: anytype,
    option: []const u8,
    available_options: []const []const u8,
    command_path: []const []const u8,
    app_name: []const u8,
    allocator: std.mem.Allocator,
) !void {
    _ = allocator; // Unused since suggestions moved to plugin
    try writer.print("Error: Unknown option '{s}'\n\n", .{option});

    // Suggestions are now handled by the zcli-suggestions plugin

    if (available_options.len > 0) {
        try writer.print("Available options:\n", .{});
        for (available_options) |opt| {
            try writer.print("    --{s}\n", .{opt});
        }
        try writer.print("\n", .{});
    }

    try writer.print("Run '{s}", .{app_name});
    for (command_path) |part| {
        try writer.print(" {s}", .{part});
    }
    try writer.print(" --help' to see available options.\n", .{});
}

/// Handle invalid option value error
pub fn handleInvalidOptionValue(
    writer: anytype,
    option: []const u8,
    value: []const u8,
    expected_type: []const u8,
    command_path: []const []const u8,
    app_name: []const u8,
) !void {
    try writer.print("Error: Invalid value '{s}' for option '--{s}'\n", .{ value, option });
    try writer.print("Expected: {s}\n\n", .{expected_type});

    try writer.print("Run '{s}", .{app_name});
    for (command_path) |part| {
        try writer.print(" {s}", .{part});
    }
    try writer.print(" --help' for more information.\n", .{});
}

/// Handle missing option value error
pub fn handleMissingOptionValue(
    writer: anytype,
    option: []const u8,
    command_path: []const []const u8,
    app_name: []const u8,
) !void {
    try writer.print("Error: Option '--{s}' requires a value\n\n", .{option});

    try writer.print("Run '{s}", .{app_name});
    for (command_path) |part| {
        try writer.print(" {s}", .{part});
    }
    try writer.print(" --help' for more information.\n", .{});
}

/// Find commands similar to the input using edit distance
pub fn findSimilarCommands(input: []const u8, candidates: []const []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    var suggestions = std.ArrayList([]const u8).init(allocator);
    defer suggestions.deinit();

    for (candidates) |candidate| {
        const distance = editDistance(input, candidate);

        // Only suggest if the edit distance is reasonable
        if (distance <= 3 and distance < input.len) {
            try suggestions.append(candidate);
        }
    }

    return suggestions.toOwnedSlice();
}

/// Calculate Levenshtein edit distance between two strings
/// Made public for testing purposes
pub fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;

    // Create a matrix to store distances
    var matrix: [64][64]usize = undefined;

    // Handle case where strings are too long
    const max_len = 62; // Changed from 63 to avoid overflow with +1
    const a_len = @min(a.len, max_len);
    const b_len = @min(b.len, max_len);

    // Initialize first row and column
    for (0..a_len + 1) |i| {
        matrix[i][0] = i;
    }
    for (0..b_len + 1) |j| {
        matrix[0][j] = j;
    }

    // Fill the matrix
    for (1..a_len + 1) |i| {
        for (1..b_len + 1) |j| {
            const cost: usize = if (a[i - 1] == b[j - 1]) 0 else 1;

            matrix[i][j] = @min(
                @min(
                    matrix[i - 1][j] + 1, // deletion
                    matrix[i][j - 1] + 1, // insertion
                ),
                matrix[i - 1][j - 1] + cost, // substitution
            );
        }
    }

    return matrix[a_len][b_len];
}

// Tests
test "editDistance basic" {
    try std.testing.expectEqual(@as(usize, 0), editDistance("hello", "hello"));
    try std.testing.expectEqual(@as(usize, 1), editDistance("hello", "helo"));
    try std.testing.expectEqual(@as(usize, 1), editDistance("hello", "helloo"));
    try std.testing.expectEqual(@as(usize, 2), editDistance("hello", "bell"));
    try std.testing.expectEqual(@as(usize, 4), editDistance("hello", "world"));
}

test "findSimilarCommands" {
    const commands = [_][]const u8{ "list", "search", "create", "delete", "status" };

    const suggestions = findSimilarCommands("serach", &commands, std.testing.allocator) catch &[_][]const u8{};
    defer if (suggestions.len > 0) std.testing.allocator.free(suggestions);
    try std.testing.expect(suggestions.len > 0);
    try std.testing.expectEqualStrings("search", suggestions[0]);
}

test "handleCommandNotFound" {
    const commands = [_][]const u8{ "list", "search", "create" };

    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try handleCommandNotFound(stream.writer(), "serach", &commands, "myapp", std.testing.allocator);

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Unknown command 'serach'") != null);
    // Suggestion tests moved to zcli-suggestions plugin
}

test "handleSubcommandNotFound" {
    const subcommands = [_][]const u8{ "add", "remove", "list" };

    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try handleSubcommandNotFound(stream.writer(), "users", "lst", &subcommands, "myapp", std.testing.allocator);

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Unknown subcommand 'lst' for 'users'") != null);
    // Suggestion tests moved to zcli-suggestions plugin
    try std.testing.expect(std.mem.indexOf(u8, output, "myapp users --help") != null);
}

test "handleMissingArgument" {
    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const command_path = [_][]const u8{ "users", "create" };
    try handleMissingArgument(stream.writer(), &command_path, "username", 0, "myapp");

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Missing required argument 'username' (argument 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "myapp users create <username>") != null);
}

test "handleTooManyArguments" {
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const command_path = [_][]const u8{"status"};
    try handleTooManyArguments(stream.writer(), &command_path, 0, 2, "myapp");

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Too many arguments provided. Expected 0, got 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "myapp status --help") != null);
}

test "handleUnknownOption" {
    const available_options = [_][]const u8{ "verbose", "output", "format" };

    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const allocator = std.testing.allocator;

    const command_path = [_][]const u8{"convert"};
    try handleUnknownOption(stream.writer(), "--outpt", &available_options, &command_path, "myapp", allocator);

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Unknown option '--outpt'") != null);
    // Suggestion tests moved to zcli-suggestions plugin
}

test "handleInvalidOptionValue" {
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const command_path = [_][]const u8{ "server", "start" };
    try handleInvalidOptionValue(stream.writer(), "port", "abc", "integer", &command_path, "myapp");

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Invalid value 'abc' for option '--port'") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Expected: integer") != null);
}

test "handleMissingOptionValue" {
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const command_path = [_][]const u8{"build"};
    try handleMissingOptionValue(stream.writer(), "output", &command_path, "myapp");

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Option '--output' requires a value") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "myapp build --help") != null);
}

test "editDistance edge cases" {
    // Test empty strings
    try std.testing.expectEqual(@as(usize, 5), editDistance("", "hello"));
    try std.testing.expectEqual(@as(usize, 5), editDistance("hello", ""));
    try std.testing.expectEqual(@as(usize, 0), editDistance("", ""));

    // Test single character differences
    try std.testing.expectEqual(@as(usize, 1), editDistance("a", "b"));
    try std.testing.expectEqual(@as(usize, 1), editDistance("cat", "cut"));
    try std.testing.expectEqual(@as(usize, 1), editDistance("saturday", "saturdays"));

    // Test completely different strings
    try std.testing.expectEqual(@as(usize, 3), editDistance("abc", "xyz"));

    // Test case sensitivity
    try std.testing.expectEqual(@as(usize, 1), editDistance("Hello", "hello"));

    // Test very long strings (should be capped at 62 chars)
    const long1 = "a" ** 70; // Still longer than 62 to test capping
    const long2 = "b" ** 70;
    const dist = editDistance(long1, long2);
    try std.testing.expect(dist <= 62);
}

test "findSimilarCommands edge cases" {
    // Test with no candidates
    {
        const commands = [_][]const u8{};
        const suggestions = findSimilarCommands("test", &commands, std.testing.allocator) catch &[_][]const u8{};
        try std.testing.expectEqual(@as(usize, 0), suggestions.len);
    }

    // Test with exact match
    {
        const commands = [_][]const u8{ "test", "testing", "tests" };
        const suggestions = findSimilarCommands("test", &commands, std.testing.allocator) catch &[_][]const u8{};
        defer if (suggestions.len > 0) std.testing.allocator.free(suggestions);
        // Should find exact match plus similar ones
        try std.testing.expect(suggestions.len >= 1);
        // First result should be exact match
        try std.testing.expectEqualStrings("test", suggestions[0]);
    }

    // Test with multiple similar commands
    {
        const commands = [_][]const u8{ "list", "lint", "link", "last", "lost" };
        const suggestions = findSimilarCommands("lst", &commands, std.testing.allocator) catch &[_][]const u8{};
        defer if (suggestions.len > 0) std.testing.allocator.free(suggestions);
        try std.testing.expect(suggestions.len >= 2);
    }

    // Test distance threshold
    {
        const commands = [_][]const u8{"completely-different"};
        const suggestions = findSimilarCommands("test", &commands, std.testing.allocator) catch &[_][]const u8{};
        defer if (suggestions.len > 0) std.testing.allocator.free(suggestions);
        try std.testing.expectEqual(@as(usize, 0), suggestions.len);
    }
}

test "error handler formatting" {
    // Test that error messages don't exceed reasonable lengths
    var buffer: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const very_long_command = "very-long-command-name-that-might-wrap";
    const commands = [_][]const u8{very_long_command};

    try handleCommandNotFound(stream.writer(), "test", &commands, "myapp", std.testing.allocator);

    const output = stream.getWritten();
    try std.testing.expect(output.len < 1000); // Reasonable message length
    try std.testing.expect(std.mem.indexOf(u8, output, very_long_command) != null);
}

// Edge case tests migrated from error_edge_cases_test.zig

test "error handler with very long command names" {
    const allocator = std.testing.allocator;

    // Create a very long command name that should still generate suggestions
    var long_cmd_buf: [200]u8 = undefined;
    @memset(&long_cmd_buf, 'x');
    const long_cmd = long_cmd_buf[0..100];

    const available_commands = [_][]const u8{ "list", "search", "create", "delete" };

    var buffer: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try handleCommandNotFound(stream.writer(), long_cmd, &available_commands, "myapp", allocator);

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Unknown command") != null);
    try std.testing.expect(output.len < buffer.len); // Should not overflow
}

test "error handler with empty command lists" {
    const allocator = std.testing.allocator;

    const no_commands = [_][]const u8{};

    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try handleCommandNotFound(stream.writer(), "missing", &no_commands, "myapp", allocator);

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Unknown command 'missing'") != null);
    // The actual error handler might not include "No commands available" text
    // so let's just check that it handles empty command lists without crashing
}

test "edit distance with identical strings" {
    // Test the edge case where strings are identical (distance should be 0)
    const distance = editDistance("identical", "identical");
    try std.testing.expectEqual(@as(usize, 0), distance);
}

test "edit distance with empty strings" {
    // Test edge cases with empty strings
    try std.testing.expectEqual(@as(usize, 5), editDistance("", "hello"));
    try std.testing.expectEqual(@as(usize, 5), editDistance("hello", ""));
    try std.testing.expectEqual(@as(usize, 0), editDistance("", ""));
}

test "edit distance with very different strings" {
    // Test with completely different strings
    const distance = editDistance("abcdefghijk", "zyxwvutsrqp");
    try std.testing.expect(distance > 10); // Should be high distance
}
