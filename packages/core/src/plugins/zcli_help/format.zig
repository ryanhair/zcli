//! Shared help-formatting helpers for the zcli_help plugin.
//!
//! This is the "how a section renders" half of the help renderer — the
//! per-field ARGUMENTS/OPTIONS tables, the usage arg-pattern, and the whole
//! sections (arguments, examples, global options) that both app-level (`app_help`)
//! and command-level (`command_help`) help emit identically. Splitting it out of
//! the old monolith lets the two renderers share one implementation of each
//! section instead of duplicating the field loops.
//!
//! The visible arg-token convention (`<NAME>`/`[NAME]`/`[NAME]...`) comes from
//! the shared `zcli.plugin_abi.usage` module, so help agrees with the doc generator's
//! markdown/man/HTML synopses.

const std = @import("std");
const zcli = @import("zcli");
const md = zcli.markdown;

/// The app's palette, resolved at comptime from the root `zcli_theme`
/// declaration, so help text compiles to the app's themed escape sequences.
/// Shared by every help file via this one import.
pub const app_palette = zcli.appTheme().palette;

/// Width for command/option name columns (content width, excluding indent).
pub const NAME_COLUMN_WIDTH: usize = 16;

/// Generate the usage arg-pattern from command module info (e.g.
/// `<TITLE> [TAGS]...`). Returns null when there are no args to display — an
/// empty `Args = struct {}` yields no pattern.
///
/// The token spelling is the shared `zcli.plugin_abi.usage` convention, uppercase, so help
/// matches the doc generator's synopses verbatim.
pub fn generateArgsPattern(module_info: zcli.CommandModuleInfo, context: anytype) !?[]u8 {
    if (!module_info.has_args or module_info.args_fields.len == 0) return null;

    var aw: std.Io.Writer.Allocating = .init(context.allocator);
    errdefer aw.deinit();
    const writer = &aw.writer;

    var first = true;
    for (module_info.args_fields) |field_info| {
        if (!first) try writer.writeAll(" ");
        first = false;

        // A positional's `is_array` is its variadic-ness; `is_optional` its
        // optionality. The shared classifier picks the bracket set, uppercased.
        var name_buf: [64]u8 = undefined;
        const name = zcli.plugin_abi.usage.upperInto(&name_buf, field_info.name);
        const d = zcli.plugin_abi.usage.delims(zcli.plugin_abi.usage.classify(field_info.is_optional, field_info.is_array));
        try writer.print("{s}{s}{s}", .{ d.open, name, d.close });
    }

    var al = aw.toArrayList();
    return try al.toOwnedSlice(context.allocator);
}

/// Generate args help text (the ARGUMENTS table body) from command module info.
/// Returns null if there are no args to display.
pub fn generateArgsHelp(module_info: zcli.CommandModuleInfo, context: anytype) !?[]u8 {
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
        // Terminate the row on the raw writer, not through the markdown
        // formatter: a standalone "\n" has no semantic tags and isn't simple
        // inline, so it routes through the block parser, which drops a leading
        // blank line — swallowing the newline and collapsing all rows onto one
        // line. A newline is not markdown, so write it directly.
        try buf_writer.writeAll("\n");
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

/// Generate options help text (the OPTIONS table body) from command module info.
/// Returns null if there are no options to display.
pub fn generateOptionsHelp(module_info: zcli.CommandModuleInfo, context: anytype) !?[]u8 {
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
        // Terminate the row on the raw writer, not through the markdown
        // formatter: a standalone "\n" has no semantic tags and isn't simple
        // inline, so it routes through the block parser, which drops a leading
        // blank line — swallowing the newline and collapsing all rows onto one
        // line. A newline is not markdown, so write it directly.
        try buf_writer.writeAll("\n");
    }

    // Mutually-exclusive sets, listed once each under the option lines.
    for (module_info.exclusive) |set| {
        try buf_fmt.write("    Mutually exclusive: ", .{});
        for (set, 0..) |member, mi| {
            if (mi > 0) try buf_fmt.write(", ", .{});
            try writeDashedFlag(&buf_fmt, member);
        }
        try buf_writer.writeAll("\n");
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

// ============================================================================
// Whole-section writers
//
// These render an entire help section from context and are shared by the two
// scenarios that emit them identically: the ARGUMENTS and EXAMPLES sections
// appear in both root help and command help, and GLOBAL OPTIONS in both app and
// root help. Keeping one implementation each is what prevents the sections from
// drifting apart across the two renderers.
// ============================================================================

/// ARGUMENTS section (header + table), shared by root and command help. Emits
/// nothing when the command declares no positional args.
pub fn writeArgumentsSection(writer: *std.Io.Writer, fmt: anytype, context: anytype) !void {
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

/// EXAMPLES section, shared by root and command help. Emits nothing when the
/// command has no `meta.examples`.
pub fn writeExamplesSection(writer: *std.Io.Writer, fmt: anytype, context: anytype) !void {
    if (context.command_meta) |meta| {
        if (meta.examples) |examples| {
            try fmt.write("\n<header>EXAMPLES:</header>\n", .{});
            for (examples) |example| {
                try writer.print("    {s}\n", .{example});
            }
        }
    }
}

/// GLOBAL OPTIONS section, shared by app and root help. Emits nothing when the
/// app registered no global options.
pub fn writeGlobalOptionsSection(writer: *std.Io.Writer, fmt: anytype, context: anytype) !void {
    const global_opts = context.getGlobalOptions();
    if (global_opts.len == 0) return;
    try fmt.write("\n<header>GLOBAL OPTIONS:</header>\n", .{});
    for (global_opts) |opt| {
        if (opt.short) |short| {
            try fmt.write("    <flag>-{c}</flag>, <flag>--{s}</flag>", .{ short, opt.name });
            // Pad to align descriptions. Visible prefix is "-x, --" (6) + name.
            const used = 6 + opt.name.len; // "-x, --name"
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
            // Visible prefix is "--" (2) + name.
            const used = 2 + opt.name.len;
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

// ============================================================================
// Tests
// ============================================================================

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

test "help renders each argument row on its own line" {
    // Same standalone-"\n" regression as the options block: two arg rows must
    // each land on their own line, and the block must end with a newline so the
    // ARGUMENTS/OPTIONS separator renders as a real blank line.
    const allocator = std.testing.allocator;

    const Ctx = zcli.TestContext(&.{});
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    const environ = std.process.Environ.Map.init(allocator);
    var ctx = Ctx.init(allocator, std.testing.io, &stdio, &environ);
    defer ctx.deinit();

    const module_info = zcli.CommandModuleInfo{
        .has_args = true,
        .args_fields = &.{
            .{ .name = "source", .is_optional = false, .is_array = false, .type_name = "[]const u8", .description = "Source path" },
            .{ .name = "dest", .is_optional = false, .is_array = false, .type_name = "[]const u8", .description = "Destination path" },
        },
    };

    const help = (try generateArgsHelp(module_info, &ctx)).?;
    defer allocator.free(help);

    try std.testing.expect(std.mem.endsWith(u8, help, "\n"));

    var line_count: usize = 0;
    var it = std.mem.splitScalar(u8, help, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), line_count);

    // The two arg rows are on separate lines.
    const source_at = std.mem.indexOf(u8, help, "source").?;
    const dest_at = std.mem.indexOf(u8, help, "dest").?;
    try std.testing.expect(std.mem.indexOfScalar(u8, help[source_at..dest_at], '\n') != null);
}

test "help renders each option row on its own line" {
    // Regression guard: option rows were terminated with a standalone markdown
    // write of "\n", which the markdown block parser dropped (leading blank
    // line), collapsing every option onto a single line. The row newline must
    // survive so each option gets its own line and a trailing newline lets the
    // caller add the ARGUMENTS/OPTIONS blank-line separator.
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
            .{ .name = "status", .is_optional = true, .is_array = false, .type_name = "?[]const u8", .short = 's', .description = "Filter by status" },
            .{ .name = "all", .is_optional = false, .is_array = false, .type_name = "bool", .default_value = "false", .short = 'a', .description = "Show all" },
        },
    };

    const help = (try generateOptionsHelp(module_info, &ctx)).?;
    defer allocator.free(help);

    // Two options → two rows, each ending in its own newline. The block ends
    // with a newline (so the callsite's separator produces a real blank line),
    // and there are no interior double newlines gluing rows together.
    try std.testing.expect(std.mem.endsWith(u8, help, "\n"));

    // Split into lines and assert every non-empty line is exactly one option
    // row (starts with the four-space indent + a flag), i.e. rows did not get
    // concatenated onto a shared line.
    var line_count: usize = 0;
    var it = std.mem.splitScalar(u8, help, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;
        // Each option row begins with the 4-space indent then "--" (past any
        // leading ANSI styling, which no_color capability omits here).
        try std.testing.expect(std.mem.indexOf(u8, line, "--") != null);
        // A row must not contain a second "--<name>" flag — that would mean two
        // rows were glued together (the original bug).
        const first = std.mem.indexOf(u8, line, "--").?;
        try std.testing.expect(std.mem.indexOfPos(u8, line, first + 2, "--") == null);
    }
    try std.testing.expectEqual(@as(usize, 2), line_count);

    // Spelled out: the exact two rows are present, each terminated.
    try std.testing.expect(std.mem.indexOf(u8, help, "--status") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--all") != null);
    // The --status row's newline separates it from the --all row (they are not
    // on the same physical line).
    const status_at = std.mem.indexOf(u8, help, "--status").?;
    const all_at = std.mem.indexOf(u8, help, "--all").?;
    const between = help[status_at..all_at];
    try std.testing.expect(std.mem.indexOfScalar(u8, between, '\n') != null);
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

test "generateArgsPattern: shared token convention (uppercase, clap-style brackets)" {
    const allocator = std.testing.allocator;

    const Ctx = zcli.TestContext(&.{});
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    const environ = std.process.Environ.Map.init(allocator);
    var ctx = Ctx.init(allocator, std.testing.io, &stdio, &environ);
    defer ctx.deinit();

    // required → <NAME>, optional → [NAME], variadic → [NAME]... (variadic wins
    // over optional). Names uppercased, agreeing with the doc generator.
    const module_info = zcli.CommandModuleInfo{
        .has_args = true,
        .args_fields = &.{
            .{ .name = "title", .is_optional = false, .is_array = false, .type_name = "[]const u8" },
            .{ .name = "note", .is_optional = true, .is_array = false, .type_name = "?[]const u8" },
            .{ .name = "tags", .is_optional = true, .is_array = true, .type_name = "[][]const u8" },
        },
    };

    const pattern = (try generateArgsPattern(module_info, &ctx)).?;
    defer allocator.free(pattern);

    try std.testing.expectEqualStrings("<TITLE> [NOTE] [TAGS]...", pattern);
}
