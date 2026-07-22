//! zcli_docs — build-only plugin: the documentation generator tool.
//!
//! Compiled for the build host and run via `zig build docs` (see
//! PluginConfig.tool); nothing from this plugin is linked into the shipped
//! binary. Reads command metadata from the registry at comptime and writes
//! markdown, man page, or HTML files.
//!
//! All free text (descriptions, examples, the app description) is routed
//! through `doc_escape` before being written, so a command whose metadata
//! contains `|`, `<`, `\`, or a leading `.` cannot corrupt the output. Those
//! rules are unit-tested in `doc_escape.zig`.

const std = @import("std");
const registry = @import("command_registry");
const tool_config = @import("tool_config");
const zcli = @import("zcli");
const esc = @import("doc_escape.zig");

const CommandInfo = zcli.CommandInfo;
const OptionInfo = zcli.OptionInfo;
const ArgInfo = zcli.ArgInfo;

/// The plugin's config — filled from the consumer's registration, e.g.
/// `zcli.builtin(.docs, .{ .formats = &.{ "markdown", "man" } })`.
const Config = struct {
    /// Formats to generate; each gets its own subdirectory under `output_dir`
    /// when more than one is listed.
    formats: []const []const u8 = &.{"markdown"},
    output_dir: []const u8 = "docs",
};

const cfg = tool_config.config(Config);

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const commands = registry.command_info;
    const global_opts = registry.global_options_info;

    // Route progress through the io model, not std.debug.print — buffered here
    // and flushed at the end, consistent with the framework's output contract.
    var err_buf: [512]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &err_buf);
    const errw = &stderr.interface;

    for (cfg.formats) |format| {
        const dir = if (cfg.formats.len > 1)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cfg.output_dir, format })
        else
            try allocator.dupe(u8, cfg.output_dir);
        defer allocator.free(dir);

        // Ensure the output directory exists before writing into it.
        try std.Io.Dir.cwd().createDirPath(io, dir);

        if (std.mem.eql(u8, format, "man")) {
            try writeManPages(allocator, io, dir, commands, global_opts, init.environ_map, errw);
        } else if (std.mem.eql(u8, format, "html")) {
            try writeHtml(allocator, io, dir, commands, global_opts);
        } else {
            try writeMarkdown(allocator, io, dir, commands, global_opts);
        }

        try errw.print("Generated {s} docs in {s}/\n", .{ format, dir });
    }
    try errw.flush();
}

/// Build the display description for an option/argument: the base description
/// with a trailing `(one of: a, b, c)` when the field is enum-typed, so the
/// valid choices surface in every format. Caller owns the returned slice.
fn descText(allocator: std.mem.Allocator, description: ?[]const u8, enum_values: ?[]const []const u8) ![]u8 {
    const base = description orelse "";
    if (enum_values) |vals| {
        if (vals.len > 0) {
            const joined = try std.mem.join(allocator, ", ", vals);
            defer allocator.free(joined);
            return std.fmt.allocPrint(allocator, "{s}{s}(one of: {s})", .{
                base,
                if (base.len > 0) " " else "",
                joined,
            });
        }
    }
    return allocator.dupe(u8, base);
}

// ============================================================================
// Markdown
// ============================================================================

fn writeMarkdown(allocator: std.mem.Allocator, io: std.Io, output_dir: []const u8, commands: []const CommandInfo, global_opts: []const OptionInfo) !void {
    // Index
    const index_path = try std.fmt.allocPrint(allocator, "{s}/README.md", .{output_dir});
    defer allocator.free(index_path);
    var index_file = try std.Io.Dir.cwd().createFile(io, index_path, .{});
    defer index_file.close(io);
    var ifw = index_file.writer(io, &.{});
    const iw = &ifw.interface;

    try iw.print("# {s}\n\n", .{registry.app_name});
    if (registry.app_description.len > 0) {
        try esc.mdText(iw, registry.app_description);
        try iw.writeAll("\n\n");
    }
    try iw.print("**Version:** {s}\n\n", .{registry.app_version});

    try iw.writeAll("## Commands\n\n| Command | Description |\n|---------|-------------|\n");
    for (commands) |cmd| {
        if (cmd.hidden) continue;
        const name = try std.mem.join(allocator, " ", cmd.path);
        defer allocator.free(name);
        const file_name = try std.mem.join(allocator, "/", cmd.path);
        defer allocator.free(file_name);
        // Link the command to its own page (kept in sync with the HTML index).
        try iw.print("| [`{s} {s}`]({s}.md) | ", .{ registry.app_name, name, file_name });
        try esc.mdCell(iw, cmd.description orelse "");
        try iw.writeAll(" |\n");
    }

    if (global_opts.len > 0) {
        try iw.writeAll("\n## Global Options\n\n| Flag | Short | Description |\n|------|-------|-------------|\n");
        for (global_opts) |opt| try writeOptionRowMarkdown(allocator, iw, opt);
    }

    // Individual command pages
    for (commands) |cmd| {
        if (cmd.hidden) continue;
        try writeCommandMarkdown(allocator, io, output_dir, cmd);
    }
}

fn writeOptionRowMarkdown(allocator: std.mem.Allocator, w: *std.Io.Writer, opt: OptionInfo) !void {
    try w.print("| `--{s}` | ", .{opt.name});
    if (opt.short) |s| try w.print("`-{c}`", .{s});
    try w.writeAll(" | ");
    const d = try descText(allocator, opt.description, opt.enum_values);
    defer allocator.free(d);
    try esc.mdCell(w, d);
    try w.writeAll(" |\n");
}

fn writeCommandMarkdown(allocator: std.mem.Allocator, io: std.Io, output_dir: []const u8, cmd: CommandInfo) !void {
    const cmd_name = try std.mem.join(allocator, " ", cmd.path);
    defer allocator.free(cmd_name);
    const file_name = try std.mem.join(allocator, "/", cmd.path);
    defer allocator.free(file_name);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}.md", .{ output_dir, file_name });
    defer allocator.free(file_path);

    // Create parent directories for nested commands
    if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |last_slash| {
        std.Io.Dir.cwd().createDirPath(io, file_path[0..last_slash]) catch {};
    }

    var file = try std.Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);
    var fw = file.writer(io, &.{});
    const w = &fw.interface;

    try w.print("# {s} {s}\n\n", .{ registry.app_name, cmd_name });
    if (cmd.description) |desc| {
        try esc.mdText(w, desc);
        try w.writeAll("\n\n");
    }

    // Usage (fenced as an indented code block — literal, no escaping needed).
    // Synopsis order `app cmd [OPTIONS] <ARGS>` and the `<NAME>`/`[NAME]`/
    // `[NAME]...` bracket convention come from the shared `zcli.plugin_abi.usage` module,
    // so this matches help/man/html verbatim.
    try w.print("## Usage\n\n    {s} {s}", .{ registry.app_name, cmd_name });
    if (cmd.options.len > 0) try w.writeAll(" [OPTIONS]");
    for (cmd.args) |arg| {
        var name_buf: [64]u8 = undefined;
        const name = zcli.plugin_abi.usage.upperInto(&name_buf, arg.name);
        const d = zcli.plugin_abi.usage.delims(zcli.plugin_abi.usage.classify(arg.is_optional, arg.is_variadic));
        try w.print(" {s}{s}{s}", .{ d.open, name, d.close });
    }
    try w.writeAll("\n\n");

    // Arguments
    if (cmd.args.len > 0) {
        try w.writeAll("## Arguments\n\n| Name | Required | Description |\n|------|----------|-------------|\n");
        for (cmd.args) |arg| {
            try w.writeAll("| ");
            try esc.mdCell(w, arg.name);
            try w.print(" | {s} | ", .{if (arg.is_optional) "no" else "yes"});
            const d = try descText(allocator, arg.description, arg.enum_values);
            defer allocator.free(d);
            try esc.mdCell(w, d);
            try w.writeAll(" |\n");
        }
        try w.writeAll("\n");
    }

    // Options
    if (cmd.options.len > 0) {
        try w.writeAll("## Options\n\n| Flag | Short | Description |\n|------|-------|-------------|\n");
        for (cmd.options) |opt| try writeOptionRowMarkdown(allocator, w, opt);
        try w.writeAll("\n");
    }

    // Aliases
    if (cmd.aliases.len > 0) {
        try w.writeAll("## Aliases\n\n");
        for (cmd.aliases) |alias| try w.print("- `{s}`\n", .{alias});
        try w.writeAll("\n");
    }

    // Examples (indented code block — literal)
    if (cmd.examples) |examples| {
        try w.writeAll("## Examples\n\n");
        for (examples) |example| try w.print("    {s} {s}\n", .{ registry.app_name, example });
        try w.writeAll("\n");
    }
}

// ============================================================================
// Man pages
// ============================================================================

/// The man page `.TH` date (`YYYY-MM-DD`). Honors `SOURCE_DATE_EPOCH` (the
/// reproducible-builds convention) when set, otherwise stamps the current
/// time — the tool runs at build time, so "now" IS the build date. Computing
/// it here rather than injecting a build option keeps the tool binary
/// byte-stable across days (no daily compile-cache bust).
fn buildDate(buf: []u8, io: std.Io, environ: *const std.process.Environ.Map, errw: *std.Io.Writer) ![]const u8 {
    const epoch_secs: u64 = blk: {
        if (environ.get("SOURCE_DATE_EPOCH")) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (std.fmt.parseInt(u64, trimmed, 10)) |secs| {
                break :blk secs;
            } else |_| {
                try errw.print("warning: SOURCE_DATE_EPOCH is not a valid integer ('{s}'); using current time\n", .{trimmed});
            }
        }
        const ns = std.Io.Clock.real.now(io).nanoseconds;
        break :blk @intCast(@divTrunc(ns, std.time.ns_per_s));
    };

    const epoch_day = (std.time.epoch.EpochSeconds{ .secs = epoch_secs }).getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
    });
}

fn writeManPages(allocator: std.mem.Allocator, io: std.Io, output_dir: []const u8, commands: []const CommandInfo, global_opts: []const OptionInfo, environ: *const std.process.Environ.Map, errw: *std.Io.Writer) !void {
    // The `.TH` date field (mandoc warns when it is empty).
    var date_buf: [16]u8 = undefined;
    const date = try buildDate(&date_buf, io, environ, errw);
    for (commands) |cmd| {
        if (cmd.hidden) continue;
        try writeCommandManPage(allocator, io, output_dir, cmd, global_opts, date);
    }
}

fn writeManOption(allocator: std.mem.Allocator, w: *std.Io.Writer, opt: OptionInfo) !void {
    if (opt.short) |s| {
        try w.print(".TP\n\\fB\\-\\-{s}\\fR, \\fB\\-{c}\\fR\n", .{ opt.name, s });
    } else {
        try w.print(".TP\n\\fB\\-\\-{s}\\fR\n", .{opt.name});
    }
    const d = try descText(allocator, opt.description, opt.enum_values);
    defer allocator.free(d);
    if (d.len > 0) {
        try esc.roff(w, d);
        try w.writeAll("\n");
    }
}

fn writeCommandManPage(allocator: std.mem.Allocator, io: std.Io, output_dir: []const u8, cmd: CommandInfo, global_opts: []const OptionInfo, date: []const u8) !void {
    const cmd_name = try std.mem.join(allocator, " ", cmd.path);
    defer allocator.free(cmd_name);
    const man_name = try std.mem.join(allocator, "-", cmd.path);
    defer allocator.free(man_name);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}.1", .{ output_dir, registry.app_name, man_name });
    defer allocator.free(file_path);

    var file = try std.Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);
    var fw = file.writer(io, &.{});
    const w = &fw.interface;

    const app_upper = try std.ascii.allocUpperString(allocator, registry.app_name);
    defer allocator.free(app_upper);

    // Header: title section date source
    try w.print(".TH {s} 1 \"{s}\" \"{s} {s}\"\n", .{ app_upper, date, registry.app_name, registry.app_version });

    // Name
    try w.print(".SH NAME\n{s}-{s} \\- ", .{ registry.app_name, man_name });
    try esc.roff(w, cmd.description orelse "");
    try w.writeAll("\n");

    // Synopsis. The `[OPTIONS]`-before-args order and the bracket convention
    // are the shared ones (`zcli.plugin_abi.usage`); only the roff font macros around the
    // name (`\fI…\fR`) are man-local. `<`/`>` are literal characters in roff.
    try w.print(".SH SYNOPSIS\n.B {s} {s}\n", .{ registry.app_name, cmd_name });
    if (cmd.options.len > 0) try w.writeAll("[\\fIOPTIONS\\fR]\n");
    for (cmd.args) |arg| {
        var name_buf: [64]u8 = undefined;
        const name = zcli.plugin_abi.usage.upperInto(&name_buf, arg.name);
        const d = zcli.plugin_abi.usage.delims(zcli.plugin_abi.usage.classify(arg.is_optional, arg.is_variadic));
        try w.print("{s}\\fI{s}\\fR{s}\n", .{ d.open, name, d.close });
    }

    // Description
    if (cmd.description) |desc| {
        try w.writeAll(".SH DESCRIPTION\n");
        try esc.roff(w, desc);
        try w.writeAll("\n");
    }

    // Arguments
    if (cmd.args.len > 0) {
        try w.writeAll(".SH ARGUMENTS\n");
        for (cmd.args) |arg| {
            try w.print(".TP\n\\fI{s}\\fR\n", .{arg.name});
            const d = try descText(allocator, arg.description, arg.enum_values);
            defer allocator.free(d);
            try esc.roff(w, d);
            if (arg.is_optional) try w.writeAll(" (optional)");
            try w.writeAll("\n");
        }
    }

    // Options
    if (cmd.options.len > 0 or global_opts.len > 0) {
        try w.writeAll(".SH OPTIONS\n");
        for (cmd.options) |opt| try writeManOption(allocator, w, opt);
        if (global_opts.len > 0) {
            try w.writeAll(".SS Global Options\n");
            for (global_opts) |opt| try writeManOption(allocator, w, opt);
        }
    }

    // Aliases
    if (cmd.aliases.len > 0) {
        try w.writeAll(".SH ALIASES\n");
        for (cmd.aliases, 0..) |alias, i| {
            if (i > 0) try w.writeAll(".br\n");
            try w.print("\\fB{s}\\fR\n", .{alias});
        }
    }

    // Examples
    if (cmd.examples) |examples| {
        try w.writeAll(".SH EXAMPLES\n");
        for (examples) |example| {
            try w.writeAll(".nf\n");
            try w.print("{s} ", .{registry.app_name});
            try esc.roff(w, example);
            try w.writeAll("\n.fi\n");
        }
    }
}

// ============================================================================
// HTML
// ============================================================================

// Dark, terminal-native theme mirroring the zcli website (website/assets/
// styles.css): Zig-amber accent, system-mono code, subtle grid texture. Kept
// inline and dependency-free (no webfont) so a generated docs tree is portable
// and works offline.
const html_style =
    \\:root {
    \\  --bg: #0c0d10; --surface: #14161b; --surface2: #1a1d24;
    \\  --fg: #e7e9ee; --muted: #9298a4; --faint: #838b98;
    \\  --border: rgba(255,255,255,0.08); --border2: rgba(255,255,255,0.14);
    \\  --accent: #f7a41d; --green: #57c97a; --red: #f06969; --cyan: #5ec8d8;
    \\  --font: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    \\  --mono: "JetBrains Mono", "SF Mono", ui-monospace, "IBM Plex Mono", Menlo, monospace;
    \\}
    \\* { margin: 0; padding: 0; box-sizing: border-box; }
    \\body {
    \\  font: 16px/1.65 var(--font); color: var(--fg); background: var(--bg);
    \\  max-width: 46rem; margin: 0 auto; padding: 3rem 1.5rem 5rem;
    \\  -webkit-font-smoothing: antialiased; -moz-osx-font-smoothing: grayscale;
    \\  background-image:
    \\    linear-gradient(rgba(255,255,255,0.018) 1px, transparent 1px),
    \\    linear-gradient(90deg, rgba(255,255,255,0.018) 1px, transparent 1px);
    \\  background-size: 56px 56px;
    \\}
    \\h1 { font-size: 1.9rem; letter-spacing: -0.02em; line-height: 1.1; margin-bottom: 0.6rem; }
    \\h2 { font-size: 1.15rem; letter-spacing: -0.01em; margin: 2.4rem 0 0.9rem; padding-bottom: 0.35rem; border-bottom: 1px solid var(--border); }
    \\p { margin-bottom: 1rem; color: var(--fg); }
    \\a { color: var(--accent); text-decoration: none; }
    \\a:hover { text-decoration: underline; }
    \\::selection { background: var(--accent); color: #1a1205; }
    \\code { font-family: var(--mono); font-size: 0.86em; background: var(--surface2); border: 1px solid var(--border); border-radius: 5px; padding: 1px 6px; color: var(--accent); }
    \\pre { background: #0a0b0e; border: 1px solid var(--border2); border-radius: 10px; padding: 1rem 1.15rem; overflow-x: auto; margin-bottom: 1rem; box-shadow: 0 12px 32px rgba(0,0,0,0.4); }
    \\pre code { background: none; border: none; padding: 0; color: #cfd3da; font-size: 0.86rem; line-height: 1.7; }
    \\table { width: 100%; border-collapse: collapse; margin-bottom: 1rem; font-size: 0.92rem; }
    \\th { text-align: left; padding: 0 0.9rem 0.7rem; border-bottom: 1px solid var(--border); font-family: var(--mono); font-size: 0.68rem; letter-spacing: 0.08em; text-transform: uppercase; color: var(--faint); font-weight: 500; }
    \\td { padding: 0.7rem 0.9rem; border-bottom: 1px solid var(--border); color: var(--muted); vertical-align: top; }
    \\td code { color: var(--accent); }
    \\.version { color: var(--faint); font-family: var(--mono); font-size: 0.8rem; margin-bottom: 1.75rem; }
    \\.nav { margin-bottom: 1.5rem; font-family: var(--mono); font-size: 0.8rem; color: var(--faint); }
    \\.nav a { color: var(--muted); }
    \\.nav a:hover { color: var(--accent); }
    \\ul { padding-left: 1.4rem; margin-bottom: 1rem; color: var(--muted); }
    \\li { padding: 0.15rem 0; }
    \\footer { margin-top: 3.5rem; padding-top: 1.5rem; border-top: 1px solid var(--border); color: var(--faint); font-family: var(--mono); font-size: 0.75rem; }
    \\footer a { color: var(--muted); }
;

fn writeHtml(allocator: std.mem.Allocator, io: std.Io, output_dir: []const u8, commands: []const CommandInfo, global_opts: []const OptionInfo) !void {
    // Index page
    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.html", .{output_dir});
    defer allocator.free(index_path);
    var index_file = try std.Io.Dir.cwd().createFile(io, index_path, .{});
    defer index_file.close(io);
    var ifw = index_file.writer(io, &.{});
    const iw = &ifw.interface;

    try htmlHead(iw, registry.app_name);
    try iw.writeAll("<h1>");
    try esc.html(iw, registry.app_name);
    try iw.writeAll("</h1>\n");
    if (registry.app_description.len > 0) {
        try iw.writeAll("<p>");
        try esc.html(iw, registry.app_description);
        try iw.writeAll("</p>\n");
    }
    try iw.print("<p class=\"version\">Version {s}</p>\n", .{registry.app_version});

    try iw.writeAll("<h2>Commands</h2>\n<table><tr><th>Command</th><th>Description</th></tr>\n");
    for (commands) |cmd| {
        if (cmd.hidden) continue;
        const name = try std.mem.join(allocator, " ", cmd.path);
        defer allocator.free(name);
        const file_name = try std.mem.join(allocator, "/", cmd.path);
        defer allocator.free(file_name);
        try iw.print("<tr><td><a href=\"{s}.html\"><code>", .{file_name});
        try esc.html(iw, registry.app_name);
        try iw.writeByte(' ');
        try esc.html(iw, name);
        try iw.writeAll("</code></a></td><td>");
        try esc.html(iw, cmd.description orelse "");
        try iw.writeAll("</td></tr>\n");
    }
    try iw.writeAll("</table>\n");

    if (global_opts.len > 0) {
        try iw.writeAll("<h2>Global Options</h2>\n<table><tr><th>Flag</th><th>Short</th><th>Description</th></tr>\n");
        for (global_opts) |opt| try writeOptionRowHtml(allocator, iw, opt);
        try iw.writeAll("</table>\n");
    }

    try htmlFoot(iw);

    // Individual command pages
    for (commands) |cmd| {
        if (cmd.hidden) continue;
        try writeCommandHtml(allocator, io, output_dir, cmd, commands);
    }
}

fn writeOptionRowHtml(allocator: std.mem.Allocator, w: *std.Io.Writer, opt: OptionInfo) !void {
    try w.print("<tr><td><code>--{s}</code></td><td>", .{opt.name});
    if (opt.short) |s| try w.print("<code>-{c}</code>", .{s});
    try w.writeAll("</td><td>");
    const d = try descText(allocator, opt.description, opt.enum_values);
    defer allocator.free(d);
    try esc.html(w, d);
    try w.writeAll("</td></tr>\n");
}

fn writeCommandHtml(allocator: std.mem.Allocator, io: std.Io, output_dir: []const u8, cmd: CommandInfo, all_commands: []const CommandInfo) !void {
    const cmd_name = try std.mem.join(allocator, " ", cmd.path);
    defer allocator.free(cmd_name);
    const file_name = try std.mem.join(allocator, "/", cmd.path);
    defer allocator.free(file_name);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}.html", .{ output_dir, file_name });
    defer allocator.free(file_path);

    if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |last_slash| {
        std.Io.Dir.cwd().createDirPath(io, file_path[0..last_slash]) catch {};
    }

    var file = try std.Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);
    var fw = file.writer(io, &.{});
    const w = &fw.interface;

    const title = try std.fmt.allocPrint(allocator, "{s} {s}", .{ registry.app_name, cmd_name });
    defer allocator.free(title);
    try htmlHead(w, title);

    // Breadcrumb navigation with correct relative paths
    {
        // Compute path back to root: depth of cmd.path levels up
        // e.g. path ["container", "ls"] -> file is container/ls.html -> root is ../index.html
        const depth = cmd.path.len - 1; // first segment is the filename's directory depth
        try w.writeAll("<p class=\"nav\">");

        // Link to root index
        var root_prefix = try allocator.alloc(u8, depth * 3); // "../" per level
        defer allocator.free(root_prefix);
        for (0..depth) |i| {
            root_prefix[i * 3] = '.';
            root_prefix[i * 3 + 1] = '.';
            root_prefix[i * 3 + 2] = '/';
        }
        try w.print("<a href=\"{s}index.html\">", .{root_prefix});
        try esc.html(w, registry.app_name);
        try w.writeAll("</a>");

        // Link intermediate path segments (only if they have their own page)
        for (cmd.path[0 .. cmd.path.len - 1], 0..) |part, i| {
            // Check if this intermediate path has a corresponding command page
            const ancestor_path = cmd.path[0 .. i + 1];
            var has_page = false;
            for (all_commands) |other| {
                if (other.hidden) continue;
                if (other.path.len == ancestor_path.len) {
                    var match = true;
                    for (other.path, ancestor_path) |a, b| {
                        if (!std.mem.eql(u8, a, b)) {
                            match = false;
                            break;
                        }
                    }
                    if (match) {
                        has_page = true;
                        break;
                    }
                }
            }

            if (has_page) {
                const levels_up = depth - i;
                var prefix = try allocator.alloc(u8, levels_up * 3);
                defer allocator.free(prefix);
                for (0..levels_up) |j| {
                    prefix[j * 3] = '.';
                    prefix[j * 3 + 1] = '.';
                    prefix[j * 3 + 2] = '/';
                }
                try w.print(" &rsaquo; <a href=\"{s}{s}.html\">", .{ prefix, part });
                try esc.html(w, part);
                try w.writeAll("</a>");
            } else {
                try w.writeAll(" &rsaquo; ");
                try esc.html(w, part);
            }
        }

        // Current command (not linked)
        try w.writeAll(" &rsaquo; ");
        try esc.html(w, cmd.path[cmd.path.len - 1]);
        try w.writeAll("</p>\n");
    }
    try w.writeAll("<h1>");
    try esc.html(w, registry.app_name);
    try w.writeByte(' ');
    try esc.html(w, cmd_name);
    try w.writeAll("</h1>\n");
    if (cmd.description) |desc| {
        try w.writeAll("<p>");
        try esc.html(w, desc);
        try w.writeAll("</p>\n");
    }

    // Subcommands (all descendants under this command's path)
    {
        var has_subcommands = false;
        for (all_commands) |other| {
            if (other.hidden) continue;
            if (other.path.len > cmd.path.len and startsWith(other.path, cmd.path)) {
                if (!has_subcommands) {
                    try w.writeAll("<h2>Subcommands</h2>\n<table><tr><th>Command</th><th>Description</th></tr>\n");
                    has_subcommands = true;
                }
                // Full display name
                const full_name = try std.mem.join(allocator, " ", other.path);
                defer allocator.free(full_name);

                // Link is relative to current file's directory.
                // Current file is at: {cmd.path[0]}/{cmd.path[1]}/.../{last}.html
                // which sits in a directory at depth = cmd.path.len - 1.
                // Target file is at: {other.path[0]}/{other.path[1]}/.../{last}.html
                // We need to go up to root, then back down to the target.
                const depth = cmd.path.len - 1;
                var prefix = try allocator.alloc(u8, depth * 3);
                defer allocator.free(prefix);
                for (0..depth) |j| {
                    prefix[j * 3] = '.';
                    prefix[j * 3 + 1] = '.';
                    prefix[j * 3 + 2] = '/';
                }
                const target_file = try std.mem.join(allocator, "/", other.path);
                defer allocator.free(target_file);
                try w.print("<tr><td><a href=\"{s}{s}.html\"><code>", .{ prefix, target_file });
                try esc.html(w, registry.app_name);
                try w.writeByte(' ');
                try esc.html(w, full_name);
                try w.writeAll("</code></a></td><td>");
                try esc.html(w, other.description orelse "");
                try w.writeAll("</td></tr>\n");
            }
        }
        if (has_subcommands) try w.writeAll("</table>\n");
    }

    // Usage. Synopsis order and bracket convention are the shared ones
    // (`zcli.plugin_abi.usage`); the delimiters and name are routed through `esc.html`, so
    // the required `<`/`>` become `&lt;`/`&gt;` while `[`, `]`, `]...` pass
    // through unchanged.
    try w.writeAll("<h2>Usage</h2>\n<pre><code>");
    try esc.html(w, registry.app_name);
    try w.writeByte(' ');
    try esc.html(w, cmd_name);
    if (cmd.options.len > 0) try w.writeAll(" [OPTIONS]");
    for (cmd.args) |arg| {
        var name_buf: [64]u8 = undefined;
        const name = zcli.plugin_abi.usage.upperInto(&name_buf, arg.name);
        const d = zcli.plugin_abi.usage.delims(zcli.plugin_abi.usage.classify(arg.is_optional, arg.is_variadic));
        try w.writeByte(' ');
        try esc.html(w, d.open);
        try esc.html(w, name);
        try esc.html(w, d.close);
    }
    try w.writeAll("</code></pre>\n");

    // Arguments
    if (cmd.args.len > 0) {
        try w.writeAll("<h2>Arguments</h2>\n<table><tr><th>Name</th><th>Required</th><th>Description</th></tr>\n");
        for (cmd.args) |arg| {
            try w.writeAll("<tr><td><code>");
            try esc.html(w, arg.name);
            try w.print("</code></td><td>{s}</td><td>", .{if (arg.is_optional) "no" else "yes"});
            const d = try descText(allocator, arg.description, arg.enum_values);
            defer allocator.free(d);
            try esc.html(w, d);
            try w.writeAll("</td></tr>\n");
        }
        try w.writeAll("</table>\n");
    }

    // Options
    if (cmd.options.len > 0) {
        try w.writeAll("<h2>Options</h2>\n<table><tr><th>Flag</th><th>Short</th><th>Description</th></tr>\n");
        for (cmd.options) |opt| try writeOptionRowHtml(allocator, w, opt);
        try w.writeAll("</table>\n");
    }

    // Aliases
    if (cmd.aliases.len > 0) {
        try w.writeAll("<h2>Aliases</h2>\n<ul>\n");
        for (cmd.aliases) |alias| {
            try w.writeAll("<li><code>");
            try esc.html(w, alias);
            try w.writeAll("</code></li>\n");
        }
        try w.writeAll("</ul>\n");
    }

    // Examples
    if (cmd.examples) |examples| {
        try w.writeAll("<h2>Examples</h2>\n<pre><code>");
        for (examples) |example| {
            try esc.html(w, registry.app_name);
            try w.writeByte(' ');
            try esc.html(w, example);
            try w.writeByte('\n');
        }
        try w.writeAll("</code></pre>\n");
    }

    try htmlFoot(w);
}

fn startsWith(path: []const []const u8, prefix: []const []const u8) bool {
    if (path.len < prefix.len) return false;
    for (path[0..prefix.len], prefix) |a, b| {
        if (!std.mem.eql(u8, a, b)) return false;
    }
    return true;
}

fn htmlHead(w: *std.Io.Writer, title: []const u8) !void {
    try w.writeAll("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"UTF-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n");
    try w.writeAll("<title>");
    try esc.html(w, title);
    try w.writeAll("</title>\n");
    try w.writeAll("<style>\n");
    try w.writeAll(html_style);
    try w.writeAll("\n</style>\n</head>\n<body>\n");
}

fn htmlFoot(w: *std.Io.Writer) !void {
    try w.writeAll("<footer>Generated with <a href=\"https://github.com/ryanhair/zcli\">zcli</a> · ");
    try esc.html(w, registry.app_name);
    try w.print(" {s}</footer>\n", .{registry.app_version});
    try w.writeAll("</body>\n</html>\n");
}
