const std = @import("std");
const zcli = @import("zcli");

/// zcli-help Plugin
///
/// Provides help functionality for CLI applications using the lifecycle hook plugin system.
/// Global options provided by this plugin
pub const global_options = [_]zcli.GlobalOption{
    zcli.option("help", bool, .{ .short = 'h', .default = false, .description = "Show help message" }),
};

/// Handle global options - specifically the --help flag
pub fn handleGlobalOption(
    context: *zcli.Context,
    option_name: []const u8,
    value: anytype,
) !void {
    if (std.mem.eql(u8, option_name, "help")) {
        const bool_val = if (@TypeOf(value) == bool) value else false;
        if (bool_val) {
            try context.setGlobalData("help_requested", "true");
        }
    }
}

/// Pre-execute hook to show help if requested
pub fn preExecute(
    context: *zcli.Context,
    args: zcli.ParsedArgs,
) !?zcli.ParsedArgs {
    const help_requested = context.getGlobalData([]const u8, "help_requested") orelse "false";
    if (std.mem.eql(u8, help_requested, "true")) {
        // If command_path is empty, show app help; otherwise show command help
        if (context.command_path.len == 0) {
            try showAppHelp(context);
        } else {
            // Join command parts with spaces for display
            const command_string = try std.mem.join(context.allocator, " ", context.command_path);
            defer context.allocator.free(command_string);
            try showCommandHelp(context, command_string);
        }

        // Return null to stop execution
        return null;
    }

    // Continue normal execution
    return args;
}

/// Error hook to handle command group help
pub fn onError(
    context: *zcli.Context,
    err: anyerror,
) !bool {
    if (err == error.CommandNotFound) {
        // Check if this looks like a command group (has subcommands)
        if (context.command_path.len > 0) {
            const attempted_command = context.command_path[0];
            var subcommands = std.ArrayList([]const u8).init(context.allocator);
            defer subcommands.deinit();

            // Find all commands that start with the attempted command
            for (context.available_commands) |cmd_parts| {
                // Check if this command starts with the attempted command
                if (cmd_parts.len >= 2 and std.mem.eql(u8, cmd_parts[0], attempted_command)) {
                    // This is a subcommand - get the next part
                    try subcommands.append(cmd_parts[1]);
                }
            }

            // If we found subcommands, show group help and handle the error
            if (subcommands.items.len > 0) {
                try showCommandGroupHelp(context, attempted_command, subcommands.items);
                return true; // Error handled, don't let it propagate
            }
        }
    }

    return false; // Error not handled
}

/// Show help for a command group with subcommands
fn showCommandGroupHelp(context: *zcli.Context, group_name: []const u8, subcommands: []const []const u8) !void {
    const writer = context.stderr();

    try writer.print("'{s}' is a command group. Available subcommands:\n\n", .{group_name});

    try writer.writeAll("USAGE:\n");
    try writer.print("    {s} {s} <subcommand>\n\n", .{ context.app_name, group_name });

    try writer.writeAll("SUBCOMMANDS:\n");
    for (subcommands) |subcmd| {
        try writer.print("    {s}    \n", .{subcmd});
    }
    try writer.writeAll("\n");

    try writer.print("Run '{s} {s} <subcommand> --help' for more information on a specific subcommand.\n", .{ context.app_name, group_name });
    try writer.print("Run '{s} --help' for general help.\n", .{context.app_name});
}

/// Commands provided by this plugin
pub const commands = struct {
    /// The help command itself
    pub const help = struct {
        pub const Args = struct {
            command: ?[]const u8 = null,
        };

        pub const Options = struct {};

        pub const meta = .{
            .description = "Show help for commands",
        };

        pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
            _ = options;
            if (args.command) |cmd| {
                try showCommandHelp(context, cmd);
            } else {
                try showAppHelp(context);
            }
        }
    };
};

/// Show help for the entire application
fn showAppHelp(context: *zcli.Context) !void {
    const writer = context.stderr();

    // Get app metadata from context
    const app_name = context.app_name;
    const app_version = context.app_version;
    const app_description = context.app_description;

    try writer.print("{s} v{s}\n", .{ app_name, app_version });
    if (app_description.len > 0) {
        try writer.print("{s}\n", .{app_description});
    }
    try writer.writeAll("\n");

    try writer.writeAll("USAGE:\n");
    try writer.print("    {s} [command] [options]\n\n", .{app_name});

    try writer.writeAll("COMMANDS:\n");
    try writer.writeAll("    help    Show help for commands\n");
    // TODO: List other available commands when we have registry access
    try writer.writeAll("\n");

    try writer.writeAll("GLOBAL OPTIONS:\n");
    try writer.writeAll("    --help, -h    Show help message\n");
    try writer.writeAll("\n");
}

/// Show help for a specific command
fn showCommandHelp(context: *zcli.Context, command: []const u8) !void {
    const writer = context.stderr();

    try writer.print("Help for command: {s}\n\n", .{command});

    // TODO: When we have access to command metadata, show:
    // - Command description
    // - Usage
    // - Arguments
    // - Options
    // - Examples

    try writer.writeAll("OPTIONS:\n");
    try writer.writeAll("    --help, -h    Show this help message\n");
    try writer.writeAll("\n");
}

// Context extension - optional configuration for the help plugin
pub const ContextExtension = struct {
    show_examples: bool = true,
    show_tips: bool = true,
    color_output: bool = true,
    max_width: usize = 80,
    // Store command metadata for help generation
    command_metadata: std.StringHashMap(CommandMetadata),

    pub fn init(allocator: std.mem.Allocator) !@This() {
        return .{
            .show_examples = true,
            .show_tips = true,
            .color_output = std.io.tty.detectConfig(std.io.getStdErr()) != .no_color,
            .max_width = 80,
            .command_metadata = std.StringHashMap(CommandMetadata).init(allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.command_metadata.deinit();
    }
};

/// Metadata about a command for help generation
const CommandMetadata = struct {
    description: ?[]const u8 = null,
    usage: ?[]const u8 = null,
    examples: ?[]const []const u8 = null,
};

// Tests
test "help plugin structure" {
    try std.testing.expect(@hasDecl(@This(), "global_options"));
    try std.testing.expect(@hasDecl(@This(), "handleGlobalOption"));
    try std.testing.expect(@hasDecl(@This(), "preExecute"));
    try std.testing.expect(@hasDecl(@This(), "commands"));
    try std.testing.expect(@hasDecl(@This(), "ContextExtension"));
}

test "handleGlobalOption handles help flag" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var context = zcli.Context.init(gpa.allocator());
    defer context.deinit();

    // Test handling --help flag
    try handleGlobalOption(&context, "help", true);

    const help_requested = context.getGlobalData([]const u8, "help_requested") orelse "false";
    try std.testing.expectEqualStrings("true", help_requested);
}

test "help command execution" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var context = zcli.Context.init(gpa.allocator());
    defer context.deinit();

    // Test help command with no arguments (shows app help)
    const args = commands.help.Args{ .command = null };
    const options = commands.help.Options{};

    try commands.help.execute(args, options, &context);
    // Test passes if it doesn't crash
}
