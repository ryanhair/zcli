//! Multi-selection prompt with toggle via space key.

const std = @import("std");
const terminal = @import("terminal");
const prompts = @import("prompts.zig");
const lr = @import("list_render.zig");

pub const MultiSelectConfig = struct {
    message: []const u8,
    choices: []const []const u8,
    defaults: ?[]const bool = null,
    prefix: []const u8 = "? ",
    unicode: bool = true,
    /// Theme + terminal capabilities for styling; zcli commands pass `context.theme`.
    theme: prompts.theme.ThemeContext = prompts.default_style,
};

/// Prompt to select multiple items. Returns owned slice of selected indices.
pub fn multiSelect(writer: anytype, reader: anytype, allocator: std.mem.Allocator, config: MultiSelectConfig) ![]usize {
    if (config.choices.len == 0) return error.NoChoices;
    const is_tty = terminal.isStdinTty();

    if (!is_tty) {
        // Non-TTY: numbered list, accept comma-separated numbers
        try writer.print("{s}{s} (space to toggle, enter to confirm)\r\n", .{ config.prefix, config.message });
        for (config.choices, 1..) |choice, i| {
            const is_default = if (config.defaults) |d| (i - 1 < d.len and d[i - 1]) else false;
            const marker: []const u8 = if (is_default) "[x]" else "[ ]";
            try writer.print("  {d}) {s} {s}\n", .{ i, marker, choice });
        }
        try writer.writeAll("> ");

        const line = readLine(reader, allocator) catch return collectDefaults(allocator, config);
        defer allocator.free(line);
        if (line.len == 0) return collectDefaults(allocator, config);

        // Parse comma-separated numbers
        var result = std.ArrayList(usize).empty;
        var iter = std.mem.splitScalar(u8, line, ',');
        while (iter.next()) |part| {
            const num_str = std.mem.trim(u8, part, " ");
            const num = std.fmt.parseInt(usize, num_str, 10) catch continue;
            if (num >= 1 and num <= config.choices.len) {
                try result.append(allocator, num - 1);
            }
        }
        return try result.toOwnedSlice(allocator);
    }

    // TTY: interactive multi-select
    prompts.flushWriter(writer);
    const raw = terminal.enableRawMode(std.Io.File.stdin().handle) catch {
        return collectDefaults(allocator, config);
    };
    try writer.writeAll(terminal.ansi.hide_cursor);
    var watcher = terminal.ResizeWatcher.init();
    defer {
        writer.writeAll(terminal.ansi.show_cursor) catch {};
        watcher.deinit();
        raw.disable();
        prompts.flushWriter(writer);
    }

    var selected = try allocator.alloc(bool, config.choices.len);
    defer allocator.free(selected);
    if (config.defaults) |d| {
        for (0..config.choices.len) |i| {
            selected[i] = if (i < d.len) d[i] else false;
        }
    } else {
        @memset(selected, false);
    }

    const stdin = std.Io.File.stdin().handle;
    var cursor: usize = 0;
    var rows = try renderList(writer, config, selected, cursor, lr.windowSize());

    while (true) {
        prompts.flushWriter(writer);
        switch (try terminal.readEvent(reader, stdin, &watcher)) {
            .resize => {
                try lr.eraseRegion(writer, rows);
                rows = try renderList(writer, config, selected, cursor, lr.windowSize());
            },
            .key => |k| switch (k) {
                .up => {
                    if (cursor > 0) cursor -= 1;
                    try lr.eraseRegion(writer, rows);
                    rows = try renderList(writer, config, selected, cursor, lr.windowSize());
                },
                .down => {
                    if (cursor < config.choices.len - 1) cursor += 1;
                    try lr.eraseRegion(writer, rows);
                    rows = try renderList(writer, config, selected, cursor, lr.windowSize());
                },
                .char => |c| {
                    if (c == ' ') {
                        selected[cursor] = !selected[cursor];
                        try lr.eraseRegion(writer, rows);
                        rows = try renderList(writer, config, selected, cursor, lr.windowSize());
                    }
                },
                .enter => {
                    try lr.eraseRegion(writer, rows);
                    // Show summary
                    var first = true;
                    var obuf: [64]u8 = undefined;
                    const open = prompts.openSeq(&obuf, config.theme, config.theme.promptTokens().selected);
                    try writer.print("  {s}", .{open});
                    for (config.choices, 0..) |choice, i| {
                        if (selected[i]) {
                            if (!first) try writer.writeAll(", ");
                            try writer.writeAll(choice);
                            first = false;
                        }
                    }
                    try writer.print("{s}\r\n", .{prompts.closeSeq(open)});

                    // Collect selected indices
                    var result = std.ArrayList(usize).empty;
                    for (0..config.choices.len) |i| {
                        if (selected[i]) try result.append(allocator, i);
                    }
                    return try result.toOwnedSlice(allocator);
                },
                .ctrl => |c| {
                    if (c == 'c') {
                        try lr.eraseRegion(writer, rows);
                        return error.UserAborted;
                    }
                },
                else => {},
            },
        }
    }
}

/// Render the header and (viewport-limited) choice list at the given terminal
/// size, returning the number of physical rows emitted. Width is taken as an
/// explicit parameter (not queried) so this is deterministic and unit-testable.
/// Uses the shared `list_render` machinery; only the marker/cursor styling is
/// multi-select-specific.
///
/// Lines are separated by (not terminated with) CRLF: after rendering, the
/// cursor sits at the end of the last row, which `lr.eraseRegion` relies on to
/// avoid scrolling the screen when the region reaches the bottom.
///
/// Public for the cross-platform emulator render tests.
pub fn renderList(
    writer: anytype,
    config: MultiSelectConfig,
    selected: []const bool,
    cursor: usize,
    ws: terminal.Winsize,
) !usize {
    const width = @max(@as(usize, ws.col), 1);
    // Leave the last column unused so a full-width line can't trigger the
    // terminal's deferred auto-wrap (DECAWM) and desync our row count.
    const usable = @max(width -| 1, 1);
    const height = @max(@as(usize, ws.row), 2);

    const cursor_sym = terminal.symbols.select_cursor(config.unicode);
    const sel_sym = terminal.symbols.selected(config.unicode);
    const unsel_sym = terminal.symbols.unselected(config.unicode);
    // Cursor row "  <cur> <marker> " and plain row "    <marker> " are both this
    // wide (assuming a single-column cursor glyph), so wrapped text and the
    // hang-indent of continuation lines all align.
    const prefix_w = 5 + terminal.displayWidth(sel_sym);
    const avail = @max(usable -| prefix_w, 1);

    var rows: usize = 0;
    var first_line = true;

    // Header (hang-indents any wrap under the message text).
    const hprefix_w = terminal.displayWidth(config.prefix);
    var hbuf: [512]u8 = undefined;
    const header = std.fmt.bufPrint(&hbuf, "{s} (space to toggle, enter to confirm)", .{config.message}) catch config.message;
    rows += try lr.renderItem(writer, &first_line, .{ .first_prefix = config.prefix, .prefix_w = hprefix_w }, header, @max(usable -| hprefix_w, 1));

    // Viewport over choices; row counts are computed on demand (no allocation).
    const Counter = struct {
        choices: []const []const u8,
        avail: usize,
        fn at(self: *const @This(), i: usize) usize {
            return terminal.wrapCount(self.choices[i], self.avail);
        }
    };
    const counter = Counter{ .choices = config.choices, .avail = avail };
    // Reserve one screen row (below the header) so trailing content never scrolls.
    const list_budget = @max((height -| 1) -| rows, 1);
    const win = lr.viewport(config.choices.len, cursor, list_budget, &counter, Counter.at);

    const tokens = config.theme.promptTokens();
    for (win.start..win.end) |i| {
        const marker = if (selected[i]) sel_sym else unsel_sym;
        var pbuf: [192]u8 = undefined;
        var cbuf: [64]u8 = undefined;
        var mbuf: [64]u8 = undefined;
        const style: lr.ItemStyle = if (i == cursor) blk: {
            const cur_open = prompts.openSeq(&cbuf, config.theme, tokens.cursor);
            const mark_open = prompts.openSeq(&mbuf, config.theme, tokens.marker);
            break :blk .{
                .first_prefix = std.fmt.bufPrint(&pbuf, "  {s}{s}{s} {s}{s}{s} ", .{
                    cur_open,  cursor_sym, prompts.closeSeq(cur_open),
                    mark_open, marker,     prompts.closeSeq(mark_open),
                }) catch "  ",
                .prefix_w = prefix_w,
            };
        } else .{
            .first_prefix = std.fmt.bufPrint(&pbuf, "    {s} ", .{marker}) catch "    ",
            .prefix_w = prefix_w,
        };
        rows += try lr.renderItem(writer, &first_line, style, config.choices[i], avail);
    }

    return rows;
}

fn readLine(reader: anytype, allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    while (true) {
        const byte = terminal.key.readByteFn(reader) catch return try buf.toOwnedSlice(allocator);
        if (byte == '\n') break;
        if (byte != '\r') try buf.append(allocator, byte);
    }
    return try buf.toOwnedSlice(allocator);
}

fn collectDefaults(allocator: std.mem.Allocator, config: MultiSelectConfig) ![]usize {
    var result = std.ArrayList(usize).empty;
    if (config.defaults) |d| {
        for (0..@min(d.len, config.choices.len)) |i| {
            if (d[i]) try result.append(allocator, i);
        }
    }
    return try result.toOwnedSlice(allocator);
}

test "MultiSelectConfig defaults" {
    const cfg = MultiSelectConfig{ .message = "Pick:", .choices = &.{ "a", "b" } };
    try std.testing.expect(cfg.defaults == null);
}

test "non-TTY: selects by comma-separated numbers" {
    const allocator = std.testing.allocator;
    var input = "1,3\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [1024]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try multiSelect(&output_writer, &input_reader, allocator, .{
        .message = "Pick:",
        .choices = &.{ "a", "b", "c" },
    });
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(usize, 0), result[0]); // 1 => index 0
    try std.testing.expectEqual(@as(usize, 2), result[1]); // 3 => index 2
}

test "non-TTY: empty input returns defaults" {
    const allocator = std.testing.allocator;
    var input = "\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [1024]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try multiSelect(&output_writer, &input_reader, allocator, .{
        .message = "Pick:",
        .choices = &.{ "a", "b", "c" },
        .defaults = &.{ true, false, true },
    });
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(usize, 0), result[0]);
    try std.testing.expectEqual(@as(usize, 2), result[1]);
}

test "non-TTY: no defaults returns empty" {
    const allocator = std.testing.allocator;
    var input = "\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [1024]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try multiSelect(&output_writer, &input_reader, allocator, .{
        .message = "Pick:",
        .choices = &.{ "a", "b" },
    });
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

// ---------------------------------------------------------------------------
// Render tests — the regression guard for the erase-count bug: a wrapped option
// must report the true number of physical rows, and continuation lines must
// hang-indent under the option text.
// ---------------------------------------------------------------------------

fn renderToBuf(buf: []u8, config: MultiSelectConfig, selected: []const bool, cursor: usize, ws: terminal.Winsize) !struct { rows: usize, text: []const u8 } {
    var w: std.Io.Writer = .fixed(buf);
    const rows = try renderList(&w, config, selected, cursor, ws);
    return .{ .rows = rows, .text = w.buffered() };
}

test "renderList: short options are one row each" {
    var buf: [1024]u8 = undefined;
    const r = try renderToBuf(&buf, .{ .message = "Pick", .choices = &.{ "a", "b", "c" } }, &.{ false, false, false }, 0, .{ .row = 24, .col = 80 });
    // 1 header row + 3 option rows.
    try std.testing.expectEqual(@as(usize, 4), r.rows);
}

test "renderList: a wrapping option counts as multiple physical rows" {
    var buf: [4096]u8 = undefined;
    const long = "this is a fairly long option label that will certainly wrap";
    // Narrow terminal forces the long option onto several rows.
    const r = try renderToBuf(&buf, .{ .message = "Pick", .choices = &.{ "short", long } }, &.{ false, false }, 0, .{ .row = 24, .col = 24 });
    // header(1) + short(1) + long(>=3 at width 24) — the key point is it is not 3.
    try std.testing.expect(r.rows > 3);
    // Row count must equal the number of CRLF-separated lines actually emitted.
    const lines = std.mem.count(u8, r.text, "\r\n") + 1;
    try std.testing.expectEqual(lines, r.rows);
}

test "renderList: cursor row styles through the cursor and marker tokens" {
    var buf: [1024]u8 = undefined;
    const custom = prompts.theme.Theme{
        .prompts = .{
            .cursor = .{ .style = .{ .foreground = .{ .rgb = .{ .r = 9, .g = 8, .b = 7 } } } },
            .marker = .{ .style = .{ .foreground = .{ .rgb = .{ .r = 4, .g = 5, .b = 6 } } } },
        },
    };
    const ctx = prompts.theme.ThemeContext{
        .theme = &custom,
        .caps = .{ .capability = .true_color, .is_tty = true, .color_enabled = true },
    };
    const r = try renderToBuf(&buf, .{ .message = "Pick", .choices = &.{ "a", "b" }, .theme = ctx }, &.{ true, false }, 0, .{ .row = 24, .col = 80 });
    try std.testing.expect(std.mem.indexOf(u8, r.text, "38;2;9;8;7") != null); // cursor glyph
    try std.testing.expect(std.mem.indexOf(u8, r.text, "38;2;4;5;6") != null); // marker
}

test "renderList: no_color renders without any escapes" {
    var buf: [1024]u8 = undefined;
    const ctx = prompts.theme.ThemeContext{
        .caps = .{ .capability = .no_color, .is_tty = true, .color_enabled = false },
    };
    const r = try renderToBuf(&buf, .{ .message = "Pick", .choices = &.{ "a", "b" }, .theme = ctx }, &.{ true, false }, 0, .{ .row = 24, .col = 80 });
    try std.testing.expect(std.mem.indexOf(u8, r.text, "\x1b[") == null);
}

test "renderList: continuation lines hang-indent under the option text" {
    var buf: [4096]u8 = undefined;
    // unicode=false so the prefix is "    [ ] " = 8 columns.
    const r = try renderToBuf(&buf, .{ .message = "Pick", .choices = &.{"alpha bravo charlie delta"}, .unicode = false }, &.{false}, 0, .{ .row = 24, .col = 20 });
    _ = r;
    // The continuation line is preceded by 8 spaces (prefix width), aligning it
    // under the label text rather than under the bullet.
    try std.testing.expect(std.mem.indexOf(u8, buf[0..], "\r\n        ") != null);
}
