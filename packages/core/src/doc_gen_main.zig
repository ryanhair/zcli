//! zcli documentation generator.
//! Reads command metadata from the registry at comptime and writes
//! markdown or man page files. Run via `zig build docs`.

const std = @import("std");
const registry = @import("command_registry");
const zcli = @import("zcli");

const CommandInfo = zcli.CommandInfo;
const OptionInfo = zcli.OptionInfo;
const ArgInfo = zcli.ArgInfo;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const output_dir = if (args.len > 1) args[1] else "docs";
    // Remaining args are formats to generate (default: markdown)
    const formats = if (args.len > 2) args[2..] else &[_][:0]const u8{"markdown"};

    const commands = registry.command_info;
    const global_opts = registry.global_options_info;

    for (formats) |format| {
        const dir = if (formats.len > 1)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, format })
        else
            try allocator.dupe(u8, output_dir);
        defer allocator.free(dir);

        std.fs.cwd().makePath(dir) catch |err| {
            std.debug.print("Failed to create output directory '{s}': {}\n", .{ dir, err });
            return err;
        };

        if (std.mem.eql(u8, format, "man")) {
            try writeManPages(allocator, dir, commands, global_opts);
        } else if (std.mem.eql(u8, format, "html")) {
            try writeHtml(allocator, dir, commands, global_opts);
        } else {
            try writeMarkdown(allocator, dir, commands, global_opts);
        }

        std.debug.print("Generated {s} docs in {s}/\n", .{ format, dir });
    }
}

// ============================================================================
// Markdown
// ============================================================================

fn writeMarkdown(allocator: std.mem.Allocator, output_dir: []const u8, commands: []const CommandInfo, global_opts: []const OptionInfo) !void {
    // Index
    const index_path = try std.fmt.allocPrint(allocator, "{s}/README.md", .{output_dir});
    defer allocator.free(index_path);
    var index_file = try std.fs.cwd().createFile(index_path, .{});
    defer index_file.close();
    var ifw = index_file.writer(&.{});
    const iw = &ifw.interface;

    try iw.print("# {s}\n\n", .{registry.app_name});
    if (registry.app_description.len > 0) {
        try iw.print("{s}\n\n", .{registry.app_description});
    }
    try iw.print("**Version:** {s}\n\n", .{registry.app_version});

    try iw.writeAll("## Commands\n\n| Command | Description |\n|---------|-------------|\n");
    for (commands) |cmd| {
        if (cmd.hidden) continue;
        const name = try std.mem.join(allocator, " ", cmd.path);
        defer allocator.free(name);
        try iw.print("| `{s} {s}` | {s} |\n", .{ registry.app_name, name, cmd.description orelse "" });
    }

    if (global_opts.len > 0) {
        try iw.writeAll("\n## Global Options\n\n| Flag | Short | Description |\n|------|-------|-------------|\n");
        for (global_opts) |opt| {
            var short_buf: [2]u8 = undefined;
            const short_str: []const u8 = if (opt.short) |s| blk: {
                short_buf = .{ '-', s };
                break :blk &short_buf;
            } else "";
            try iw.print("| `--{s}` | `{s}` | {s} |\n", .{ opt.name, short_str, opt.description orelse "" });
        }
    }

    // Individual command pages
    for (commands) |cmd| {
        if (cmd.hidden) continue;
        try writeCommandMarkdown(allocator, output_dir, cmd);
    }
}

fn writeCommandMarkdown(allocator: std.mem.Allocator, output_dir: []const u8, cmd: CommandInfo) !void {
    const cmd_name = try std.mem.join(allocator, " ", cmd.path);
    defer allocator.free(cmd_name);
    const file_name = try std.mem.join(allocator, "/", cmd.path);
    defer allocator.free(file_name);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}.md", .{ output_dir, file_name });
    defer allocator.free(file_path);

    // Create parent directories for nested commands
    if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |last_slash| {
        std.fs.cwd().makePath(file_path[0..last_slash]) catch {};
    }

    var file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();
    var fw = file.writer(&.{});
    const w = &fw.interface;

    try w.print("# {s} {s}\n\n", .{ registry.app_name, cmd_name });
    if (cmd.description) |desc| try w.print("{s}\n\n", .{desc});

    // Usage
    try w.print("## Usage\n\n    {s} {s}", .{ registry.app_name, cmd_name });
    for (cmd.args) |arg| {
        if (arg.is_variadic) {
            try w.print(" {s}...", .{arg.name});
        } else if (arg.is_optional) {
            try w.print(" [{s}]", .{arg.name});
        } else {
            try w.print(" <{s}>", .{arg.name});
        }
    }
    if (cmd.options.len > 0) try w.writeAll(" [OPTIONS]");
    try w.writeAll("\n\n");

    // Arguments
    if (cmd.args.len > 0) {
        try w.writeAll("## Arguments\n\n| Name | Required | Description |\n|------|----------|-------------|\n");
        for (cmd.args) |arg| {
            try w.print("| {s} | {s} | {s} |\n", .{ arg.name, if (arg.is_optional) "no" else "yes", arg.description orelse "" });
        }
        try w.writeAll("\n");
    }

    // Options
    if (cmd.options.len > 0) {
        try w.writeAll("## Options\n\n| Flag | Short | Description |\n|------|-------|-------------|\n");
        for (cmd.options) |opt| {
            var short_buf: [2]u8 = undefined;
            const short_str: []const u8 = if (opt.short) |s| blk: {
                short_buf = .{ '-', s };
                break :blk &short_buf;
            } else "";
            try w.print("| `--{s}` | `{s}` | {s} |\n", .{ opt.name, short_str, opt.description orelse "" });
        }
        try w.writeAll("\n");
    }

    // Aliases
    if (cmd.aliases.len > 0) {
        try w.writeAll("## Aliases\n\n");
        for (cmd.aliases) |alias| try w.print("- `{s}`\n", .{alias});
        try w.writeAll("\n");
    }

    // Examples
    if (cmd.examples) |examples| {
        try w.writeAll("## Examples\n\n");
        for (examples) |example| try w.print("    {s} {s}\n", .{ registry.app_name, example });
        try w.writeAll("\n");
    }
}

// ============================================================================
// Man pages
// ============================================================================

fn writeManPages(allocator: std.mem.Allocator, output_dir: []const u8, commands: []const CommandInfo, global_opts: []const OptionInfo) !void {
    for (commands) |cmd| {
        if (cmd.hidden) continue;
        try writeCommandManPage(allocator, output_dir, cmd, global_opts);
    }
}

fn writeCommandManPage(allocator: std.mem.Allocator, output_dir: []const u8, cmd: CommandInfo, global_opts: []const OptionInfo) !void {
    const cmd_name = try std.mem.join(allocator, " ", cmd.path);
    defer allocator.free(cmd_name);
    const man_name = try std.mem.join(allocator, "-", cmd.path);
    defer allocator.free(man_name);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}.1", .{ output_dir, registry.app_name, man_name });
    defer allocator.free(file_path);

    var file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();
    var fw = file.writer(&.{});
    const w = &fw.interface;

    const app_upper = try std.ascii.allocUpperString(allocator, registry.app_name);
    defer allocator.free(app_upper);

    // Header
    try w.print(".TH {s} 1 \"\" \"{s} {s}\"\n", .{ app_upper, registry.app_name, registry.app_version });

    // Name
    try w.print(".SH NAME\n{s}-{s} \\- {s}\n", .{ registry.app_name, man_name, cmd.description orelse "" });

    // Synopsis
    try w.print(".SH SYNOPSIS\n.B {s} {s}\n", .{ registry.app_name, cmd_name });
    for (cmd.args) |arg| {
        if (arg.is_optional) {
            try w.print("[\\fI{s}\\fR]\n", .{arg.name});
        } else {
            try w.print("\\fI{s}\\fR\n", .{arg.name});
        }
    }

    // Description
    if (cmd.description) |desc| try w.print(".SH DESCRIPTION\n{s}\n", .{desc});

    // Arguments
    if (cmd.args.len > 0) {
        try w.writeAll(".SH ARGUMENTS\n");
        for (cmd.args) |arg| {
            try w.print(".TP\n\\fI{s}\\fR\n", .{arg.name});
            if (arg.description) |d| try w.print("{s}", .{d});
            if (arg.is_optional) try w.writeAll(" (optional)");
            try w.writeAll("\n");
        }
    }

    // Options
    if (cmd.options.len > 0 or global_opts.len > 0) {
        try w.writeAll(".SH OPTIONS\n");
        for (cmd.options) |opt| {
            if (opt.short) |s| {
                try w.print(".TP\n\\fB\\-\\-{s}\\fR, \\fB\\-{c}\\fR\n", .{ opt.name, s });
            } else {
                try w.print(".TP\n\\fB\\-\\-{s}\\fR\n", .{opt.name});
            }
            if (opt.description) |d| try w.print("{s}\n", .{d});
        }
        if (global_opts.len > 0) {
            try w.writeAll(".SS Global Options\n");
            for (global_opts) |opt| {
                if (opt.short) |s| {
                    try w.print(".TP\n\\fB\\-\\-{s}\\fR, \\fB\\-{c}\\fR\n", .{ opt.name, s });
                } else {
                    try w.print(".TP\n\\fB\\-\\-{s}\\fR\n", .{opt.name});
                }
                if (opt.description) |d| try w.print("{s}\n", .{d});
            }
        }
    }

    // Examples
    if (cmd.examples) |examples| {
        try w.writeAll(".SH EXAMPLES\n");
        for (examples) |example| {
            try w.writeAll(".nf\n");
            try w.print("{s} {s}\n", .{ registry.app_name, example });
            try w.writeAll(".fi\n");
        }
    }
}

// ============================================================================
// HTML
// ============================================================================

const html_style =
    \\:root { --bg: #fff; --fg: #1a1a2e; --muted: #6b7280; --border: #e5e7eb; --accent: #2563eb; --code-bg: #f3f4f6; --table-stripe: #f9fafb; }
    \\@media (prefers-color-scheme: dark) { :root { --bg: #1a1a2e; --fg: #e5e7eb; --muted: #9ca3af; --border: #374151; --accent: #60a5fa; --code-bg: #1f2937; --table-stripe: #111827; } }
    \\* { margin: 0; padding: 0; box-sizing: border-box; }
    \\body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif; color: var(--fg); background: var(--bg); max-width: 48rem; margin: 0 auto; padding: 2rem 1.5rem; line-height: 1.6; }
    \\h1 { font-size: 1.75rem; margin-bottom: 0.5rem; }
    \\h2 { font-size: 1.25rem; margin-top: 2rem; margin-bottom: 0.75rem; border-bottom: 1px solid var(--border); padding-bottom: 0.25rem; }
    \\p { margin-bottom: 1rem; }
    \\code { font-family: 'SF Mono', Consolas, 'Liberation Mono', Menlo, monospace; font-size: 0.875em; background: var(--code-bg); padding: 0.15em 0.35em; border-radius: 3px; }
    \\pre { background: var(--code-bg); padding: 1rem; border-radius: 6px; overflow-x: auto; margin-bottom: 1rem; }
    \\pre code { background: none; padding: 0; }
    \\table { width: 100%; border-collapse: collapse; margin-bottom: 1rem; font-size: 0.9rem; }
    \\th { text-align: left; padding: 0.5rem 0.75rem; border-bottom: 2px solid var(--border); font-weight: 600; }
    \\td { padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--border); }
    \\tr:nth-child(even) { background: var(--table-stripe); }
    \\a { color: var(--accent); text-decoration: none; }
    \\a:hover { text-decoration: underline; }
    \\.version { color: var(--muted); font-size: 0.9rem; margin-bottom: 1.5rem; }
    \\.nav { margin-bottom: 1.5rem; font-size: 0.875rem; }
    \\.nav a { margin-right: 0.5rem; }
    \\ul { padding-left: 1.5rem; margin-bottom: 1rem; }
;

fn writeHtml(allocator: std.mem.Allocator, output_dir: []const u8, commands: []const CommandInfo, global_opts: []const OptionInfo) !void {
    // Index page
    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.html", .{output_dir});
    defer allocator.free(index_path);
    var index_file = try std.fs.cwd().createFile(index_path, .{});
    defer index_file.close();
    var ifw = index_file.writer(&.{});
    const iw = &ifw.interface;

    try htmlHead(iw, registry.app_name);
    try iw.print("<h1>{s}</h1>\n", .{registry.app_name});
    if (registry.app_description.len > 0) {
        try iw.print("<p>{s}</p>\n", .{registry.app_description});
    }
    try iw.print("<p class=\"version\">Version {s}</p>\n", .{registry.app_version});

    try iw.writeAll("<h2>Commands</h2>\n<table><tr><th>Command</th><th>Description</th></tr>\n");
    for (commands) |cmd| {
        if (cmd.hidden) continue;
        const name = try std.mem.join(allocator, " ", cmd.path);
        defer allocator.free(name);
        const file_name = try std.mem.join(allocator, "/", cmd.path);
        defer allocator.free(file_name);
        try iw.print("<tr><td><a href=\"{s}.html\"><code>{s} {s}</code></a></td><td>{s}</td></tr>\n", .{ file_name, registry.app_name, name, cmd.description orelse "" });
    }
    try iw.writeAll("</table>\n");

    if (global_opts.len > 0) {
        try iw.writeAll("<h2>Global Options</h2>\n<table><tr><th>Flag</th><th>Short</th><th>Description</th></tr>\n");
        for (global_opts) |opt| {
            var short_buf: [2]u8 = undefined;
            const short_str: []const u8 = if (opt.short) |s| blk: {
                short_buf = .{ '-', s };
                break :blk &short_buf;
            } else "";
            try iw.print("<tr><td><code>--{s}</code></td><td><code>{s}</code></td><td>{s}</td></tr>\n", .{ opt.name, short_str, opt.description orelse "" });
        }
        try iw.writeAll("</table>\n");
    }

    try htmlFoot(iw);

    // Individual command pages
    for (commands) |cmd| {
        if (cmd.hidden) continue;
        try writeCommandHtml(allocator, output_dir, cmd, commands);
    }
}

fn writeCommandHtml(allocator: std.mem.Allocator, output_dir: []const u8, cmd: CommandInfo, all_commands: []const CommandInfo) !void {
    const cmd_name = try std.mem.join(allocator, " ", cmd.path);
    defer allocator.free(cmd_name);
    const file_name = try std.mem.join(allocator, "/", cmd.path);
    defer allocator.free(file_name);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}.html", .{ output_dir, file_name });
    defer allocator.free(file_path);

    if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |last_slash| {
        std.fs.cwd().makePath(file_path[0..last_slash]) catch {};
    }

    var file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();
    var fw = file.writer(&.{});
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
        try w.print("<a href=\"{s}index.html\">{s}</a>", .{ root_prefix, registry.app_name });

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
                try w.print(" &rsaquo; <a href=\"{s}{s}.html\">{s}</a>", .{ prefix, part, part });
            } else {
                try w.print(" &rsaquo; {s}", .{part});
            }
        }

        // Current command (not linked)
        try w.print(" &rsaquo; {s}", .{cmd.path[cmd.path.len - 1]});
        try w.writeAll("</p>\n");
    }
    try w.print("<h1>{s} {s}</h1>\n", .{ registry.app_name, cmd_name });
    if (cmd.description) |desc| try w.print("<p>{s}</p>\n", .{desc});

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
                try w.print("<tr><td><a href=\"{s}{s}.html\"><code>{s} {s}</code></a></td><td>{s}</td></tr>\n", .{ prefix, target_file, registry.app_name, full_name, other.description orelse "" });
            }
        }
        if (has_subcommands) try w.writeAll("</table>\n");
    }

    // Usage
    try w.writeAll("<h2>Usage</h2>\n<pre><code>");
    try w.print("{s} {s}", .{ registry.app_name, cmd_name });
    for (cmd.args) |arg| {
        if (arg.is_variadic) {
            try w.print(" {s}...", .{arg.name});
        } else if (arg.is_optional) {
            try w.print(" [{s}]", .{arg.name});
        } else {
            try w.print(" &lt;{s}&gt;", .{arg.name});
        }
    }
    if (cmd.options.len > 0) try w.writeAll(" [OPTIONS]");
    try w.writeAll("</code></pre>\n");

    // Arguments
    if (cmd.args.len > 0) {
        try w.writeAll("<h2>Arguments</h2>\n<table><tr><th>Name</th><th>Required</th><th>Description</th></tr>\n");
        for (cmd.args) |arg| {
            try w.print("<tr><td><code>{s}</code></td><td>{s}</td><td>{s}</td></tr>\n", .{ arg.name, if (arg.is_optional) "no" else "yes", arg.description orelse "" });
        }
        try w.writeAll("</table>\n");
    }

    // Options
    if (cmd.options.len > 0) {
        try w.writeAll("<h2>Options</h2>\n<table><tr><th>Flag</th><th>Short</th><th>Description</th></tr>\n");
        for (cmd.options) |opt| {
            var short_buf: [2]u8 = undefined;
            const short_str: []const u8 = if (opt.short) |s| blk: {
                short_buf = .{ '-', s };
                break :blk &short_buf;
            } else "";
            try w.print("<tr><td><code>--{s}</code></td><td><code>{s}</code></td><td>{s}</td></tr>\n", .{ opt.name, short_str, opt.description orelse "" });
        }
        try w.writeAll("</table>\n");
    }

    // Aliases
    if (cmd.aliases.len > 0) {
        try w.writeAll("<h2>Aliases</h2>\n<ul>\n");
        for (cmd.aliases) |alias| try w.print("<li><code>{s}</code></li>\n", .{alias});
        try w.writeAll("</ul>\n");
    }

    // Examples
    if (cmd.examples) |examples| {
        try w.writeAll("<h2>Examples</h2>\n<pre><code>");
        for (examples) |example| try w.print("{s} {s}\n", .{ registry.app_name, example });
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

fn htmlHead(w: anytype, title: []const u8) !void {
    try w.writeAll("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"UTF-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n");
    try w.print("<title>{s}</title>\n", .{title});
    try w.writeAll("<style>\n");
    try w.writeAll(html_style);
    try w.writeAll("\n</style>\n</head>\n<body>\n");
}

fn htmlFoot(w: anytype) !void {
    try w.writeAll("</body>\n</html>\n");
}
