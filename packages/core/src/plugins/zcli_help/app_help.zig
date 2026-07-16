//! App-level help rendering for the zcli_help plugin.
//!
//! Covers the two "navigate to a command" scenarios:
//!   - `showApp`   — general application help (`myapp --help`, bare `help`),
//!   - `showRoot`  — root-command help (app help plus the root command's own
//!                   args/options/examples).
//!
//! Command-group help (a bare group or `myapp group --help`) shares the single
//! command renderer in `command_help.zig` — a group is just a command that has
//! subcommands. The per-field tables and the ARGUMENTS/EXAMPLES/GLOBAL OPTIONS
//! sections these share with command help come from `format.zig`.

const std = @import("std");
const zcli = @import("zcli");
const md = zcli.markdown;
const format = @import("format.zig");

const app_palette = format.app_palette;

/// Show help for the entire application. `to_stdout` selects the stream:
/// explicitly-requested help (`--help`, `-h`, the `help` command) goes to
/// stdout (GNU convention, matches the version plugin); help emitted as a
/// reaction to an error (an unknown command) goes to stderr so it doesn't
/// pollute a piped stdout.
pub fn showApp(context: anytype, to_stdout: bool) !void {
    var writer = if (to_stdout) context.stdout() else context.stderr();
    var fmt = md.formatterWithPalette(writer, context.theme.capability(), app_palette);
    const app_name = context.app_name;
    const app_version = context.app_version;
    const app_description = context.app_description;

    // Header
    try fmt.write("<command>{s}</command> v{s}\n", .{ app_name, app_version });
    if (app_description.len > 0) {
        try writer.print("{s}\n", .{app_description});
    }
    try writer.writeAll("\n");

    // Usage
    try fmt.write("<header>USAGE:</header>\n", .{});
    try fmt.write("    <command>{s}</command> [GLOBAL OPTIONS] <COMMAND> [ARGS]\n\n", .{app_name});

    // Commands (navigation to children)
    try showCommandList(context, &fmt);

    // Global options
    try format.writeGlobalOptionsSection(writer, &fmt, context);

    // Footer
    try writer.writeAll("\n");
    try fmt.write("Run '<command>{s}</command> <command><COMMAND></command> <flag>--help</flag>' for more information on a command.\n", .{app_name});
}

/// Show root-command help: application help plus the root command's own
/// arguments, options, and examples (the root command can be invoked directly).
pub fn showRoot(context: anytype, to_stdout: bool) !void {
    var writer = if (to_stdout) context.stdout() else context.stderr();
    var fmt = md.formatterWithPalette(writer, context.theme.capability(), app_palette);
    const app_name = context.app_name;
    const app_version = context.app_version;
    const app_description = context.app_description;

    // Header
    try fmt.write("<command>{s}</command> v{s}\n", .{ app_name, app_version });
    try writer.print("{s}\n\n", .{app_description});

    // Usage: the root can be invoked directly, then the general form.
    try fmt.write("<header>USAGE:</header>\n", .{});
    try fmt.write("    <command>{s}</command> [OPTIONS]", .{app_name});
    if (context.command_module_info) |module_info| {
        // Only render the positionals the root's Args actually declares; an
        // empty `Args = struct {}` yields no pattern.
        if (format.generateArgsPattern(module_info, context) catch null) |pattern| {
            defer context.allocator.free(pattern);
            try writer.print(" {s}", .{pattern});
        }
    }
    try writer.writeAll("\n");
    try fmt.write("    <command>{s}</command> [GLOBAL OPTIONS] <COMMAND> [ARGS]\n\n", .{app_name});

    // Arguments (the root's own positionals)
    try format.writeArgumentsSection(writer, &fmt, context);

    // Root command's own options, before the navigation list below.
    if (context.command_module_info) |module_info| {
        if (module_info.has_options) {
            if (format.generateOptionsHelp(module_info, context) catch null) |options_help| {
                defer context.allocator.free(options_help);
                try fmt.write("<header>OPTIONS:</header>\n", .{});
                try writer.writeAll(options_help);
                try fmt.write("    <flag>--help</flag>, <flag>-h</flag>{s:<6} Show this help message\n\n", .{""});
            }
        }
    }

    // Commands (navigation to children)
    try showCommandList(context, &fmt);

    // Global options
    try format.writeGlobalOptionsSection(writer, &fmt, context);

    // Examples
    try format.writeExamplesSection(writer, &fmt, context);

    // Footer
    try writer.writeAll("\n");
    try fmt.write("Run '<command>{s}</command> <command><COMMAND></command> <flag>--help</flag>' for more information on a command.\n", .{app_name});
}

// ============================================================================
// Command-list rendering (top-level commands)
// ============================================================================

/// Helper struct for command display info with aliases
const CommandDisplayInfo = struct {
    description: ?[]const u8,
    aliases: []const []const u8,
};

/// Sort comparator: order command names alphabetically for display.
fn lessByNameStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Check if a name is in the aliases list
pub fn isAlias(name: []const u8, aliases: []const []const u8) bool {
    for (aliases) |alias| {
        if (std.mem.eql(u8, name, alias)) return true;
    }
    return false;
}

/// Show the top-level command list (used by app and root help). A command
/// group's subcommand list is rendered by the command renderer in
/// `command_help.zig` instead.
fn showCommandList(context: anytype, fmt: anytype) !void {
    try fmt.write("<header>COMMANDS:</header>\n", .{});

    const command_infos = context.getAvailableCommandInfo();
    var displayed_names: std.ArrayList([]const u8) = .empty;
    defer displayed_names.deinit(context.allocator);

    // A group marked hidden hides its whole subtree from listings: a hidden
    // `secret/index.zig` (path == {"secret"}, hidden) must also suppress a
    // visible `secret/list.zig`, which would otherwise re-insert "secret" into
    // the top-level list with no description. Collect the top-level names of all
    // hidden groups first so we can filter their descendants below.
    var hidden_groups = std.StringHashMap(void).init(context.allocator);
    defer hidden_groups.deinit();
    for (command_infos) |cmd_info| {
        if (cmd_info.hidden and cmd_info.path.len == 1) {
            try hidden_groups.put(cmd_info.path[0], {});
        }
    }

    // First pass: collect unique command names and find the best description for each
    // Use CommandDisplayInfo to also track aliases
    var command_map = std.StringHashMap(CommandDisplayInfo).init(context.allocator);
    defer command_map.deinit();

    for (command_infos) |cmd_info| {
        // Skip hidden commands
        if (cmd_info.hidden) continue;

        if (cmd_info.path.len < 1) continue;
        // Skip descendants of a hidden group (hiddenness propagates downward).
        if (hidden_groups.contains(cmd_info.path[0])) continue;
        const display_name = cmd_info.path[0];
        // Exact match if this is a top-level command (path.len == 1); a nested
        // command contributes its top-level name but no description.
        const is_exact_match = (cmd_info.path.len == 1);

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

    // Second pass: display commands in alphabetical order. The dedup map above
    // is a StringHashMap (unordered), so collect its names and sort them before
    // printing — otherwise the list comes out in hash order.
    var it = command_map.iterator();
    while (it.next()) |entry| {
        const display_name = entry.key_ptr.*;
        // Skip the help command (we append it manually last).
        if (std.mem.eql(u8, display_name, "help")) continue;
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

    // Always show the help command last.
    try fmt.write("    <command>{s:<16}</command> Show help for commands\n\n", .{"help"});
}

// ============================================================================
// Tests
// ============================================================================

test "showApp renders header, usage, the command list, and the command hint footer" {
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
    ctx.theme.caps = .{ .capability = .no_color, .is_tty = false, .color_enabled = false };

    ctx.app_name = "myapp";
    ctx.app_version = "1.2.3";
    ctx.app_description = "Does useful things";
    ctx.plugin_command_info = &.{
        .{ .path = &.{"build"}, .description = "Build the project" },
        .{ .path = &.{"deploy"}, .description = "Deploy it" },
    };

    try showApp(&ctx, true);
    try ctx.stdout().flush();
    const out = aw.written();

    // Header (name + version + description), the general usage form, the command
    // list (with the always-appended `help`), and the "more information" footer.
    try std.testing.expect(std.mem.startsWith(u8, out, "myapp v1.2.3\nDoes useful things\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "USAGE:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "myapp [GLOBAL OPTIONS] <COMMAND> [ARGS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "COMMANDS:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "build") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "deploy") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "help") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "for more information on a command.\n"));
}

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
    try showCommandList(&ctx, &fmt);
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

test "showCommandList: a hidden group suppresses its visible children" {
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

    // `secret` is a hidden group (its index is hidden) but has a visible child
    // `secret list`. Hiddenness must propagate: neither `secret` nor its child
    // may appear in the top-level command list. `apple` stays visible.
    ctx.plugin_command_info = &.{
        .{ .path = &.{"apple"}, .description = "Apple command" },
        .{ .path = &.{"secret"}, .description = "Secret group", .hidden = true },
        .{ .path = &.{ "secret", "list" }, .description = "List secrets" },
    };

    var fmt = md.formatterWithPalette(ctx.stdout(), ctx.theme.capability(), app_palette);
    try showCommandList(&ctx, &fmt);
    try ctx.stdout().flush();

    const out = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "apple") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "secret") == null);
}

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
