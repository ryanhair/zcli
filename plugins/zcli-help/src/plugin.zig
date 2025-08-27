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
        // If no command was provided at all, show app help
        if (context.command_path.len == 0) {
            try showAppHelp(context);
            return true; // Error handled, don't let it propagate
        }
        
        // Check if this looks like a command group (has subcommands)
        if (context.command_path.len > 0) {
            const attempted_command = context.command_path[0];

            // Check if there are any subcommands for this command group
            const command_infos = context.getAvailableCommandInfo();
            var has_subcommands = false;

            for (command_infos) |cmd_info| {
                if (cmd_info.path.len >= 2 and std.mem.eql(u8, cmd_info.path[0], attempted_command)) {
                    has_subcommands = true;
                    break;
                }
            }

            // If we found subcommands, show group help and handle the error
            if (has_subcommands) {
                try showCommandGroupHelp(context, attempted_command);
                return true; // Error handled, don't let it propagate
            }
        }
    }

    return false; // Error not handled
}

/// Show help for a command group with subcommands
fn showCommandGroupHelp(context: *zcli.Context, group_name: []const u8) !void {
    const writer = context.stderr();

    try writer.print("'{s}' is a command group. Available subcommands:\n\n", .{group_name});

    try writer.writeAll("USAGE:\n");
    try writer.print("    {s} {s} <subcommand>\n\n", .{ context.app_name, group_name });

    try writer.writeAll("SUBCOMMANDS:\n");

    const command_infos = context.getAvailableCommandInfo();
    var displayed_names = std.ArrayList([]const u8).init(context.allocator);
    defer displayed_names.deinit();

    for (command_infos) |cmd_info| {
        // Find direct subcommands of this group
        if (cmd_info.path.len >= 2 and std.mem.eql(u8, cmd_info.path[0], group_name)) {
            const subcmd_name = cmd_info.path[1];

            // Avoid duplicates
            var already_added = false;
            for (displayed_names.items) |existing| {
                if (std.mem.eql(u8, existing, subcmd_name)) {
                    already_added = true;
                    break;
                }
            }

            if (!already_added) {
                try displayed_names.append(subcmd_name);

                if (cmd_info.description) |desc| {
                    try writer.print("    {s:<15} {s}\n", .{ subcmd_name, desc });
                } else {
                    try writer.print("    {s}\n", .{subcmd_name});
                }
            }
        }
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
    try writer.print("    {s} [GLOBAL OPTIONS] <COMMAND> [ARGS]\n\n", .{app_name});

    try writer.writeAll("COMMANDS:\n");

    // Collect top-level commands and their info using new command info system
    const CommandInfo = struct {
        name: []const u8,
        description: ?[]const u8,
        is_group: bool,
    };

    var top_level_commands = std.ArrayList(CommandInfo).init(context.allocator);
    defer top_level_commands.deinit();

    const command_infos = context.getAvailableCommandInfo();
    var displayed_names = std.ArrayList([]const u8).init(context.allocator);
    defer displayed_names.deinit();

    for (command_infos) |cmd_info| {
        if (cmd_info.path.len == 1) {
            const cmd_name = cmd_info.path[0];

            // Avoid duplicates
            var already_added = false;
            for (displayed_names.items) |existing| {
                if (std.mem.eql(u8, existing, cmd_name)) {
                    already_added = true;
                    break;
                }
            }

            if (!already_added) {
                try displayed_names.append(cmd_name);

                // Check if this command has subcommands (making it a group)
                var has_subcommands = false;
                for (command_infos) |other_cmd_info| {
                    if (other_cmd_info.path.len > 1 and std.mem.eql(u8, other_cmd_info.path[0], cmd_name)) {
                        has_subcommands = true;
                        break;
                    }
                }

                try top_level_commands.append(CommandInfo{
                    .name = cmd_name,
                    .description = cmd_info.description,
                    .is_group = has_subcommands,
                });
            }
        }
    }

    // Show top-level commands with descriptions
    for (top_level_commands.items) |cmd| {
        // Skip showing help command here since it's handled by the plugin system
        if (std.mem.eql(u8, cmd.name, "help")) continue;

        if (cmd.description) |desc| {
            try writer.print("    {s:<12} {s}\n", .{ cmd.name, desc });
        } else {
            try writer.print("    {s:<12} \n", .{cmd.name});
        }
    }

    // Always show help command last
    try writer.writeAll("    help         Show help for commands\n");

    try writer.writeAll("\nGLOBAL OPTIONS:\n");
    try writer.writeAll("    -h, --help       Show help information\n");
    try writer.writeAll("    -V, --version    Show version information\n");
    try writer.writeAll("\n");
    try writer.print("Run '{s} <command> --help' for more information on a command.\n", .{app_name});
}

/// Show help for a specific command
fn showCommandHelp(context: *zcli.Context, command: []const u8) !void {
    const writer = context.stderr();

    try writer.print("Help for command: {s}\n\n", .{command});

    // Access command metadata from context
    if (context.command_meta) |meta| {
        // Show description
        if (meta.description) |desc| {
            try writer.print("{s}\n\n", .{desc});
        }

        // Show usage (always generated)
        const usage_string = try generateUsage(context);
        defer context.allocator.free(usage_string);

        try writer.writeAll("USAGE:\n");
        try writer.print("    {s}\n\n", .{usage_string});

        // Show arguments (generated from command module info)
        if (context.command_module_info) |module_info| {
            if (module_info.has_args) {
                if (generateArgsHelp(module_info, context) catch null) |args_help| {
                    defer context.allocator.free(args_help);
                    try writer.writeAll("ARGUMENTS:\n");
                    try writer.writeAll(args_help);
                    try writer.writeAll("\n");
                }
            }
        }

        // Show subcommands (dynamically discovered)
        try showSubcommands(context, writer);

        // Show options (generated from command module info)
        try writer.writeAll("OPTIONS:\n");
        if (context.command_module_info) |module_info| {
            if (module_info.has_options) {
                if (generateOptionsHelp(module_info, context) catch null) |options_help| {
                    defer context.allocator.free(options_help);
                    try writer.writeAll(options_help);
                }
            }
        }
        try writer.print("    {s:<15} Show this help message\n\n", .{"--help, -h"});

        // Show examples
        if (meta.examples) |examples| {
            try writer.writeAll("EXAMPLES:\n");
            for (examples) |example| {
                try writer.print("    {s}\n", .{example});
            }
            try writer.writeAll("\n");
        }
    } else {
        // Fallback when no metadata is available
        try writer.writeAll("OPTIONS:\n");
        try writer.print("    {s:<15} Show this help message\n", .{"--help, -h"});
        try writer.writeAll("\n");
    }
}

/// Generate usage string based on command structure
fn generateUsage(context: *zcli.Context) ![]const u8 {
    var usage_parts = std.ArrayList([]const u8).init(context.allocator);
    defer usage_parts.deinit();

    // Track allocated strings that need to be freed
    var allocated_pattern: ?[]const u8 = null;
    defer if (allocated_pattern) |pattern| context.allocator.free(pattern);

    // Start with app name
    try usage_parts.append(context.app_name);

    // Add command path
    for (context.command_path) |path_part| {
        try usage_parts.append(path_part);
    }

    // Check if this command has subcommands
    const has_subcommands = blk: {
        for (context.available_commands) |cmd_parts| {
            if (cmd_parts.len == context.command_path.len + 1) {
                // Check if the prefix matches current command path
                var matches = true;
                for (context.command_path, 0..) |path_part, i| {
                    if (!std.mem.eql(u8, path_part, cmd_parts[i])) {
                        matches = false;
                        break;
                    }
                }
                if (matches) break :blk true;
            }
        }
        break :blk false;
    };

    if (has_subcommands) {
        // This is a command group - show COMMAND
        try usage_parts.append("COMMAND");
    } else {
        // This is a leaf command - show [OPTIONS] and args pattern
        var has_options = false;
        var has_args = false;

        // Check if we have options or args from command module info
        if (context.command_module_info) |module_info| {
            has_options = module_info.has_options;
            has_args = module_info.has_args;
        }

        if (has_options) {
            try usage_parts.append("[OPTIONS]");
        }

        if (has_args) {
            // Generate args pattern from command module info
            if (context.command_module_info) |module_info| {
                if (generateArgsPattern(module_info, context) catch null) |pattern| {
                    allocated_pattern = pattern; // Remember to free this later
                    try usage_parts.append(pattern);
                } else {
                    try usage_parts.append("[ARGS...]");
                }
            } else {
                try usage_parts.append("[ARGS...]");
            }
        }
    }

    // Join all parts with spaces
    return try std.mem.join(context.allocator, " ", usage_parts.items);
}

/// Show available subcommands for the current command
fn showSubcommands(context: *zcli.Context, writer: anytype) !void {
    const command_infos = context.getAvailableCommandInfo();
    var displayed_names = std.ArrayList([]const u8).init(context.allocator);
    defer displayed_names.deinit();

    var has_commands = false;

    for (command_infos) |cmd_info| {
        var should_display = false;
        var display_name: []const u8 = undefined;

        if (context.command_path.len == 0) {
            // At root level, show all top-level commands
            if (cmd_info.path.len == 1) {
                should_display = true;
                display_name = cmd_info.path[0];
            }
        } else {
            // Find subcommands that extend the current path
            if (cmd_info.path.len == context.command_path.len + 1) {
                // Check if the prefix matches
                var matches = true;
                for (context.command_path, 0..) |path_part, i| {
                    if (!std.mem.eql(u8, path_part, cmd_info.path[i])) {
                        matches = false;
                        break;
                    }
                }

                if (matches) {
                    should_display = true;
                    display_name = cmd_info.path[context.command_path.len];
                }
            }
        }

        if (should_display) {
            // Avoid duplicates
            var already_added = false;
            for (displayed_names.items) |existing| {
                if (std.mem.eql(u8, existing, display_name)) {
                    already_added = true;
                    break;
                }
            }

            if (!already_added) {
                try displayed_names.append(display_name);

                if (!has_commands) {
                    try writer.writeAll("COMMANDS:\n");
                    has_commands = true;
                }

                if (cmd_info.description) |desc| {
                    try writer.print("    {s:<15} {s}\n", .{ display_name, desc });
                } else {
                    try writer.print("    {s}\n", .{display_name});
                }
            }
        }
    }

    if (has_commands) {
        try writer.writeAll("\n");
    }
}

/// Generate args pattern from command module info (e.g., "IMAGE [COMMAND] [ARG...]")
/// Returns null if there are no args to display
fn generateArgsPattern(module_info: zcli.CommandModuleInfo, context: *zcli.Context) !?[]u8 {
    if (!module_info.has_args or module_info.args_fields.len == 0) return null;

    var buffer = std.ArrayList(u8).init(context.allocator);
    errdefer buffer.deinit();
    var writer = buffer.writer();

    var first = true;
    for (module_info.args_fields) |field_info| {
        if (!first) try writer.writeAll(" ");
        first = false;

        // Convert field name to UPPERCASE for usage
        var field_name_buf: [64]u8 = std.mem.zeroes([64]u8);

        // Protect against buffer overflow
        const safe_len = @min(field_info.name.len, field_name_buf.len);
        for (field_info.name[0..safe_len], 0..) |c, i| {
            field_name_buf[i] = std.ascii.toUpper(c);
        }
        const field_name = field_name_buf[0..safe_len];

        if (field_info.is_array) {
            // Varargs field
            if (field_info.is_optional) {
                try writer.print("[{s}...]", .{field_name});
            } else {
                try writer.print("{s}...", .{field_name});
            }
        } else {
            // Regular field
            if (field_info.is_optional) {
                try writer.print("[{s}]", .{field_name});
            } else {
                try writer.print("{s}", .{field_name});
            }
        }
    }

    return try buffer.toOwnedSlice();
}

/// Generate args help text from command module info
/// Returns null if there are no args to display
fn generateArgsHelp(module_info: zcli.CommandModuleInfo, context: *zcli.Context) !?[]u8 {
    if (!module_info.has_args or module_info.args_fields.len == 0) return null;

    var buffer = std.ArrayList(u8).init(context.allocator);
    errdefer buffer.deinit();
    var writer = buffer.writer();

    // Generate basic help from field names - description extraction would require
    // casting raw_meta_ptr which we can't do generically at runtime
    for (module_info.args_fields) |field_info| {
        // TODO: Extract descriptions from meta if available (needs type-specific casting)
        try writer.print("    {s}    {s}\n", .{ field_info.name, field_info.name });
    }

    return try buffer.toOwnedSlice();
}

/// Generate options help text from command module info
/// Returns null if there are no options to display
fn generateOptionsHelp(module_info: zcli.CommandModuleInfo, context: *zcli.Context) !?[]u8 {
    if (!module_info.has_options or module_info.options_fields.len == 0) return null;

    var buffer = std.ArrayList(u8).init(context.allocator);
    errdefer buffer.deinit();
    var writer = buffer.writer();

    // Generate basic help from field names
    for (module_info.options_fields) |field_info| {
        // Convert underscores to dashes in field name
        var option_name_buf: [64]u8 = undefined;
        var i: usize = 0;
        for (field_info.name) |c| {
            option_name_buf[i] = if (c == '_') '-' else c;
            i += 1;
        }
        const option_name = option_name_buf[0..field_info.name.len];

        // TODO: Extract descriptions and short flags from meta if available
        try writer.print("    --{s:<13} {s}\n", .{ option_name, field_info.name });
    }

    return try buffer.toOwnedSlice();
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
