//! Command-level help rendering for the zcli_help plugin.
//!
//! Renders help for a single resolved command (`myapp deploy --help`): its
//! description, synopsis, ARGUMENTS/OPTIONS tables, any subcommands (for a
//! command that is both executable and a group), and examples. App-, root-, and
//! group-level help live in `app_help.zig`; the shared per-field tables and the
//! ARGUMENTS/EXAMPLES sections come from `format.zig`.

const std = @import("std");
const zcli = @import("zcli");
const md = zcli.markdown;
const format = @import("format.zig");

const app_palette = format.app_palette;

/// Show help for a specific resolved command. `to_stdout` follows the same
/// explicit-vs-error stream rule as the app-level renderers.
pub fn showCommand(context: anytype, to_stdout: bool) !void {
    var writer = if (to_stdout) context.stdout() else context.stderr();
    var fmt = md.formatterWithPalette(writer, context.theme.capability(), app_palette);
    const app_name = context.app_name;

    // Lead with the description (like the root help), then USAGE below. No
    // "Help for command:" label — the usage line already names it.
    if (context.command_meta) |meta| {
        if (meta.description) |desc| {
            try writer.print("{s}\n\n", .{desc});
        }
    }

    // Usage
    try fmt.write("<header>USAGE:</header>\n", .{});
    const usage_string = try generateUsage(context);
    defer context.allocator.free(usage_string);
    try writer.print("    {s}\n\n", .{usage_string});

    // Arguments
    try format.writeArgumentsSection(writer, &fmt, context);

    // Options — the command's own contract comes before navigation to any
    // children, so OPTIONS precedes the subcommand list below for a command
    // that is both executable and a group.
    try fmt.write("<header>OPTIONS:</header>\n", .{});
    if (context.command_module_info) |module_info| {
        if (module_info.has_options) {
            if (format.generateOptionsHelp(module_info, context) catch null) |options_help| {
                defer context.allocator.free(options_help);
                try writer.writeAll(options_help);
            }
        }
    }
    try fmt.write("    <flag>--help</flag>, <flag>-h</flag>{s:<6} Show this help message\n\n", .{""});

    // Subcommands (last: navigation to children). For a command that is both
    // executable and a group, point at its children — mirrors the group/app
    // "run --help for more" footer.
    const had_subcommands = try showSubcommands(context, &fmt);
    if (had_subcommands) {
        const cmd_path = try std.mem.join(context.allocator, " ", context.command_path);
        defer context.allocator.free(cmd_path);
        try fmt.write("Run '<command>{s}</command> <command>{s}</command> <subcommand> <flag>--help</flag>' for more information on a subcommand.\n\n", .{ app_name, cmd_path });
    }

    // Examples
    try format.writeExamplesSection(writer, &fmt, context);

    // Footer (command help has no trailing hint line, only the terminating
    // blank line that separates it from the next shell prompt).
    try writer.writeAll("\n");
}

/// Generate the command's synopsis string. Required options are spelled out
/// (e.g. `--region <value>`); optional ones fold into `[OPTIONS]`. The
/// positional pattern comes from the shared arg-token convention.
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
            // An empty `Args = struct {}` still sets has_args (the decl exists),
            // but has no fields — generateArgsPattern returns null for it, so no
            // placeholder is rendered. A non-empty Args always yields a pattern of
            // its real, named positionals; there is no generic `[ARGS...]` case.
            if (context.command_module_info) |module_info| {
                if (format.generateArgsPattern(module_info, context) catch null) |pattern| {
                    defer context.allocator.free(pattern);
                    try buf_writer.print(" {s}", .{pattern});
                }
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
        // Terminate on the raw writer, not through the markdown formatter:
        // a standalone "\n" has no semantic tags and isn't simple inline, so
        // it routes through the block parser, which drops a leading blank line
        // — swallowing the newline and losing the blank after the COMMANDS
        // list. A newline is not markdown, so write it directly.
        try fmt.writer.writeAll("\n");
    }
    return has_commands;
}

// ============================================================================
// Tests
// ============================================================================

/// Render `.command` help (to stdout) and return the captured buffer.
fn renderCommandHelp(ctx: anytype, aw: *std.Io.Writer.Allocating) ![]const u8 {
    try showCommand(ctx, true);
    try ctx.stdout().flush();
    return aw.written();
}

test "showCommand renders args, enum choices, a required-option marker, and a terminating newline" {
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
    // Plain text so we can assert the rendered tokens directly.
    ctx.theme.caps = .{ .capability = .no_color, .is_tty = false, .color_enabled = false };

    // `deploy <ENVIRONMENT>` with an enum positional, a required `--region`
    // (folded into the usage line explicitly), and an optional enum `--format`.
    ctx.app_name = "myapp";
    ctx.command_path = &.{"deploy"};
    ctx.command_meta = .{ .description = "Deploy the application" };
    ctx.command_module_info = .{
        .has_args = true,
        .args_fields = &.{
            .{ .name = "environment", .is_optional = false, .is_array = false, .type_name = "Environment", .description = "Target environment", .enum_values = &.{ "dev", "staging", "prod" } },
        },
        .has_options = true,
        .options_fields = &.{
            .{ .name = "region", .is_optional = false, .is_array = false, .type_name = "[]const u8", .is_required = true, .description = "Deployment region" },
            .{ .name = "format", .is_optional = true, .is_array = false, .type_name = "?Format", .description = "Output format", .enum_values = &.{ "json", "table" } },
        },
    };
    ctx.plugin_command_info = &.{
        .{ .path = &.{"deploy"}, .description = "Deploy the application" },
    };

    const out = try renderCommandHelp(&ctx, &aw);

    // Description leads; USAGE names the command, spells the required option and
    // shows the positional in the shared convention; the required marker and
    // both enum choice lists render; and the block ends with a newline.
    try std.testing.expect(std.mem.startsWith(u8, out, "Deploy the application\n"));
    // Required `--region` is spelled explicitly, the optional `--format` folds
    // into `[OPTIONS]`, and the positional follows in the shared convention.
    try std.testing.expect(std.mem.indexOf(u8, out, "myapp deploy --region <value> [OPTIONS] <ENVIRONMENT>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(required)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "one of: dev, staging, prod") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "one of: json, table") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\n"));
}

test "showCommand orders sections ARGUMENTS -> OPTIONS -> COMMANDS for an exec+group command" {
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

test "showCommand has a blank line after COMMANDS for an exec+group command" {
    // Regression: showSubcommands terminated the COMMANDS block with
    // `fmt.write("\n", .{})` through the markdown formatter.  A standalone
    // "\n" has no semantic tags, so the block parser (prev_was_blank = true)
    // swallowed it — the blank line between COMMANDS and the follow-up hint
    // was dropped.  Fix: write the newline directly to the raw writer.
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

    // `deploy` is both executable (has options) AND a group (`deploy prod`
    // exists) — exactly the case where the blank line was dropped.
    ctx.app_name = "myapp";
    ctx.command_path = &.{"deploy"};
    ctx.command_module_info = .{
        .has_options = true,
        .options_fields = &.{
            .{ .name = "dry-run", .is_optional = false, .is_array = false, .type_name = "bool", .default_value = "false", .description = "Dry run" },
        },
    };
    ctx.plugin_command_info = &.{
        .{ .path = &.{"deploy"}, .description = "Deploy the app" },
        .{ .path = &.{ "deploy", "prod" }, .description = "Deploy to prod" },
    };

    const out = try renderCommandHelp(&ctx, &aw);

    // The COMMANDS block must be present.
    const i_cmds = std.mem.indexOf(u8, out, "COMMANDS:").?;
    try std.testing.expect(std.mem.indexOf(u8, out, "prod") != null);

    // The follow-up hint comes after COMMANDS.
    const i_hint = std.mem.indexOf(u8, out, "for more information on a subcommand").?;
    try std.testing.expect(i_hint > i_cmds);

    // A blank line (two consecutive newlines) must separate the last COMMANDS
    // entry from the follow-up hint — that's what the missing "\n" provides.
    const between = out[i_cmds..i_hint];
    try std.testing.expect(std.mem.indexOf(u8, between, "\n\n") != null);
}

test "showCommand renders a clean OPTIONS block for an options-less command" {
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
    try std.testing.expect(std.mem.startsWith(u8, std.mem.trimStart(u8, after, " "), "--help"));
    // With no declared options and no subcommands, --help is the only OPTIONS
    // entry and no COMMANDS section renders.
    try std.testing.expect(std.mem.indexOf(u8, out, "--help") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "COMMANDS:") == null);
}

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

test "generateUsage: an empty Args struct renders no [ARGS...] placeholder" {
    const allocator = std.testing.allocator;

    const Ctx = zcli.TestContext(&.{});
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    const environ = std.process.Environ.Map.init(allocator);
    var ctx = Ctx.init(allocator, std.testing.io, &stdio, &environ);
    defer ctx.deinit();
    // Strip color so the usage line is plain text we can match exactly.
    ctx.theme.caps = .{ .capability = .no_color, .is_tty = false, .color_enabled = false };

    ctx.app_name = "tasks";
    ctx.command_path = &.{"list"};
    // `Args = struct {}` sets has_args (the decl exists) with zero fields — the
    // regression: this used to fall through to a bogus `[ARGS...]`.
    ctx.command_module_info = .{ .has_args = true, .has_options = false };

    const usage = try generateUsage(&ctx);
    defer allocator.free(usage);

    // Exact line: no positionals, no [ARGS...] tail.
    try std.testing.expectEqualStrings("tasks list", usage);
}

test "generateUsage: a command with real args renders their names in the shared convention" {
    const allocator = std.testing.allocator;

    const Ctx = zcli.TestContext(&.{});
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    const environ = std.process.Environ.Map.init(allocator);
    var ctx = Ctx.init(allocator, std.testing.io, &stdio, &environ);
    defer ctx.deinit();
    ctx.theme.caps = .{ .capability = .no_color, .is_tty = false, .color_enabled = false };

    ctx.app_name = "tasks";
    ctx.command_path = &.{"add"};
    // A required positional plus an optional varargs tail — both spellings.
    ctx.command_module_info = .{
        .has_args = true,
        .args_fields = &.{
            .{ .name = "title", .is_optional = false, .is_array = false, .type_name = "[]const u8" },
            .{ .name = "tags", .is_optional = true, .is_array = true, .type_name = "[][]const u8" },
        },
        .has_options = false,
    };

    const usage = try generateUsage(&ctx);
    defer allocator.free(usage);

    // Exact line: real, uppercased arg names in the shared clap-style
    // convention — `<TITLE>` required, `[TAGS]...` variadic — never the generic
    // [ARGS...] fallback.
    try std.testing.expectEqualStrings("tasks add <TITLE> [TAGS]...", usage);
}
