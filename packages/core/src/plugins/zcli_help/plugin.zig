const std = @import("std");
const zcli = @import("zcli");
const md = zcli.markdown;

// The app's palette, resolved at comptime from the root `zcli_theme`
// declaration, so help text compiles to the app's themed escape sequences.
const app_palette = zcli.appTheme().palette;

/// zcli-help Plugin
///
/// Provides help functionality for CLI applications using the lifecycle hook plugin system.
/// Unique identifier for this plugin (required for type-safe context data)
pub const plugin_id = "zcli_help";

/// Help wins over --version when both are present: the plugin pipeline sorts
/// plugins by priority (higher first) and runs their hooks in that order, so a
/// value above the version plugin's 90 makes our preExecute render help first.
pub const priority = 100;

// Width for command/option name columns (content width, excluding indent)
const NAME_COLUMN_WIDTH: usize = 16;

// Helper struct for collecting command information
const CommandListEntry = struct {
    name: []const u8,
    description: ?[]const u8,
    is_group: bool,
};

// Helper struct for command display info with aliases
const CommandDisplayInfo = struct {
    description: ?[]const u8,
    aliases: []const []const u8,
};

/// Plugin-specific context data (type-safe, stored in computed Context)
pub const ContextData = struct {
    help_requested: bool = false,
};

/// Public API: Check if help was requested
pub fn isHelpRequested(context: anytype) bool {
    return context.plugins.zcli_help.help_requested;
}

/// Global options provided by this plugin
pub const global_options = [_]zcli.GlobalOption{
    zcli.option("help", bool, .{ .short = 'h', .default = false, .description = "Show help message" }),
};

/// Handle global options - specifically the --help flag
pub fn handleGlobalOption(
    context: anytype,
    option_name: []const u8,
    value: anytype,
) !void {
    // The registry dispatches --help with its declared bool type, so `value` is
    // always a bool here — no runtime type guard needed.
    if (std.mem.eql(u8, option_name, "help") and value) {
        context.plugins.zcli_help.help_requested = true;
    }
}

/// Rewrite `myapp help <cmd...>` into `myapp <cmd...>` with help requested, so
/// the target command resolves normally and populates the context (meta,
/// module_info) that the help renderer reads. Without this, `help <cmd>` would
/// resolve the `help` command itself and describe *it* instead of the target.
///
/// Multi-word paths work for free — `help remote add` drops the leading `help`
/// and lets normal resolution match `remote add`. Bare `help` (or `help` with a
/// trailing option like `help --foo`) is left untouched: it routes to the help
/// command below, which shows app help.
pub fn transformArgs(
    context: anytype,
    args: []const []const u8,
) !zcli.TransformResult {
    if (args.len > 1 and
        std.mem.eql(u8, args[0], "help") and
        !std.mem.startsWith(u8, args[1], "-"))
    {
        context.plugins.zcli_help.help_requested = true;
        return .{ .args = args[1..] };
    }
    return .{ .args = args };
}

/// Pre-execute hook to show help if requested
pub fn preExecute(
    context: anytype,
    args: zcli.ParsedArgs,
) !?zcli.ParsedArgs {
    if (context.plugins.zcli_help.help_requested) {
        // If command_path is empty, show app help. The root command resolves
        // to the "root" pseudo-path and gets root help (app help + root's own
        // options). Otherwise the resolved command's context drives the command
        // help — payload-free, everything renders from context.command_meta /
        // command_module_info.
        // Explicit help request → stdout.
        if (context.command_path.len == 0) {
            try showAppHelp(context, true);
        } else if (context.command_path.len == 1 and std.mem.eql(u8, context.command_path[0], "root")) {
            try showHelp(context, .root, true);
        } else {
            try showHelp(context, .command, true);
        }

        // Return null to stop execution
        return null;
    }

    // Continue normal execution
    return args;
}

/// Error hook to handle command group help
pub fn onError(
    context: anytype,
    err: anyerror,
) !bool {
    if (err == error.CommandNotFound) {
        // If no command was provided at all, show app help. This is an error
        // reaction (CommandNotFound), so it goes to stderr.
        if (context.command_path.len == 0) {
            try showAppHelp(context, false);
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
                    // Skip hidden commands
                    if (cmd_info.hidden) continue;

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

/// Unified help display function that handles all help scenarios.
///
/// `to_stdout` selects the stream: explicitly-requested help (`--help`, `-h`,
/// the `help` command) goes to stdout (GNU convention, matches the version
/// plugin); help emitted as a reaction to an error (a bare command group, an
/// unknown command) goes to stderr so it doesn't pollute a piped stdout.
fn showHelp(context: anytype, help_type: HelpType, to_stdout: bool) !void {
    var writer = if (to_stdout) context.stdout() else context.stderr();
    var fmt = md.formatterWithPalette(writer, context.theme.capability(), app_palette);
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
        .command => {
            // Lead with the description (like the root help), then USAGE below.
            // No "Help for command:" label — the usage line already names it.
            if (context.command_meta) |meta| {
                if (meta.description) |desc| {
                    try writer.print("{s}\n\n", .{desc});
                }
            }
        },
    }

    // Show usage
    try fmt.write("<header>USAGE:</header>\n", .{});
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
                    try fmt.write("<header>ARGUMENTS:</header>\n", .{});
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
                    try fmt.write("<header>OPTIONS:</header>\n", .{});
                    try writer.writeAll(options_help);
                    try fmt.write("    <flag>--help</flag>, <flag>-h</flag>{s:<6} Show this help message\n\n", .{""});
                }
            }
        }
    }

    // Show options (for non-root commands) — the command's own contract comes
    // before navigation to any children, so OPTIONS precedes the subcommand
    // list below for a command that is both executable and a group.
    if (help_type == .command) {
        try fmt.write("<header>OPTIONS:</header>\n", .{});
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

    // Show commands/subcommands (last: navigation to children)
    switch (help_type) {
        .app, .root => {
            try showCommandList(context, &fmt, .top_level);
        },
        .command_group => |group_name| {
            try showCommandList(context, &fmt, .{ .subcommands_of = group_name });
        },
        .command => {
            // Show subcommands if any
            const had_subcommands = try showSubcommands(context, &fmt);
            // For a command that is both executable and a group, point at its
            // children — mirrors the group/app "run --help for more" footer.
            if (had_subcommands) {
                const cmd_path = try std.mem.join(context.allocator, " ", context.command_path);
                defer context.allocator.free(cmd_path);
                try fmt.write("Run '<command>{s}</command> <command>{s}</command> <subcommand> <flag>--help</flag>' for more information on a subcommand.\n\n", .{ app_name, cmd_path });
            }
        },
    }

    // Show global options (for app and root help)
    if (help_type == .app or help_type == .root) {
        const global_opts = context.getGlobalOptions();
        if (global_opts.len > 0) {
            try fmt.write("\n<header>GLOBAL OPTIONS:</header>\n", .{});
            for (global_opts) |opt| {
                if (opt.short) |short| {
                    try fmt.write("    <flag>-{c}</flag>, <flag>--{s}</flag>", .{ short, opt.name });
                    // Pad to align descriptions
                    const used = 8 + opt.name.len; // "-x, --name"
                    if (used < NAME_COLUMN_WIDTH) {
                        var i: usize = 0;
                        while (i < NAME_COLUMN_WIDTH - used) : (i += 1) {
                            try writer.writeByte(' ');
                        }
                    } else {
                        try writer.writeByte(' ');
                    }
                } else {
                    try fmt.write("    <flag>--{s}</flag>", .{opt.name});
                    const used = 4 + opt.name.len;
                    if (used < NAME_COLUMN_WIDTH) {
                        var i: usize = 0;
                        while (i < NAME_COLUMN_WIDTH - used) : (i += 1) {
                            try writer.writeByte(' ');
                        }
                    } else {
                        try writer.writeByte(' ');
                    }
                }
                try writer.print(" {s}\n", .{opt.description orelse ""});
            }
        }
    }

    // Show examples if available
    if ((help_type == .command or help_type == .root) and context.command_meta != null) {
        if (context.command_meta.?.examples) |examples| {
            try fmt.write("\n<header>EXAMPLES:</header>\n", .{});
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
    command, // Specific command help (renders from the resolved command's context)
};

/// List type for showCommandList
const CommandListType = union(enum) {
    top_level, // Show top-level commands
    subcommands_of: []const u8, // Show subcommands of a specific command
};

/// Sort comparator: order command names alphabetically for display.
fn lessByNameStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Check if a name is in the aliases list
fn isAlias(name: []const u8, aliases: []const []const u8) bool {
    for (aliases) |alias| {
        if (std.mem.eql(u8, name, alias)) return true;
    }
    return false;
}

/// Show a list of commands (used by unified help function)
fn showCommandList(context: anytype, fmt: anytype, list_type: CommandListType) !void {
    if (list_type == .top_level) {
        try fmt.write("<header>COMMANDS:</header>\n", .{});
    } else {
        try fmt.write("<header>SUBCOMMANDS:</header>\n", .{});
    }

    const command_infos = context.getAvailableCommandInfo();
    var displayed_names: std.ArrayList([]const u8) = .empty;
    defer displayed_names.deinit(context.allocator);

    // First pass: collect unique command names and find the best description for each
    // Use CommandDisplayInfo to also track aliases
    var command_map = std.StringHashMap(CommandDisplayInfo).init(context.allocator);
    defer command_map.deinit();

    for (command_infos) |cmd_info| {
        // Skip hidden commands
        if (cmd_info.hidden) continue;

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
            // Skip alias entries - the display_name is in the aliases list
            // This means this entry is an alias, not the primary command
            if (isAlias(display_name, cmd_info.aliases)) continue;

            const existing = command_map.get(display_name);

            // Add or update the command in the map
            // Only use descriptions from exact matches (commands at the correct depth)
            if (existing == null) {
                // First time seeing this command
                // Only add description if it's an exact match
                if (is_exact_match) {
                    try command_map.put(display_name, .{
                        .description = cmd_info.description,
                        .aliases = cmd_info.aliases,
                    });
                } else {
                    // Not an exact match, add with no description
                    try command_map.put(display_name, .{
                        .description = null,
                        .aliases = &.{},
                    });
                }
            } else if (is_exact_match and cmd_info.description != null) {
                // We have an exact match with a description, prefer it over previous entries
                try command_map.put(display_name, .{
                    .description = cmd_info.description,
                    .aliases = cmd_info.aliases,
                });
            }
            // Otherwise keep existing entry
        }
    }

    // Second pass: display commands in alphabetical order. The dedup map above
    // is a StringHashMap (unordered), so collect its names and sort them before
    // printing — otherwise the list comes out in hash order.
    var it = command_map.iterator();
    while (it.next()) |entry| {
        const display_name = entry.key_ptr.*;
        // Skip help command for top-level (we'll add it manually)
        if (list_type == .top_level and std.mem.eql(u8, display_name, "help")) continue;
        try displayed_names.append(context.allocator, display_name);
    }
    std.mem.sort([]const u8, displayed_names.items, {}, lessByNameStr);

    for (displayed_names.items) |display_name| {
        const info = command_map.get(display_name).?;

        if (info.description) |desc| {
            if (info.aliases.len > 0) {
                // Build alias string for interpolation
                var alias_buf: std.ArrayList(u8) = .empty;
                defer alias_buf.deinit(context.allocator);
                for (info.aliases, 0..) |alias, i| {
                    if (i > 0) try alias_buf.appendSlice(context.allocator, ", ");
                    try alias_buf.appendSlice(context.allocator, alias);
                }
                try fmt.write("    <command>{s:<16}</command> {s} ~(aliases: {s})~\n", .{ display_name, desc, alias_buf.items });
            } else {
                try fmt.write("    <command>{s:<16}</command> {s}\n", .{ display_name, desc });
            }
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
fn showCommandGroupHelp(context: anytype, group_name: []const u8) !void {
    // Reached only from onError (a bare command group) → stderr.
    try showHelp(context, .{ .command_group = group_name }, false);
}

/// Commands provided by this plugin
pub const commands = struct {
    /// The help command itself. `help <cmd...>` is handled earlier by
    /// transformArgs (which rewrites it to the target command with help
    /// requested), so this command only ever runs for a bare `help` and shows
    /// application help.
    pub const help = struct {
        pub const Args = struct {};

        pub const Options = struct {};

        pub const meta = .{
            .description = "Show help for commands",
        };

        pub fn execute(args: Args, options: Options, context: anytype) !void {
            _ = args;
            _ = options;
            // Explicitly invoked → stdout.
            try showAppHelp(context, true);
        }
    };
};

/// Show help for the entire application. `to_stdout` follows the same
/// explicit-vs-error stream rule as showHelp.
fn showAppHelp(context: anytype, to_stdout: bool) !void {
    try showHelp(context, .app, to_stdout);
}

/// Generate usage string based on command structure
fn generateUsage(context: anytype) ![]const u8 {
    // Build a markdown-formatted usage string using the formatter
    var aw: std.Io.Writer.Allocating = .init(context.allocator);
    errdefer aw.deinit();
    const buf_writer = &aw.writer;
    var fmt = md.formatterWithPalette(buf_writer, context.theme.capability(), app_palette);

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
            // Required options are shown explicitly in the usage line (e.g.
            // `--region <value>`); everything else folds into `[OPTIONS]`. An
            // empty Options struct keeps `[OPTIONS]` (the command still takes
            // --help); only an all-required set drops it — nothing is left over.
            var has_optional_options = true;
            if (context.command_module_info) |module_info| {
                if (module_info.options_fields.len > 0) {
                    has_optional_options = false;
                    for (module_info.options_fields) |field_info| {
                        if (field_info.is_required) {
                            try buf_writer.writeAll(" --");
                            for (field_info.name) |c| try buf_writer.writeByte(if (c == '_') '-' else c);
                            try buf_writer.writeAll(" <value>");
                        } else {
                            has_optional_options = true;
                        }
                    }
                }
            }
            if (has_optional_options) {
                try buf_writer.writeAll(" [OPTIONS]");
            }
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

    var al = aw.toArrayList();
    return try al.toOwnedSlice(context.allocator);
}

/// Show available subcommands for the current command. Returns whether any were
/// displayed, so the caller can render a follow-up hint only when they exist.
fn showSubcommands(context: anytype, fmt: anytype) !bool {
    const command_infos = context.getAvailableCommandInfo();
    var displayed_names: std.ArrayList([]const u8) = .empty;
    defer displayed_names.deinit(context.allocator);

    var has_commands = false;

    for (command_infos) |cmd_info| {
        // Skip hidden commands
        if (cmd_info.hidden) continue;

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
                    try fmt.write("<header>COMMANDS:</header>\n", .{});
                    has_commands = true;
                }

                if (cmd_info.description) |desc| {
                    try fmt.write("    <command>{s:<16}</command> {s}\n", .{ display_name, desc });
                } else {
                    try fmt.write("    <command>{s}</command>\n", .{display_name});
                }
            }
        }
    }

    if (has_commands) {
        try fmt.write("\n", .{});
    }
    return has_commands;
}

/// Generate args pattern from command module info (e.g., "IMAGE [COMMAND] [ARG...]")
/// Returns null if there are no args to display
fn generateArgsPattern(module_info: zcli.CommandModuleInfo, context: anytype) !?[]u8 {
    if (!module_info.has_args or module_info.args_fields.len == 0) return null;

    var aw: std.Io.Writer.Allocating = .init(context.allocator);
    errdefer aw.deinit();
    const writer = &aw.writer;

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

    var al = aw.toArrayList();
    return try al.toOwnedSlice(context.allocator);
}

/// Generate args help text from command module info
/// Returns null if there are no args to display
fn generateArgsHelp(module_info: zcli.CommandModuleInfo, context: anytype) !?[]u8 {
    if (!module_info.has_args or module_info.args_fields.len == 0) return null;

    var aw: std.Io.Writer.Allocating = .init(context.allocator);
    errdefer aw.deinit();
    const buf_writer = &aw.writer;
    var buf_fmt = md.formatterWithPalette(buf_writer, context.theme.capability(), app_palette);

    // Each row: name column, then the description (from meta.args), then the
    // valid choices for an enum-typed arg — `one of: dev, staging, prod`. When a
    // field has neither, fall back to echoing the name so the column isn't bare.
    for (module_info.args_fields) |field_info| {
        try buf_fmt.write("    <value>{s:<16}</value> ", .{field_info.name});
        var wrote_detail = false;
        if (field_info.description) |desc| {
            try buf_fmt.write("{s}", .{desc});
            wrote_detail = true;
        }
        if (field_info.enum_values) |values| {
            try writeChoices(&buf_fmt, values, wrote_detail);
            wrote_detail = true;
        }
        if (!wrote_detail) {
            try buf_fmt.write("{s}", .{field_info.name});
        }
        try buf_fmt.write("\n", .{});
    }

    var al = aw.toArrayList();
    return try al.toOwnedSlice(context.allocator);
}

/// Append the enum choice list — `(one of: a, b, c)` — to a help row. When
/// `leading_space` the list is separated from preceding text by a space.
fn writeChoices(fmt: anytype, values: []const []const u8, leading_space: bool) !void {
    if (leading_space) try fmt.write(" ", .{});
    try fmt.write("(one of: ", .{});
    for (values, 0..) |value, i| {
        if (i > 0) try fmt.write(", ", .{});
        try fmt.write("{s}", .{value});
    }
    try fmt.write(")", .{});
}

/// Generate options help text from command module info
/// Returns null if there are no options to display
fn generateOptionsHelp(module_info: zcli.CommandModuleInfo, context: anytype) !?[]u8 {
    if (!module_info.has_options or module_info.options_fields.len == 0) return null;

    var aw: std.Io.Writer.Allocating = .init(context.allocator);
    errdefer aw.deinit();
    const buf_writer = &aw.writer;
    var buf_fmt = md.formatterWithPalette(buf_writer, context.theme.capability(), app_palette);

    // Generate help from field info with metadata
    for (module_info.options_fields) |field_info| {
        // Convert underscores to dashes in field name. Clamp to the buffer so a
        // pathologically long field name truncates instead of overflowing the
        // stack (mirrors generateArgsPattern's @min guard).
        var option_name_buf: [64]u8 = undefined;
        const dashed_len = @min(field_info.name.len, option_name_buf.len);
        for (field_info.name[0..dashed_len], 0..) |c, i| {
            option_name_buf[i] = if (c == '_') '-' else c;
        }
        const dashed = option_name_buf[0..dashed_len];

        // A boolean flag that defaults to true is turned off with its `--no-`
        // negation, so that (long-form only, no short) is the spelling we show —
        // the positive form would just re-assert the default. Other flags render
        // their positive name and short as usual.
        const negated = std.mem.eql(u8, field_info.type_name, "bool") and
            field_info.default_value != null and
            std.mem.eql(u8, field_info.default_value.?, "true");
        var negated_name_buf: [67]u8 = undefined;
        const option_name = if (negated) blk: {
            @memcpy(negated_name_buf[0..3], "no-");
            @memcpy(negated_name_buf[3..][0..dashed.len], dashed);
            break :blk negated_name_buf[0 .. 3 + dashed.len];
        } else dashed;
        const short = if (negated) null else field_info.short;

        // Use description from metadata, fallback to field name
        const description = field_info.description orelse field_info.name;

        // Calculate padding to align descriptions
        // Format: "    --option, -x" or "    --option"
        const option_length = if (short) |_|
            2 + option_name.len + 4 // "--name, -x"
        else
            2 + option_name.len; // "--name"

        const padding_needed = if (option_length < NAME_COLUMN_WIDTH)
            NAME_COLUMN_WIDTH - option_length
        else
            1; // At least one space

        // Build padding string
        var padding_buf: [32]u8 = undefined;
        @memset(&padding_buf, ' ');
        const padding = padding_buf[0..padding_needed];

        // Add long form first, then short form (consistent with --help, -h),
        // then the description, the enum choices (if any), and a `(required)`
        // marker so a defaultless option reads as mandatory at a glance.
        if (short) |short_char| {
            try buf_fmt.write("    <flag>--{s}</flag>, <flag>-{c}</flag>{s} {s}", .{ option_name, short_char, padding, description });
        } else {
            try buf_fmt.write("    <flag>--{s}</flag>{s} {s}", .{ option_name, padding, description });
        }
        if (field_info.enum_values) |values| {
            try writeChoices(&buf_fmt, values, description.len > 0);
        }
        if (field_info.is_required) {
            try buf_fmt.write(" (required)", .{});
        }
        // Array-typed options accept several values — via `--opt a,b` or by
        // repeating the flag — so mark them as such at a glance.
        if (field_info.is_array) {
            try buf_fmt.write(" (repeatable)", .{});
        }
        if (field_info.requires) |deps| {
            try buf_fmt.write(" (requires ", .{});
            for (deps, 0..) |dep, di| {
                if (di > 0) try buf_fmt.write(", ", .{});
                try writeDashedFlag(&buf_fmt, dep);
            }
            try buf_fmt.write(")", .{});
        }
        try buf_fmt.write("\n", .{});
    }

    // Mutually-exclusive sets, listed once each under the option lines.
    for (module_info.exclusive) |set| {
        try buf_fmt.write("    Mutually exclusive: ", .{});
        for (set, 0..) |member, mi| {
            if (mi > 0) try buf_fmt.write(", ", .{});
            try writeDashedFlag(&buf_fmt, member);
        }
        try buf_fmt.write("\n", .{});
    }

    var al = aw.toArrayList();
    return try al.toOwnedSlice(context.allocator);
}

/// Write an option field name as its `--dashed-flag`, converting underscores to
/// dashes (matching how option names render above).
fn writeDashedFlag(buf_fmt: anytype, field_name: []const u8) !void {
    var name_buf: [64]u8 = undefined;
    if (field_name.len > name_buf.len) {
        try buf_fmt.write("--{s}", .{field_name});
        return;
    }
    for (field_name, 0..) |c, i| name_buf[i] = if (c == '_') '-' else c;
    try buf_fmt.write("<flag>--{s}</flag>", .{name_buf[0..field_name.len]});
}

test {
    std.testing.refAllDecls(@This());
}

// Tests
test "help plugin structure" {
    try std.testing.expect(@hasDecl(@This(), "global_options"));
    try std.testing.expect(@hasDecl(@This(), "handleGlobalOption"));
    try std.testing.expect(@hasDecl(@This(), "preExecute"));
    try std.testing.expect(@hasDecl(@This(), "commands"));
    try std.testing.expect(@hasDecl(@This(), "ContextData"));
    try std.testing.expect(@hasDecl(@This(), "isHelpRequested"));
}

test "help never renders auto-generated --no- negation flags" {
    const allocator = std.testing.allocator;

    const Ctx = zcli.TestContext(&.{});
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    const environ = std.process.Environ.Map.init(allocator);
    var ctx = Ctx.init(allocator, std.testing.io, &stdio, &environ);
    defer ctx.deinit();

    // `verbose` defaults false → help shows the positive `--verbose` (its hidden
    // `--no-verbose` never appears). `color` defaults true → help shows the useful
    // `--no-color` negation instead (long-form only, no short), never the redundant
    // positive `--color`.
    const module_info = zcli.CommandModuleInfo{
        .has_options = true,
        .options_fields = &.{
            .{ .name = "verbose", .is_optional = false, .is_array = false, .short = 'v', .type_name = "bool", .default_value = "false", .description = "Verbose output" },
            .{ .name = "color", .is_optional = false, .is_array = false, .short = 'c', .type_name = "bool", .default_value = "true", .description = "Disable color" },
        },
    };

    const help = (try generateOptionsHelp(module_info, &ctx)).?;
    defer allocator.free(help);

    // default-false bool: positive shown, negation hidden.
    try std.testing.expect(std.mem.indexOf(u8, help, "--verbose") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-verbose") == null);
    // default-true bool: negation shown, positive hidden.
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-color") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--color") == null);
}

test "help renders requires markers and mutually-exclusive sets" {
    const allocator = std.testing.allocator;

    const Ctx = zcli.TestContext(&.{});
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    const environ = std.process.Environ.Map.init(allocator);
    var ctx = Ctx.init(allocator, std.testing.io, &stdio, &environ);
    defer ctx.deinit();

    const module_info = zcli.CommandModuleInfo{
        .has_options = true,
        .options_fields = &.{
            .{ .name = "json", .is_optional = false, .is_array = false, .type_name = "bool", .default_value = "false" },
            .{ .name = "yaml", .is_optional = false, .is_array = false, .type_name = "bool", .default_value = "false" },
            .{ .name = "output", .is_optional = true, .is_array = false, .type_name = "?[]const u8" },
            .{ .name = "output_format", .is_optional = true, .is_array = false, .type_name = "?[]const u8", .requires = &.{"output"} },
        },
        .exclusive = &.{&.{ "json", "yaml" }},
    };

    const help = (try generateOptionsHelp(module_info, &ctx)).?;
    defer allocator.free(help);

    // The dependent option shows its requirement (dash-converted).
    try std.testing.expect(std.mem.indexOf(u8, help, "requires ") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--output") != null);
    // The exclusive set is listed once.
    try std.testing.expect(std.mem.indexOf(u8, help, "Mutually exclusive:") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--json") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--yaml") != null);
}

test "help marks array options as repeatable but not scalars" {
    const allocator = std.testing.allocator;

    const Ctx = zcli.TestContext(&.{});
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    const environ = std.process.Environ.Map.init(allocator);
    var ctx = Ctx.init(allocator, std.testing.io, &stdio, &environ);
    defer ctx.deinit();

    const module_info = zcli.CommandModuleInfo{
        .has_options = true,
        .options_fields = &.{
            .{ .name = "tags", .is_optional = false, .is_array = true, .type_name = "[][]const u8", .description = "Tags to apply" },
            .{ .name = "output", .is_optional = true, .is_array = false, .type_name = "?[]const u8", .description = "Output path" },
        },
    };

    const help = (try generateOptionsHelp(module_info, &ctx)).?;
    defer allocator.free(help);

    // The array option carries the marker; the scalar option does not (there is
    // exactly one occurrence of "(repeatable)" in the whole block).
    try std.testing.expect(std.mem.indexOf(u8, help, "--tags") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "(repeatable)") != null);
    try std.testing.expect(std.mem.lastIndexOf(u8, help, "(repeatable)").? == std.mem.indexOf(u8, help, "(repeatable)").?);
}

test "help option rendering does not overflow on a >64-char field name" {
    const allocator = std.testing.allocator;

    const Ctx = zcli.TestContext(&.{});
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    const environ = std.process.Environ.Map.init(allocator);
    var ctx = Ctx.init(allocator, std.testing.io, &stdio, &environ);
    defer ctx.deinit();

    // A field name longer than the 64-byte dashed-name buffer must truncate,
    // not corrupt the stack. (70 chars.)
    const long_name = "a_very_" ++ "long_" ** 12 ++ "field";
    comptime std.debug.assert(long_name.len > 64);

    const module_info = zcli.CommandModuleInfo{
        .has_options = true,
        .options_fields = &.{
            .{ .name = long_name, .is_optional = true, .is_array = false, .type_name = "?[]const u8", .description = "Long" },
        },
    };

    const help = (try generateOptionsHelp(module_info, &ctx)).?;
    defer allocator.free(help);

    // The truncated (64-char, underscores→dashes) prefix is present; the render
    // completed without a panic.
    try std.testing.expect(std.mem.indexOf(u8, help, "--a-very-long-") != null);
}

// ============================================================================
// showCommandList: dedup, alphabetical sort, alias rendering
// ============================================================================

test "showCommandList: dedups, sorts alphabetically, and renders aliases" {
    const allocator = std.testing.allocator;

    const Ctx = zcli.TestContext(&.{});
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    // Capture the formatter's output via the stdout override.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    stdio.stdout_override = &aw.writer;

    const environ = std.process.Environ.Map.init(allocator);
    var ctx = Ctx.init(allocator, std.testing.io, &stdio, &environ);
    defer ctx.deinit();

    // Two top-level commands plus a nested one under `list`. `list` has an
    // alias `ls`, which should render as `(aliases: ls)` and be deduped away as
    // its own entry. `zebra` comes before `apple` in source but must sort after.
    ctx.plugin_command_info = &.{
        .{ .path = &.{"zebra"}, .description = "Zebra command" },
        .{ .path = &.{"apple"}, .description = "Apple command" },
        .{ .path = &.{"list"}, .description = "List things", .aliases = &.{"ls"} },
        .{ .path = &.{ "list", "sub" }, .description = "A subcommand" },
    };

    var fmt = md.formatterWithPalette(ctx.stdout(), ctx.theme.capability(), app_palette);
    try showCommandList(&ctx, &fmt, .top_level);
    try ctx.stdout().flush();

    const out = aw.written();

    // Alphabetical order: apple before list before zebra.
    const i_apple = std.mem.indexOf(u8, out, "apple").?;
    const i_list = std.mem.indexOf(u8, out, "list").?;
    const i_zebra = std.mem.indexOf(u8, out, "zebra").?;
    try std.testing.expect(i_apple < i_list);
    try std.testing.expect(i_list < i_zebra);

    // Alias rendered on the primary, not as its own command row.
    try std.testing.expect(std.mem.indexOf(u8, out, "aliases: ls") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\n    ls") == null);

    // The nested subcommand does not leak into the top-level list.
    try std.testing.expect(std.mem.indexOf(u8, out, "sub") == null);
}

// ============================================================================
// showHelp(.command): section ordering + options-less rendering
// ============================================================================

/// Render `.command` help (to stdout) and return the captured buffer.
fn renderCommandHelp(ctx: anytype, aw: *std.Io.Writer.Allocating) ![]const u8 {
    try showHelp(ctx, .command, true);
    try ctx.stdout().flush();
    return aw.written();
}

test "showHelp .command orders sections ARGUMENTS -> OPTIONS -> COMMANDS for an exec+group command" {
    const allocator = std.testing.allocator;

    const Ctx = zcli.TestContext(&.{});
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    stdio.stdout_override = &aw.writer;

    const environ = std.process.Environ.Map.init(allocator);
    var ctx = Ctx.init(allocator, std.testing.io, &stdio, &environ);
    defer ctx.deinit();

    // `server` is both executable (has its own args + options) AND a group (a
    // `server status` subcommand exists) — the exact case whose ordering this
    // fix pins down.
    ctx.app_name = "myapp";
    ctx.command_path = &.{"server"};
    ctx.command_module_info = .{
        .has_args = true,
        .args_fields = &.{
            .{ .name = "target", .is_optional = false, .is_array = false, .type_name = "[]const u8", .description = "The target" },
        },
        .has_options = true,
        .options_fields = &.{
            .{ .name = "force", .is_optional = false, .is_array = false, .type_name = "bool", .default_value = "false", .description = "Force it" },
        },
    };
    ctx.plugin_command_info = &.{
        .{ .path = &.{"server"}, .description = "Manage the server" },
        .{ .path = &.{ "server", "status" }, .description = "Show status" },
    };

    const out = try renderCommandHelp(&ctx, &aw);

    const i_args = std.mem.indexOf(u8, out, "ARGUMENTS:").?;
    const i_opts = std.mem.indexOf(u8, out, "OPTIONS:").?;
    const i_cmds = std.mem.indexOf(u8, out, "COMMANDS:").?;
    // The command's own contract first (arguments, then options), navigation to
    // children last.
    try std.testing.expect(i_args < i_opts);
    try std.testing.expect(i_opts < i_cmds);

    // The subcommand and the follow-up hint both render under COMMANDS.
    try std.testing.expect(std.mem.indexOf(u8, out, "status") != null);
    const i_hint = std.mem.indexOf(u8, out, "for more information on a subcommand").?;
    try std.testing.expect(i_hint > i_cmds);
}

test "showHelp .command renders a clean OPTIONS block for an options-less command" {
    const allocator = std.testing.allocator;

    const Ctx = zcli.TestContext(&.{});
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    stdio.stdout_override = &aw.writer;

    const environ = std.process.Environ.Map.init(allocator);
    var ctx = Ctx.init(allocator, std.testing.io, &stdio, &environ);
    defer ctx.deinit();

    // A leaf command with `Options = struct {}` and no subcommands: the OPTIONS
    // block still lists the implicit --help (it IS an option; every CLI shows
    // -h). Decision (a) from the audit — locked here so the single-line OPTIONS
    // block is intentional, not accidental.
    ctx.app_name = "myapp";
    ctx.command_path = &.{"noop"};
    ctx.command_module_info = .{ .has_args = false, .has_options = false };
    ctx.plugin_command_info = &.{
        .{ .path = &.{"noop"}, .description = "Does nothing" },
    };

    const out = try renderCommandHelp(&ctx, &aw);

    // The OPTIONS header is present and immediately followed by the --help line
    // (no blank line between them, no stray trailing blanks — the block is one
    // header + one entry).
    const opts_at = std.mem.indexOf(u8, out, "OPTIONS:\n").?;
    const after = out[opts_at + "OPTIONS:\n".len ..];
    try std.testing.expect(std.mem.startsWith(u8, std.mem.trimLeft(u8, after, " "), "--help"));
    // With no declared options and no subcommands, --help is the only OPTIONS
    // entry and no COMMANDS section renders.
    try std.testing.expect(std.mem.indexOf(u8, out, "--help") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "COMMANDS:") == null);
}

// ============================================================================
// generateUsage: required-option folding + subcommand detection
// ============================================================================

test "generateUsage: folds optional options, shows required ones explicitly" {
    const allocator = std.testing.allocator;

    const Ctx = zcli.TestContext(&.{});
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    const environ = std.process.Environ.Map.init(allocator);
    var ctx = Ctx.init(allocator, std.testing.io, &stdio, &environ);
    defer ctx.deinit();

    ctx.app_name = "myapp";
    ctx.command_path = &.{"deploy"};
    ctx.command_module_info = .{
        .has_options = true,
        .options_fields = &.{
            .{ .name = "region", .is_optional = false, .is_array = false, .type_name = "[]const u8", .is_required = true },
            .{ .name = "verbose", .is_optional = false, .is_array = false, .type_name = "bool", .default_value = "false" },
        },
    };

    const usage = try generateUsage(&ctx);
    defer allocator.free(usage);

    // Required option is spelled out (dash-converted); the rest fold into
    // [OPTIONS].
    try std.testing.expect(std.mem.indexOf(u8, usage, "--region <value>") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "[OPTIONS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "myapp") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "deploy") != null);
}

test "generateUsage: a command with subcommands shows COMMAND, not its options" {
    const allocator = std.testing.allocator;

    const Ctx = zcli.TestContext(&.{});
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    const environ = std.process.Environ.Map.init(allocator);
    var ctx = Ctx.init(allocator, std.testing.io, &stdio, &environ);
    defer ctx.deinit();

    ctx.app_name = "myapp";
    ctx.command_path = &.{"remote"};
    // `remote add` exists → `remote` is a group.
    ctx.available_commands = &.{
        &.{ "remote", "add" },
    };
    ctx.command_module_info = .{ .has_options = false, .has_args = false };

    const usage = try generateUsage(&ctx);
    defer allocator.free(usage);

    try std.testing.expect(std.mem.indexOf(u8, usage, "remote") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "COMMAND") != null);
}

// Note: Integration tests for handleGlobalOption and help command execution
// require a compiled registry with this plugin registered. See integration tests.

// ============================================================================
// Alias Helper Tests
// ============================================================================

test "isAlias: name in aliases list" {
    const aliases = &[_][]const u8{ "list", "ps", "l" };
    try std.testing.expect(isAlias("list", aliases));
    try std.testing.expect(isAlias("ps", aliases));
    try std.testing.expect(isAlias("l", aliases));
}

test "isAlias: name not in aliases list" {
    const aliases = &[_][]const u8{ "list", "ps", "l" };
    try std.testing.expect(!isAlias("ls", aliases));
    try std.testing.expect(!isAlias("show", aliases));
}

test "isAlias: empty aliases list" {
    const aliases: []const []const u8 = &.{};
    try std.testing.expect(!isAlias("anything", aliases));
}
