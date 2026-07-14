//! Multi-selection prompt with toggle via space key.
//!
//! Rendering runs on the ui engine (see select.zig); input handling stays
//! here. Toggling a marker repaints exactly one cell — the frame diff does
//! the rest.

const std = @import("std");
const terminal = @import("terminal");
const Prompts = @import("Prompts.zig");
const lr = @import("list_render.zig");
const ui = lr.ui;

pub const MultiSelectConfig = struct {
    message: []const u8,
    choices: []const []const u8,
    defaults: ?[]const bool = null,
    prefix: []const u8 = "? ",
    unicode: bool = true,
};

/// Prompt to select multiple items. Returns owned slice of selected indices,
/// or `error.EndOfStream` if stdin closes with no line to submit.
pub fn multiSelect(p: Prompts, config: MultiSelectConfig) ![]usize {
    const writer = p.writer;
    const reader = p.reader;
    const allocator = p.allocator;
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

        // A submitted blank line accepts the defaults; a closed stdin errors.
        const line = try readLine(reader, allocator);
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
    Prompts.flushWriter(writer);
    const raw = terminal.enableRawMode(std.Io.File.stdin().handle) catch {
        return collectDefaults(allocator, config);
    };
    var watcher = terminal.ResizeWatcher.init();
    defer {
        watcher.deinit();
        raw.disable();
        Prompts.flushWriter(writer);
    }
    var app = try ui.App.init(p.allocator, writer, .{
        .capability = p.theme.capability(),
        .unicode = config.unicode,
        .hybrid_raw = raw,
    });
    defer app.deinit();

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
    try renderFrame(&app, p.theme, config, selected, cursor);

    while (true) {
        switch (try terminal.readEvent(reader, stdin, &watcher)) {
            .resize => try renderFrame(&app, p.theme, config, selected, cursor),
            .key => |k| switch (k) {
                .up => {
                    if (cursor > 0) cursor -= 1;
                    try renderFrame(&app, p.theme, config, selected, cursor);
                },
                .down => {
                    if (cursor < config.choices.len - 1) cursor += 1;
                    try renderFrame(&app, p.theme, config, selected, cursor);
                },
                .char => |c| {
                    if (c == ' ') {
                        selected[cursor] = !selected[cursor];
                        try renderFrame(&app, p.theme, config, selected, cursor);
                    }
                },
                .enter => {
                    try app.clear();
                    // Emit the summary of selected choices as a static line.
                    var summary = std.ArrayList(u8).empty;
                    defer summary.deinit(allocator);
                    for (config.choices, 0..) |choice, i| {
                        if (selected[i]) {
                            if (summary.items.len > 0) try summary.appendSlice(allocator, ", ");
                            try summary.appendSlice(allocator, choice);
                        }
                    }
                    var obuf: [64]u8 = undefined;
                    const open = Prompts.openSeq(&obuf, p.theme, p.theme.promptTokens().selected);
                    try app.emit("  {s}{s}{s}", .{ open, summary.items, Prompts.closeSeq(open) });

                    // Collect selected indices
                    var result = std.ArrayList(usize).empty;
                    for (0..config.choices.len) |i| {
                        if (selected[i]) try result.append(allocator, i);
                    }
                    return try result.toOwnedSlice(allocator);
                },
                .ctrl => |c| {
                    if (c == 'c') {
                        try app.clear();
                        return error.UserAborted;
                    }
                },
                else => {},
            },
            else => {}, // mouse/focus never arrive — prompts don't enable them
        }
    }
}

fn renderFrame(app: *ui.App, ctx: Prompts.ThemeContext, config: MultiSelectConfig, selected: []const bool, cursor: usize) !void {
    try app.frame(try frameNode(app.arena(), ctx, config, selected, cursor, lr.windowSize()));
}

/// Build the header and (viewport-limited) choice list as one frame. Pure
/// and size-explicit so it is deterministic and unit-testable; only the
/// marker/cursor styling is multi-select-specific.
pub fn frameNode(
    a: std.mem.Allocator,
    ctx: Prompts.ThemeContext,
    config: MultiSelectConfig,
    selected: []const bool,
    cursor: usize,
    ws: terminal.Winsize,
) !ui.Node {
    const width = @max(@as(usize, ws.col), 1);
    const usable: u16 = @intCast(@min(@max(width -| 1, 1), std.math.maxInt(u16)));
    const height = @max(@as(usize, ws.row), 2);

    const cursor_sym = terminal.symbols.select_cursor(config.unicode);
    const sel_sym = terminal.symbols.selected(config.unicode);
    const unsel_sym = terminal.symbols.unselected(config.unicode);
    // Cursor row "  <cur> <marker> " and plain row "    <marker> " are both
    // this wide (single-column cursor glyph), so labels and their wrapped
    // continuation lines all align.
    const prefix_w: u16 = @intCast(5 + terminal.displayWidth(sel_sym));
    const avail: u16 = @intCast(@max(@as(usize, usable) -| prefix_w, 1));

    var rows = std.ArrayList(ui.Node).empty;

    // Header (hang-indents any wrap under the message text).
    const hprefix_w: u16 = @intCast(terminal.displayWidth(config.prefix));
    const havail: u16 = @intCast(@max(@as(usize, usable) -| hprefix_w, 1));
    const header = try std.fmt.allocPrint(a, "{s} (space to toggle, enter to confirm)", .{config.message});
    try rows.append(a, try lr.itemRow(a, lr.prefixCell(.{}, config.prefix), hprefix_w, header, havail, .{}));
    const header_rows = terminal.wrapCount(header, havail);

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
    const list_budget = @max((height -| 1) -| header_rows, 1);
    const win = lr.viewport(config.choices.len, cursor, list_budget, &counter, Counter.at);

    const tokens = ctx.promptTokens();
    const cursor_style = ctx.resolveRef(tokens.cursor);
    const marker_style = ctx.resolveRef(tokens.marker);
    for (win.start..win.end) |i| {
        const marker = if (selected[i]) sel_sym else unsel_sym;
        const prefix = if (i == cursor)
            try ui.row(a, .{}, &.{
                lr.prefixCell(.{}, "  "),
                lr.prefixCell(cursor_style, cursor_sym),
                lr.prefixCell(.{}, " "),
                lr.prefixCell(marker_style, marker),
            })
        else
            try ui.row(a, .{}, &.{
                lr.prefixCell(.{}, "    "),
                lr.prefixCell(.{}, marker),
            });
        try rows.append(a, try lr.itemRow(a, prefix, prefix_w, config.choices[i], avail, .{}));
    }

    return ui.column(a, .{ .width = .{ .len = usable } }, rows.items);
}

/// Read a line byte by byte until newline. Returns `error.EndOfStream` if the
/// stream closes before any byte is read; a partial line terminated by EOF is
/// returned as the submitted line.
fn readLine(reader: anytype, allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    while (true) {
        const byte = terminal.key.readByteFn(reader) catch {
            if (buf.items.len == 0) return error.EndOfStream;
            return try buf.toOwnedSlice(allocator);
        };
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

    const result = try multiSelect(.{ .writer = &output_writer, .reader = &input_reader, .allocator = allocator }, .{
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

    const result = try multiSelect(.{ .writer = &output_writer, .reader = &input_reader, .allocator = allocator }, .{
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

    const result = try multiSelect(.{ .writer = &output_writer, .reader = &input_reader, .allocator = allocator }, .{
        .message = "Pick:",
        .choices = &.{ "a", "b" },
    });
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "non-TTY: EOF errors instead of returning defaults" {
    const allocator = std.testing.allocator;
    var input = "".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [1024]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    // A blank line accepts defaults, but a closed stdin surfaces instead.
    try std.testing.expectError(error.EndOfStream, multiSelect(.{ .writer = &output_writer, .reader = &input_reader, .allocator = allocator }, .{
        .message = "Pick:",
        .choices = &.{ "a", "b", "c" },
        .defaults = &.{ true, false, true },
    }));
}

// ---------------------------------------------------------------------------
// Frame tests — the regression guard for the erase-count bug's modern form: a
// wrapped option must measure its true physical rows (so the App reserves
// enough region), and continuation lines must hang-indent under the label.
// ---------------------------------------------------------------------------

const FrameHarness = struct {
    arena: std.heap.ArenaAllocator,

    fn init() FrameHarness {
        return .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    }
    fn deinit(self: *FrameHarness) void {
        self.arena.deinit();
    }
    fn a(self: *FrameHarness) std.mem.Allocator {
        return self.arena.allocator();
    }
    fn rctx(self: *FrameHarness) ui.RenderCtx {
        return .{ .allocator = self.a() };
    }
};

test "frameNode: short options are one row each" {
    var h = FrameHarness.init();
    defer h.deinit();
    const node = try frameNode(h.a(), Prompts.default_style, .{ .message = "Pick", .choices = &.{ "a", "b", "c" } }, &.{ false, false, false }, 0, .{ .row = 24, .col = 80 });
    const rc = h.rctx();
    const size = ui.measure(&rc, &node, .{ .max_w = 100, .max_h = 50 });
    try std.testing.expectEqual(@as(u16, 4), size.h); // header + 3
}

test "frameNode: a wrapping option measures its true physical rows" {
    var h = FrameHarness.init();
    defer h.deinit();
    const long = "this is a fairly long option label that will certainly wrap";
    const node = try frameNode(h.a(), Prompts.default_style, .{ .message = "Pick", .choices = &.{ "short", long } }, &.{ false, false }, 0, .{ .row = 24, .col = 24 });
    const rc = h.rctx();
    const size = ui.measure(&rc, &node, .{ .max_w = 100, .max_h = 50 });
    try std.testing.expect(size.h > 3);
    // header (wraps: it carries the toggle hint) + short(1) + the long
    // label's wrap count at the item width (usable 23 minus the prefix).
    const header_rows = terminal.wrapCount("Pick (space to toggle, enter to confirm)", 23 - 2);
    const prefix_w = 5 + terminal.displayWidth(terminal.symbols.selected(true));
    const expected = header_rows + 1 + terminal.wrapCount(long, 23 - prefix_w);
    try std.testing.expectEqual(@as(u16, @intCast(expected)), size.h);
}

test "frameNode: cursor row styles through the cursor and marker tokens" {
    var h = FrameHarness.init();
    defer h.deinit();
    const custom = Prompts.Theme{
        .prompts = .{
            .cursor = .{ .style = .{ .foreground = .{ .rgb = .{ .r = 9, .g = 8, .b = 7 } } } },
            .marker = .{ .style = .{ .foreground = .{ .rgb = .{ .r = 4, .g = 5, .b = 6 } } } },
        },
    };
    const ctx = Prompts.ThemeContext{
        .theme = &custom,
        .caps = .{ .capability = .true_color, .is_tty = true, .color_enabled = true },
    };
    const node = try frameNode(h.a(), ctx, .{ .message = "Pick", .choices = &.{ "a", "b" } }, &.{ true, false }, 0, .{ .row = 24, .col = 80 });

    var s = try ui.Surface.init(std.testing.allocator, 79, 3);
    defer s.deinit();
    const rc = h.rctx();
    try ui.render(&rc, &node, s.root());

    // Cursor row (row 1): glyph at col 2 wears the cursor token, the marker
    // next to it wears the marker token; the plain row's marker is unstyled.
    try std.testing.expect(ui.styleEql(ctx.resolveRef(ctx.promptTokens().cursor), s.cell(2, 1).style));
    try std.testing.expect(ui.styleEql(ctx.resolveRef(ctx.promptTokens().marker), s.cell(4, 1).style));
    try std.testing.expect(ui.styleEql(.{}, s.cell(4, 2).style));
}

test "frameNode: continuation lines hang-indent under the option text" {
    var h = FrameHarness.init();
    defer h.deinit();
    // unicode=false so the prefix is "    [ ] " = 8 columns.
    const node = try frameNode(h.a(), Prompts.default_style, .{ .message = "Pick", .choices = &.{"alpha bravo charlie delta"}, .unicode = false }, &.{false}, 0, .{ .row = 24, .col = 20 });

    var s = try ui.Surface.init(std.testing.allocator, 19, 8);
    defer s.deinit();
    const rc = h.rctx();
    try ui.render(&rc, &node, s.root());

    // The header (with its toggle hint) wraps at this width; the option's
    // first line follows it: marker "[" at col 4, label from col 8.
    const opt: u16 = @intCast(terminal.wrapCount("Pick (space to toggle, enter to confirm)", 19 - 2));
    try std.testing.expectEqualStrings("[", s.cellText(s.cell(4, opt)));
    try std.testing.expectEqualStrings("a", s.cellText(s.cell(8, opt)));
    // The next row is a continuation: columns 0-7 blank (hang indent).
    var x: u16 = 0;
    while (x < 8) : (x += 1) try std.testing.expect(s.cell(x, opt + 1).isBlank());
    try std.testing.expect(!s.cell(8, opt + 1).isBlank());
}
