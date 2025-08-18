const std = @import("std");
const levenshtein = @import("levenshtein.zig");

/// zcli-suggestions Plugin
/// 
/// Provides intelligent command suggestions using Levenshtein distance algorithm.
/// This plugin enhances error messages with helpful command suggestions.

// Error transformer - enhances error messages with command suggestions
pub fn transformError(comptime next: anytype) type {
    return struct {
        pub fn handle(err: anyerror, ctx: anytype) !void {
            // Get suggestion configuration from context if available
            const config = if (@hasField(@TypeOf(ctx.*), "zcli_suggestions")) 
                ctx.zcli_suggestions 
            else 
                ContextExtension{};

            switch (err) {
                error.CommandNotFound => {
                    if (@hasField(@TypeOf(ctx.*), "attempted_command") and @hasField(@TypeOf(ctx.*), "available_commands")) {
                        try handleCommandNotFoundWithSuggestions(
                            ctx.io.stderr.writer(),
                            ctx.attempted_command,
                            ctx.available_commands,
                            ctx.app_name,
                            ctx.allocator,
                            config
                        );
                        return;
                    }
                },
                error.SubcommandNotFound => {
                    if (@hasField(@TypeOf(ctx.*), "attempted_subcommand") and @hasField(@TypeOf(ctx.*), "available_subcommands")) {
                        try handleSubcommandNotFoundWithSuggestions(
                            ctx.io.stderr.writer(),
                            ctx.parent_command orelse "unknown",
                            ctx.attempted_subcommand,
                            ctx.available_subcommands,
                            ctx.app_name,
                            ctx.allocator,
                            config
                        );
                        return;
                    }
                },
                else => {
                    // For other errors, just pass through to the next handler
                },
            }
            
            // Call the next error handler in the chain
            try next.handle(err, ctx);
        }
    };
}

// Context extension - stores suggestion-related configuration
pub const ContextExtension = struct {
    max_suggestions: usize,
    max_distance: usize,
    show_all_commands: bool,
    
    pub fn init(allocator: std.mem.Allocator) !@This() {
        _ = allocator;
        return .{
            .max_suggestions = 3,
            .max_distance = 3,
            .show_all_commands = true,
        };
    }
    
    pub fn deinit(self: *@This()) void {
        _ = self;
        // No cleanup needed for this simple extension
    }
};

// No plugin commands - this plugin only provides error suggestion functionality

// Private helper functions

fn handleCommandNotFoundWithSuggestions(
    writer: anytype,
    command: []const u8,
    available_commands: []const []const u8,
    app_name: []const u8,
    allocator: std.mem.Allocator,
    config: ContextExtension,
) !void {
    try writer.print("Error: Unknown command '{s}'\n\n", .{command});

    // Try to suggest similar commands using our enhanced algorithm
    const suggestions = levenshtein.findSimilarCommandsWithConfig(
        command, 
        available_commands, 
        allocator,
        config.max_distance,
        config.max_suggestions
    ) catch {
        // Fallback to basic suggestions on error
        const basic_suggestions = levenshtein.findSimilarCommands(command, available_commands, allocator) catch &[_][]const u8{};
        defer if (basic_suggestions.len > 0) allocator.free(basic_suggestions);
        
        if (basic_suggestions.len > 0) {
            try writer.print("Did you mean '{s}'?\n\n", .{basic_suggestions[0]});
        }
        
        if (config.show_all_commands) {
            try writer.print("Available commands:\n", .{});
            for (available_commands) |cmd| {
                try writer.print("    {s}\n", .{cmd});
            }
            try writer.print("\n", .{});
        }
        
        try writer.print("Run '{s} --help' to see all available commands.\n", .{app_name});
        return;
    };
    defer if (suggestions.len > 0) allocator.free(suggestions);

    if (suggestions.len > 0) {
        if (suggestions.len == 1) {
            try writer.print("Did you mean '{s}'?\n\n", .{suggestions[0]});
        } else {
            try writer.print("Did you mean one of these?\n", .{});
            for (suggestions) |suggestion| {
                try writer.print("    {s}\n", .{suggestion});
            }
            try writer.print("\n", .{});
        }
    }

    if (config.show_all_commands) {
        try writer.print("Available commands:\n", .{});
        for (available_commands) |cmd| {
            try writer.print("    {s}\n", .{cmd});
        }
        try writer.print("\n", .{});
    }

    try writer.print("Run '{s} --help' to see all available commands.\n", .{app_name});
}

fn handleSubcommandNotFoundWithSuggestions(
    writer: anytype,
    parent_command: []const u8,
    subcommand: []const u8,
    available_subcommands: []const []const u8,
    app_name: []const u8,
    allocator: std.mem.Allocator,
    config: ContextExtension,
) !void {
    try writer.print("Error: Unknown subcommand '{s}' for '{s}'\n\n", .{ subcommand, parent_command });

    // Try to suggest similar subcommands
    const suggestions = levenshtein.findSimilarCommandsWithConfig(
        subcommand, 
        available_subcommands, 
        allocator,
        config.max_distance,
        config.max_suggestions
    ) catch {
        if (config.show_all_commands) {
            try writer.print("Available subcommands for '{s}':\n", .{parent_command});
            for (available_subcommands) |cmd| {
                try writer.print("    {s}\n", .{cmd});
            }
            try writer.print("\n", .{});
        }
        try writer.print("Run '{s} {s} --help' for more information.\n", .{ app_name, parent_command });
        return;
    };
    defer if (suggestions.len > 0) allocator.free(suggestions);

    if (suggestions.len > 0) {
        if (suggestions.len == 1) {
            try writer.print("Did you mean '{s}'?\n\n", .{suggestions[0]});
        } else {
            try writer.print("Did you mean one of these?\n", .{});
            for (suggestions) |suggestion| {
                try writer.print("    {s}\n", .{suggestion});
            }
            try writer.print("\n", .{});
        }
    }

    if (config.show_all_commands) {
        try writer.print("Available subcommands for '{s}':\n", .{parent_command});
        for (available_subcommands) |cmd| {
            try writer.print("    {s}\n", .{cmd});
        }
        try writer.print("\n", .{});
    }

    try writer.print("Run '{s} {s} --help' for more information.\n", .{ app_name, parent_command });
}

fn showSuggestionConfig(ctx: anytype, options: anytype) !void {
    _ = options;
    const config = if (@hasField(@TypeOf(ctx.*), "zcli_suggestions")) 
        ctx.zcli_suggestions 
    else 
        ContextExtension{};
        
    try ctx.io.stdout.print("Suggestion Configuration:\n");
    try ctx.io.stdout.print("  Max suggestions: {}\n", .{config.max_suggestions});
    try ctx.io.stdout.print("  Max distance: {}\n", .{config.max_distance});
    try ctx.io.stdout.print("  Show all commands: {}\n", .{config.show_all_commands});
}

fn configureSuggestions(ctx: anytype, options: anytype) !void {
    var config = if (@hasField(@TypeOf(ctx.*), "zcli_suggestions")) 
        ctx.zcli_suggestions 
    else 
        ContextExtension{};
    
    if (options.max_suggestions) |max_sugg| {
        config.max_suggestions = max_sugg;
        try ctx.io.stdout.print("Set max suggestions to {}\n", .{max_sugg});
    }
    
    if (options.max_distance) |max_dist| {
        config.max_distance = max_dist;
        try ctx.io.stdout.print("Set max distance to {}\n", .{max_dist});
    }
    
    if (options.show_all) |show_all| {
        config.show_all_commands = show_all;
        try ctx.io.stdout.print("Set show all commands to {}\n", .{show_all});
    }
    
    // In a real implementation, this would save the config somewhere persistent
    try ctx.io.stdout.print("Configuration updated (changes apply to current session only)\n");
}

fn testSuggestions(ctx: anytype, options: anytype) !void {
    _ = options;
    const test_commands = [_][]const u8{ "list", "search", "create", "delete", "status", "start", "stop" };
    const test_input = "serach";
    
    try ctx.io.stdout.print("Testing suggestions for '{s}':\n", .{test_input});
    
    const config = if (@hasField(@TypeOf(ctx.*), "zcli_suggestions")) 
        ctx.zcli_suggestions 
    else 
        ContextExtension{};
    
    const suggestions = levenshtein.findSimilarCommandsWithConfig(
        test_input,
        &test_commands,
        ctx.allocator,
        config.max_distance,
        config.max_suggestions
    ) catch {
        try ctx.io.stdout.print("Error generating suggestions\n", .{});
        return;
    };
    defer if (suggestions.len > 0) ctx.allocator.free(suggestions);
    
    if (suggestions.len > 0) {
        try ctx.io.stdout.print("Suggestions:\n");
        for (suggestions) |suggestion| {
            const distance = levenshtein.editDistance(test_input, suggestion);
            try ctx.io.stdout.print("  {s} (distance: {})\n", .{ suggestion, distance });
        }
    } else {
        try ctx.io.stdout.print("No suggestions found\n");
    }
}

// Tests for the plugin
test "suggestion plugin structure" {
    // Verify the plugin has the expected structure
    try std.testing.expect(@hasDecl(@This(), "transformError"));
    try std.testing.expect(@hasDecl(@This(), "ContextExtension"));
    // No commands exported by this plugin
}

test "context extension lifecycle" {
    const allocator = std.testing.allocator;
    
    // Test initialization
    var ext = try ContextExtension.init(allocator);
    try std.testing.expect(ext.max_suggestions == 3);
    try std.testing.expect(ext.max_distance == 3);
    try std.testing.expect(ext.show_all_commands == true);
    
    // Test deinit (should not crash)
    ext.deinit();
}

test "enhanced suggestion handling" {
    const allocator = std.testing.allocator;
    
    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    
    const available_commands = [_][]const u8{ "list", "search", "create", "delete" };
    const config = ContextExtension{
        .max_suggestions = 2,
        .max_distance = 2,
        .show_all_commands = false,
    };
    
    try handleCommandNotFoundWithSuggestions(
        stream.writer(),
        "serach",
        &available_commands,
        "myapp",
        allocator,
        config
    );
    
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Unknown command 'serach'") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "search") != null);
}