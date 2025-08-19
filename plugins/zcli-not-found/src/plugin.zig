const std = @import("std");
const zcli = @import("zcli");
const levenshtein = @import("levenshtein.zig");

/// zcli-not-found Plugin
/// 
/// Handles command-not-found errors with intelligent "did you mean" suggestions
/// using Levenshtein distance algorithm to find similar commands.

/// Handle error events - specifically CommandNotFound errors
pub fn handleError(context: anytype, event: zcli.ErrorEvent) !?zcli.PluginResult {
    if (event.err == error.CommandNotFound) {
        const help_text = try generateCommandNotFoundHelp(
            context,
            event.command_path orelse "unknown",
            event.available_commands orelse &[_][]const u8{},
        );
        return zcli.PluginResult{
            .handled = true,
            .output = help_text,
            .stop_execution = true,
        };
    }
    return null; // Not handled
}

/// Generate help text for command not found errors
fn generateCommandNotFoundHelp(
    context: anytype,
    attempted_command: []const u8,
    available_commands: []const []const u8,
) ![]const u8 {
    const allocator = context.allocator;
    var help_text = std.ArrayList(u8).init(allocator);
    const writer = help_text.writer();
    
    // Error header
    try writer.print("Error: Unknown command '{s}'\n\n", .{attempted_command});
    
    // Safety check for available_commands
    if (available_commands.len == 0) {
        try writer.print("No commands available for suggestions.\n");
        try writer.print("\nRun '<app> --help' to see all available commands.\n");
        return help_text.toOwnedSlice();
    }
    
    // Find similar commands
    const suggestions = findBestSuggestions(
        attempted_command,
        available_commands,
        allocator,
        3, // max suggestions
        3, // max edit distance
    ) catch null;
    
    if (suggestions) |suggs| {
        defer allocator.free(suggs);
        
        if (suggs.len > 0) {
            if (suggs.len == 1) {
                try writer.print("Did you mean '{s}'?\n\n", .{suggs[0]});
            } else {
                try writer.print("Did you mean one of these?\n");
                for (suggs) |suggestion| {
                    try writer.print("    {s}\n", .{suggestion});
                }
                try writer.print("\n");
            }
        }
    }
    
    // Show available commands
    try writer.print("Available commands:\n");
    for (available_commands) |cmd| {
        try writer.print("    {s}\n", .{cmd});
    }
    try writer.print("\nRun '<app> --help' to see all available commands.\n");
    
    return help_text.toOwnedSlice();
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
    
    pub fn init(allocator: std.mem.Allocator) !@This() {
        _ = allocator;
        return .{
            .max_suggestions = 3,
            .max_distance = 3,
            .color_output = std.io.tty.detectConfig(std.io.getStdErr()) != .no_color,
        };
    }
    
    pub fn deinit(self: *@This()) void {
        _ = self;
    }
};

// Tests
test "not-found plugin structure" {
    try std.testing.expect(@hasDecl(@This(), "handleError"));
    try std.testing.expect(@hasDecl(@This(), "ContextExtension"));
}

test "handleError handles CommandNotFound" {
    const allocator = std.testing.allocator;
    
    // Mock context
    const MockContext = struct {
        allocator: std.mem.Allocator,
    };
    const context = MockContext{ .allocator = allocator };
    
    const commands = [_][]const u8{ "list", "search", "create" };
    
    // Test command not found error
    const event = zcli.ErrorEvent{
        .err = error.CommandNotFound,
        .command_path = "lst",
        .available_commands = &commands,
    };
    
    const result = try handleError(context, event);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.handled);
    try std.testing.expect(result.?.stop_execution);
    try std.testing.expect(result.?.output != null);
    
    // Check that output contains suggestion
    if (result.?.output) |output| {
        defer allocator.free(output);
        try std.testing.expect(std.mem.indexOf(u8, output, "list") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "Did you mean") != null);
    }
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