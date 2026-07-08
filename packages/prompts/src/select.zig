//! Single selection prompt with arrow key navigation.
//!
//! Rendering runs on the ui engine: each interaction paints one frame of a
//! node tree (diffed in place — navigation repaints only the rows that
//! changed), and the chosen answer is emitted as a static line that flows
//! into scrollback. Input stays here: raw mode, key events, and resize
//! watching are the prompt's job; the App is display-only.

const std = @import("std");
const terminal = @import("terminal");
const Prompts = @import("Prompts.zig");
const lr = @import("list_render.zig");
const ui = lr.ui;

pub const SelectConfig = struct {
    message: []const u8,
    choices: []const []const u8,
    prefix: []const u8 = "? ",
    unicode: bool = true,
    /// Keys the prompt should not handle itself: pressing one aborts the prompt
    /// with `error.Interrupted`. Empty = handle/ignore all keys.
    interrupt_keys: []const terminal.Key = &.{},
};

/// Prompt to select one item from a list. Returns the chosen index, or
/// `error.Interrupted` if the user presses one of `config.interrupt_keys`.
pub fn select(p: Prompts, config: SelectConfig) !usize {
    const writer = p.writer;
    const reader = p.reader;
    if (config.choices.len == 0) return error.NoChoices;
    const is_tty = terminal.isStdinTty();

    if (!is_tty) {
        // Non-TTY: numbered list
        try writer.print("{s}{s}\r\n", .{ config.prefix, config.message });
        for (config.choices, 1..) |choice, i| {
            try writer.print("  {d}) {s}\n", .{ i, choice });
        }
        try writer.writeAll("> ");
        const line = readLine(reader, p.allocator) catch return 0;
        defer p.allocator.free(line);
        const num = std.fmt.parseInt(usize, line, 10) catch return 0;
        if (num >= 1 and num <= config.choices.len) return num - 1;
        return 0;
    }

    // TTY: interactive selection
    Prompts.flushWriter(writer);
    const raw = terminal.enableRawMode(std.Io.File.stdin().handle) catch return 0;
    var watcher = terminal.ResizeWatcher.init();
    defer {
        watcher.deinit();
        raw.disable();
        Prompts.flushWriter(writer);
    }
    // The App owns the cursor (hidden on first frame, restored by deinit)
    // and the live region. Runs before the raw/watcher cleanup above (LIFO),
    // so its restore bytes still go out under raw mode — which is why the
    // App terminates lines with CRLF.
    var app = try ui.App.init(p.allocator, writer, .{
        .capability = p.theme.capability(),
        .unicode = config.unicode,
    });
    defer app.deinit();

    const stdin = std.Io.File.stdin().handle;
    var cursor: usize = 0;
    try renderFrame(&app, p.theme, config, cursor);

    while (true) {
        switch (try terminal.readEvent(reader, stdin, &watcher)) {
            .resize => try renderFrame(&app, p.theme, config, cursor),
            .key => |k| {
                if (Prompts.isInterrupt(k, config.interrupt_keys)) {
                    try app.clear();
                    return error.Interrupted;
                }
                switch (k) {
                    .up => {
                        if (cursor > 0) cursor -= 1;
                        try renderFrame(&app, p.theme, config, cursor);
                    },
                    .down => {
                        if (cursor < config.choices.len - 1) cursor += 1;
                        try renderFrame(&app, p.theme, config, cursor);
                    },
                    .enter => {
                        try app.clear();
                        var obuf: [64]u8 = undefined;
                        const open = Prompts.openSeq(&obuf, p.theme, p.theme.promptTokens().selected);
                        try app.emit("  {s}{s}{s}", .{ open, config.choices[cursor], Prompts.closeSeq(open) });
                        return cursor;
                    },
                    .ctrl => |c| {
                        if (c == 'c') {
                            try app.clear();
                            return error.UserAborted;
                        }
                    },
                    else => {},
                }
            },
        }
    }
}

fn renderFrame(app: *ui.App, ctx: Prompts.ThemeContext, config: SelectConfig, cursor: usize) !void {
    try app.frame(try frameNode(app.arena(), ctx, config, cursor, lr.windowSize()));
}

/// Build the header + viewport-limited choice list as one frame. Pure and
/// size-explicit, so it is deterministic/testable (the emulator render tests
/// drive it through an App with a fixed terminal size).
pub fn frameNode(
    a: std.mem.Allocator,
    ctx: Prompts.ThemeContext,
    config: SelectConfig,
    cursor: usize,
    ws: terminal.Winsize,
) !ui.Node {
    const width = @max(@as(usize, ws.col), 1);
    // Leave the last column unused, matching the historical look (and the
    // row estimates below always agree with the painted layout).
    const usable: u16 = @intCast(@min(@max(width -| 1, 1), std.math.maxInt(u16)));
    const height = @max(@as(usize, ws.row), 2);

    const cursor_sym = terminal.symbols.select_cursor(config.unicode);
    // "  <cur> " and "    " are both 4 columns (single-column cursor glyph).
    const prefix_w: u16 = 4;
    const avail = @max(@as(usize, usable) -| prefix_w, 1);

    var rows = std.ArrayList(ui.Node).empty;

    // Header (any wrap hang-indents under the message text).
    const hprefix_w: u16 = @intCast(terminal.displayWidth(config.prefix));
    const havail: u16 = @intCast(@max(@as(usize, usable) -| hprefix_w, 1));
    try rows.append(a, try lr.itemRow(a, lr.prefixCell(.{}, config.prefix), hprefix_w, config.message, havail, .{}));
    const header_rows = terminal.wrapCount(config.message, havail);

    const Counter = struct {
        choices: []const []const u8,
        avail: usize,
        fn at(self: *const @This(), i: usize) usize {
            return terminal.wrapCount(self.choices[i], self.avail);
        }
    };
    const counter = Counter{ .choices = config.choices, .avail = avail };
    const list_budget = @max((height -| 1) -| header_rows, 1);
    const win = lr.viewport(config.choices.len, cursor, list_budget, &counter, Counter.at);

    const selected_style = ctx.resolveRef(ctx.promptTokens().selected);
    for (win.start..win.end) |i| {
        const on = i == cursor;
        const prefix = if (on)
            lr.prefixCell(selected_style, try std.fmt.allocPrint(a, "  {s} ", .{cursor_sym}))
        else
            lr.prefixCell(.{}, "");
        try rows.append(a, try lr.itemRow(a, prefix, prefix_w, config.choices[i], @intCast(avail), if (on) selected_style else .{}));
    }

    return ui.column(a, .{ .width = .{ .len = usable } }, rows.items);
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

pub const SelectError = error{NoChoices};

test "SelectConfig" {
    const cfg = SelectConfig{ .message = "Pick:", .choices = &.{ "a", "b" } };
    try std.testing.expectEqualStrings("Pick:", cfg.message);
    try std.testing.expect(cfg.choices.len == 2);
}

test "non-TTY: selects by number" {
    var input = "2\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [1024]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try select(.{ .writer = &output_writer, .reader = &input_reader, .allocator = std.testing.allocator }, .{
        .message = "Pick:",
        .choices = &.{ "alpha", "beta", "gamma" },
    });

    try std.testing.expectEqual(@as(usize, 1), result); // 2 => index 1
}

test "non-TTY: invalid number returns 0" {
    var input = "999\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [1024]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try select(.{ .writer = &output_writer, .reader = &input_reader, .allocator = std.testing.allocator }, .{
        .message = "Pick:",
        .choices = &.{ "a", "b" },
    });

    try std.testing.expectEqual(@as(usize, 0), result);
}

test "non-TTY: shows numbered choices" {
    var input = "1\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [1024]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    _ = try select(.{ .writer = &output_writer, .reader = &input_reader, .allocator = std.testing.allocator }, .{
        .message = "Pick:",
        .choices = &.{ "first", "second" },
    });

    const written = output_writer.buffer[0..output_writer.end];
    try std.testing.expect(std.mem.indexOf(u8, written, "1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "second") != null);
}

// ---------------------------------------------------------------------------
// Frame tests: measure/render the component as pure functions.
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

test "frameNode: header plus one row per short option" {
    var h = FrameHarness.init();
    defer h.deinit();
    const node = try frameNode(h.a(), Prompts.default_style, .{ .message = "Pick", .choices = &.{ "a", "b", "c" } }, 0, .{ .row = 24, .col = 80 });
    const rc = h.rctx();
    const size = ui.measure(&rc, &node, .{ .max_w = 100, .max_h = 50 });
    try std.testing.expectEqual(@as(u16, 4), size.h); // header + 3
}

test "frameNode: wrapped option occupies its true physical rows" {
    var h = FrameHarness.init();
    defer h.deinit();
    const long = "this is a long option label that will certainly wrap at a narrow width";
    const node = try frameNode(h.a(), Prompts.default_style, .{ .message = "Pick", .choices = &.{ "short", long } }, 0, .{ .row = 24, .col = 24 });
    const rc = h.rctx();
    const size = ui.measure(&rc, &node, .{ .max_w = 100, .max_h = 50 });
    try std.testing.expect(size.h > 3);
    // header(1) + short(1) + the long label's wrap count at the item width.
    const expected = 2 + terminal.wrapCount(long, 24 - 1 - 4);
    try std.testing.expectEqual(@as(u16, @intCast(expected)), size.h);
}

test "frameNode: selected row carries the theme's selected token" {
    var h = FrameHarness.init();
    defer h.deinit();
    const custom = Prompts.Theme{
        .palette = .{ .accent = .{ .foreground = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } } } },
    };
    const ctx = Prompts.ThemeContext{
        .theme = &custom,
        .caps = .{ .capability = .true_color, .is_tty = true, .color_enabled = true },
    };
    const node = try frameNode(h.a(), ctx, .{ .message = "Pick", .choices = &.{ "a", "b" } }, 0, .{ .row = 24, .col = 80 });

    var s = try ui.Surface.init(std.testing.allocator, 79, 3);
    defer s.deinit();
    const rc = h.rctx();
    try ui.render(&rc, &node, s.root());

    const selected_style = ctx.resolveRef(ctx.promptTokens().selected);
    // Row 1 is the cursor row: glyph cell and label cell styled; row 2 plain.
    try std.testing.expectEqualStrings("a", s.cellText(s.cell(4, 1)));
    try std.testing.expect(ui.styleEql(selected_style, s.cell(4, 1).style));
    try std.testing.expectEqualStrings("b", s.cellText(s.cell(4, 2)));
    try std.testing.expect(ui.styleEql(.{}, s.cell(4, 2).style));
}
