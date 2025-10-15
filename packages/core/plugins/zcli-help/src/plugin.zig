const std = @import("std");
const zcli = @import("zcli");
const md = @import("markdown-fmt");

/// zcli-help Plugin
///
/// Provides help functionality for CLI applications using the lifecycle hook plugin system.

// Column where descriptions should start (after indentation)
const DESCRIPTION_COLUMN: usize = 20;

// Helper struct for collecting command information
const CommandInfo = struct {
    name: []const u8,
    description: ?[]const u8,
    is_group: bool,
};

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
            const command_infos = context.getAvailableCommandInfo();

            // Try to find the deepest command group that has subcommands
            // Start from the full path and work backwards
            var depth = context.command_path.len;
            while (depth > 0) : (depth -= 1) {
                const prefix = context.command_path[0..depth];
                var has_subcommands = false;

                // Check if this prefix has any subcommands
                for (command_infos) |cmd_info| {
                    if (cmd_info.path.len > depth) {
                        // Check if the prefix matches
                        var matches = true;
                        for (prefix, 0..) |part, i| {
                            if (!std.mem.eql(u8, cmd_info.path[i], part)) {
                                matches = false;
                                break;
                            }
                        }
                        if (matches) {
                            has_subcommands = true;
                            break;
                        }
                    }
                }

                // If we found subcommands at this depth, show help for this group
                if (has_subcommands) {
                    const group_name = try std.mem.join(context.allocator, " ", prefix);
                    defer context.allocator.free(group_name);
                    try showCommandGroupHelp(context, group_name);
                    return true; // Error handled, don't let it propagate
                }
            }
        }
    }

    return false; // Error not handled
}

/// Unified help display function that handles all help scenarios
fn showHelp(context: *zcli.Context, help_type: HelpType) !void {
    var writer = context.stderr();
    var fmt = md.formatter(writer);
    const app_name = context.app_name;
    const app_version = context.app_version;
    const app_description = context.app_description;

    // Print appropriate header based on help type
    switch (help_type) {
        .app => {
            try fmt.write("<command>{s}</command> v{s}\n", .{ app_name, app_version });
            if (app_description.len > 0) {
                try writer.print("{s}\n", .{app_description});
            }
            try writer.writeAll("\n");
        },
        .root => {
            try fmt.write("<command>{s}</command> v{s}\n", .{ app_name, app_version });
            try writer.print("{s}\n\n", .{app_description});
        },
        .command_group => |group_name| {
            try fmt.write("'<command>{s}</command>' is a command group. Available subcommands:\n\n", .{group_name});
        },
        .command => |command_name| {
            try fmt.write("Help for command: <command>{s}</command>\n\n", .{command_name});

            // Show description if available
            if (context.command_meta) |meta| {
                if (meta.description) |desc| {
                    try writer.print("{s}\n\n", .{desc});
                }
            }
        },
    }

    // Show usage
    try fmt.write("**USAGE:**\n", .{});
    switch (help_type) {
        .app, .root => {
            if (help_type == .root) {
                // Root command can be invoked directly
                try fmt.write("    <command>{s}</command> [OPTIONS]", .{app_name});
                if (context.command_module_info) |module_info| {
                    if (module_info.has_args) {
                        try writer.writeAll(" [ARGS...]");
                    }
                }
                try writer.writeAll("\n");
            }
            try fmt.write("    <command>{s}</command> [GLOBAL OPTIONS] <COMMAND> [ARGS]\n\n", .{app_name});
        },
        .command_group => |group_name| {
            try fmt.write("    <command>{s}</command> <command>{s}</command> <subcommand>\n\n", .{ app_name, group_name });
        },
        .command => {
            const usage_string = try generateUsage(context);
            defer context.allocator.free(usage_string);
            try writer.print("    {s}\n\n", .{usage_string});
        },
    }

    // Show arguments (for commands that have them)
    if (help_type == .command or help_type == .root) {
        if (context.command_module_info) |module_info| {
            if (module_info.has_args) {
                if (generateArgsHelp(module_info, context) catch null) |args_help| {
                    defer context.allocator.free(args_help);
                    try fmt.write("**ARGUMENTS:**\n", .{});
                    try writer.writeAll(args_help);
                    try writer.writeAll("\n");
                }
            }
        }
    }

    // Show root command's options first (for root help)
    if (help_type == .root) {
        if (context.command_module_info) |module_info| {
            if (module_info.has_options) {
                if (generateOptionsHelp(module_info, context) catch null) |options_help| {
                    defer context.allocator.free(options_help);
                    try fmt.write("**OPTIONS:**\n", .{});
                    try writer.writeAll(options_help);
                    try fmt.write("    <flag>--help</flag>, <flag>-h</flag>{s:<6} Show this help message\n\n", .{""});
                }
            }
        }
    }

    // Show commands/subcommands
    switch (help_type) {
        .app, .root => {
            try showCommandList(context, &fmt, .top_level);
        },
        .command_group => |group_name| {
            try showCommandList(context, &fmt, .{ .subcommands_of = group_name });
        },
        .command => {
            // Show subcommands if any
            try showSubcommands(context, &fmt);
        },
    }

    // Show options (for non-root commands)
    if (help_type == .command) {
        try fmt.write("**OPTIONS:**\n", .{});
        if (context.command_module_info) |module_info| {
            if (module_info.has_options) {
                if (generateOptionsHelp(module_info, context) catch null) |options_help| {
                    defer context.allocator.free(options_help);
                    try writer.writeAll(options_help);
                }
            }
        }
        try fmt.write("    <flag>--help</flag>, <flag>-h</flag>{s:<6} Show this help message\n\n", .{""});
    }

    // Show global options (for app and root help)
    if (help_type == .app or help_type == .root) {
        try fmt.write("\n**GLOBAL OPTIONS:**\n", .{});
        try fmt.write("    <flag>-h</flag>, <flag>--help</flag>{s:<6} Show help information\n", .{""});
        try fmt.write("    <flag>-V</flag>, <flag>--version</flag>{s:<3} Show version information\n", .{""});
    }

    // Show examples if available
    if ((help_type == .command or help_type == .root) and context.command_meta != null) {
        if (context.command_meta.?.examples) |examples| {
            try fmt.write("\n**EXAMPLES:**\n", .{});
            for (examples) |example| {
                try writer.print("    {s}\n", .{example});
            }
        }
    }

    // Show footer
    try writer.writeAll("\n");
    switch (help_type) {
        .app, .root => {
            try fmt.write("Run '<command>{s}</command> <command><COMMAND></command> <flag>--help</flag>' for more information on a command.\n", .{app_name});
        },
        .command_group => |group_name| {
            try fmt.write("Run '<command>{s}</command> <command>{s}</command> <subcommand> <flag>--help</flag>' for more information on a specific subcommand.\n", .{ app_name, group_name });
            try fmt.write("Run '<command>{s}</command> <flag>--help</flag>' for general help.\n", .{app_name});
        },
        .command => {},
    }
}

/// Type of help to display
const HelpType = union(enum) {
    app, // General application help
    root, // Root command help (app help with root's options)
    command_group: []const u8, // Command group help (shows subcommands)
    command: []const u8, // Specific command help
};

/// List type for showCommandList
const CommandListType = union(enum) {
    top_level, // Show top-level commands
    subcommands_of: []const u8, // Show subcommands of a specific command
};

/// Show a list of commands (used by unified help function)
fn showCommandList(context: *zcli.Context, fmt: anytype, list_type: CommandListType) !void {
    if (list_type == .top_level) {
        try fmt.write("**COMMANDS:**\n", .{});
    } else {
        try fmt.write("**SUBCOMMANDS:**\n", .{});
    }

    const command_infos = context.getAvailableCommandInfo();
    var displayed_names: std.ArrayList([]const u8) = .empty;
    defer displayed_names.deinit(context.allocator);

    // First pass: collect unique command names and find the best description for each
    var command_map = std.StringHashMap(?[]const u8).init(context.allocator);
    defer command_map.deinit();

    for (command_infos) |cmd_info| {
        var should_process = false;
        var display_name: []const u8 = undefined;
        var is_exact_match = false;

        switch (list_type) {
            .top_level => {
                if (cmd_info.path.len >= 1) {
                    should_process = true;
                    display_name = cmd_info.path[0];
                    // Exact match if this is a top-level command (path.len == 1)
                    is_exact_match = (cmd_info.path.len == 1);
                }
            },
            .subcommands_of => |parent| {
                // Split parent by spaces to get the full parent path
                var parent_parts: std.ArrayList([]const u8) = .empty;
                defer parent_parts.deinit(context.allocator);

                var iter = std.mem.splitScalar(u8, parent, ' ');
                while (iter.next()) |part| {
                    if (part.len > 0) {
                        try parent_parts.append(context.allocator, part);
                    }
                }

                const parent_depth = parent_parts.items.len;

                // Check if this command is a subcommand of the parent
                if (cmd_info.path.len > parent_depth) {
                    // Check if all parent parts match
                    var matches = true;
                    for (parent_parts.items, 0..) |part, i| {
                        if (!std.mem.eql(u8, cmd_info.path[i], part)) {
                            matches = false;
                            break;
                        }
                    }

                    if (matches) {
                        should_process = true;
                        display_name = cmd_info.path[parent_depth];
                        // Exact match if the path length is exactly parent_depth + 1
                        is_exact_match = (cmd_info.path.len == parent_depth + 1);
                    }
                }
            },
        }

        if (should_process) {
            const existing = command_map.get(display_name);

            // Add or update the command in the map
            // Only use descriptions from exact matches (commands at the correct depth)
            if (existing == null) {
                // First time seeing this command
                // Only add description if it's an exact match
                if (is_exact_match) {
                    try command_map.put(display_name, cmd_info.description);
                } else {
                    // Not an exact match, add with no description
                    try command_map.put(display_name, null);
                }
            } else if (is_exact_match and cmd_info.description != null) {
                // We have an exact match with a description, prefer it over previous entries
                try command_map.put(display_name, cmd_info.description);
            }
            // Otherwise keep existing entry
        }
    }

    // Second pass: display commands in order
    var it = command_map.iterator();
    while (it.next()) |entry| {
        const display_name = entry.key_ptr.*;
        const description = entry.value_ptr.*;

        // Skip help command for top-level (we'll add it manually)
        if (list_type == .top_level and std.mem.eql(u8, display_name, "help")) continue;

        try displayed_names.append(context.allocator, display_name);

        if (description) |desc| {
            try fmt.write("    <command>{s:<16}</command> {s}\n", .{ display_name, desc });
        } else {
            try fmt.write("    <command>{s:<16}</command>\n", .{display_name});
        }
    }

    // Always show help command last for top-level
    if (list_type == .top_level) {
        try fmt.write("    <command>{s:<16}</command> Show help for commands\n\n", .{"help"});
    }
}

/// Show help for a command group with subcommands
fn showCommandGroupHelp(context: *zcli.Context, group_name: []const u8) !void {
    try showHelp(context, .{ .command_group = group_name });
}

/// Commands provided by this plugin
pub const commands = struct {
    /// The help command itself
    pub const help = struct {
        pub const Args = struct {
            command: ?[]const u8 = null,
        };

        pub const Options = zcli.NoOptions;

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
    try showHelp(context, .app);
}

/// Show help for root command (special case - shows app-level help with root's options)
fn showRootCommandHelp(context: *zcli.Context) !void {
    try showHelp(context, .root);
}

/// Show help for a specific command
fn showCommandHelp(context: *zcli.Context, command: []const u8) !void {
    // Special handling for root command
    if (std.mem.eql(u8, command, "root")) {
        try showRootCommandHelp(context);
        return;
    }

    try showHelp(context, .{ .command = command });
}

/// Generate usage string based on command structure
fn generateUsage(context: *zcli.Context) ![]const u8 {
    // Build a markdown-formatted usage string using the formatter
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(context.allocator);
    const buf_writer = buf.writer(context.allocator);
    var fmt = md.formatter(buf_writer);

    // Start with app name and command path
    try fmt.write("<command>{s}</command>", .{context.app_name});
    for (context.command_path) |path_part| {
        try fmt.write(" <command>{s}</command>", .{path_part});
    }

    // Check if this command has subcommands
    const has_subcommands = blk: {
        for (context.available_commands) |cmd_parts| {
            if (cmd_parts.len == context.command_path.len + 1) {
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
        try buf_writer.writeAll(" COMMAND");
    } else {
        var has_options = false;
        var has_args = false;

        if (context.command_module_info) |module_info| {
            has_options = module_info.has_options;
            has_args = module_info.has_args;
        }

        if (has_options) {
            try buf_writer.writeAll(" [OPTIONS]");
        }

        if (has_args) {
            if (context.command_module_info) |module_info| {
                if (generateArgsPattern(module_info, context) catch null) |pattern| {
                    defer context.allocator.free(pattern);
                    try buf_writer.print(" {s}", .{pattern});
                } else {
                    try buf_writer.writeAll(" [ARGS...]");
                }
            } else {
                try buf_writer.writeAll(" [ARGS...]");
            }
        }
    }

    return try buf.toOwnedSlice(context.allocator);
}

/// Show available subcommands for the current command
fn showSubcommands(context: *zcli.Context, fmt: anytype) !void {
    const command_infos = context.getAvailableCommandInfo();
    var displayed_names: std.ArrayList([]const u8) = .empty;
    defer displayed_names.deinit(context.allocator);

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
                try displayed_names.append(context.allocator, display_name);

                if (!has_commands) {
                    try fmt.write("**COMMANDS:**\n", .{});
                    has_commands = true;
                }

                if (cmd_info.description) |desc| {
                    try fmt.write("    <command>{s:<15}</command> {s}\n", .{ display_name, desc });
                } else {
                    try fmt.write("    <command>{s}</command>\n", .{display_name});
                }
            }
        }
    }

    if (has_commands) {
        try fmt.write("\n", .{});
    }
}

/// Generate args pattern from command module info (e.g., "IMAGE [COMMAND] [ARG...]")
/// Returns null if there are no args to display
fn generateArgsPattern(module_info: zcli.CommandModuleInfo, context: *zcli.Context) !?[]u8 {
    if (!module_info.has_args or module_info.args_fields.len == 0) return null;

    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(context.allocator);
    var writer = buffer.writer(context.allocator);

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

    return try buffer.toOwnedSlice(context.allocator);
}

/// Generate args help text from command module info
/// Returns null if there are no args to display
fn generateArgsHelp(module_info: zcli.CommandModuleInfo, context: *zcli.Context) !?[]u8 {
    if (!module_info.has_args or module_info.args_fields.len == 0) return null;

    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(context.allocator);
    const buf_writer = buffer.writer(context.allocator);
    var buf_fmt = md.formatter(buf_writer);

    // Generate basic help from field names
    for (module_info.args_fields) |field_info| {
        try buf_fmt.write("    <value>{s:<16}</value> {s}\n", .{ field_info.name, field_info.name });
    }

    return try buffer.toOwnedSlice(context.allocator);
}

/// Generate options help text from command module info
/// Returns null if there are no options to display
fn generateOptionsHelp(module_info: zcli.CommandModuleInfo, context: *zcli.Context) !?[]u8 {
    if (!module_info.has_options or module_info.options_fields.len == 0) return null;

    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(context.allocator);
    const buf_writer = buffer.writer(context.allocator);
    var buf_fmt = md.formatter(buf_writer);

    // Generate help from field info with metadata
    for (module_info.options_fields) |field_info| {
        // Convert underscores to dashes in field name
        var option_name_buf: [64]u8 = undefined;
        var i: usize = 0;
        for (field_info.name) |c| {
            option_name_buf[i] = if (c == '_') '-' else c;
            i += 1;
        }
        const option_name = option_name_buf[0..field_info.name.len];

        // Use description from metadata, fallback to field name
        const description = field_info.description orelse field_info.name;

        // Calculate padding to align descriptions at column 20
        // Format: "    --option, -o" or "    --option"
        // We need to pad to make total reach 20 characters (4 indent + 16 content)
        const option_length = if (field_info.short) |_|
            2 + option_name.len + 4 // "--name, -x"
        else
            2 + option_name.len; // "--name"

        const padding_needed = if (option_length < 16)
            16 - option_length
        else
            1; // At least one space

        // Build padding string
        var padding_buf: [32]u8 = undefined;
        @memset(&padding_buf, ' ');
        const padding = padding_buf[0..padding_needed];

        // Add long form first, then short form (consistent with --help, -h)
        if (field_info.short) |short_char| {
            try buf_fmt.write("    <flag>--{s}</flag>, <flag>-{c}</flag>{s} {s}\n", .{ option_name, short_char, padding, description });
        } else {
            try buf_fmt.write("    <flag>--{s}</flag>{s} {s}\n", .{ option_name, padding, description });
        }
    }

    return try buffer.toOwnedSlice(context.allocator);
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
            .color_output = std.io.tty.detectConfig(std.fs.File.stderr()) != .no_color,
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

test {
    std.testing.refAllDecls(@This());
}

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

    var io = zcli.IO.init();
    io.finalize();

    var context = zcli.Context.init(gpa.allocator(), &io);
    defer context.deinit();

    // Test handling --help flag
    try handleGlobalOption(&context, "help", true);

    const help_requested = context.getGlobalData([]const u8, "help_requested") orelse "false";
    try std.testing.expectEqualStrings("true", help_requested);
}

test "help command execution" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a temporary file to capture stderr output
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var output_file = try tmp_dir.dir.createFile("test_output.txt", .{ .read = true });
    defer output_file.close();

    // Create IO and set custom stderr for test
    var io = zcli.IO.init();
    io.stdout_writer = std.fs.File.stdout().writer(&.{});
    io.stderr_writer = output_file.writer(&.{});
    io.stdin_reader = std.fs.File.stdin().reader(&.{});

    // Create context with custom IO that writes to a file
    var context = zcli.Context{
        .allocator = allocator,
        .io = &io,
        .environment = zcli.Environment.init(allocator),
        .plugin_extensions = zcli.ContextExtensions.init(allocator),
    };
    defer context.deinit();

    // Test help command with no arguments (shows app help)
    const args = commands.help.Args{ .command = null };
    const options = commands.help.Options{};

    try commands.help.execute(args, options, &context);

    // Read back the captured output
    try output_file.seekTo(0);
    const captured_output = try output_file.readToEndAlloc(allocator, 4096);
    defer allocator.free(captured_output);

    // Validate the captured output
    try std.testing.expect(captured_output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, captured_output, "USAGE:") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured_output, "COMMANDS:") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured_output, "GLOBAL OPTIONS:") != null);
}
