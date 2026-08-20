//! Single selection prompt with arrow key navigation.
//!
//! Rendering runs on the ui engine: each interaction paints one frame of a
//! node tree (diffed in place — navigation repaints only the rows that
//! changed), and the chosen answer is emitted as a static line that flows
//! into scrollback. The shared selection engine handles raw mode, key events,
//! and resize watching; the App is display-only.

const std = @import("std");
const terminal = @import("terminal");
const Prompts = @import("Prompts.zig");
const selection = @import("selection.zig");
const lr = @import("list_render.zig");
const ui = lr.ui;

pub const SelectConfig = struct {
    message: []const u8,
    choices: []const []const u8,
    prefix: []const u8 = "? ",
    unicode: bool = true,
    /// Enable type-to-filter. Printable characters except Space update the
    /// query; Space selects the highlighted result.
    search: bool = false,
    /// Keys the prompt should not handle itself: pressing one aborts the prompt
    /// with `error.Interrupted`. Empty = handle/ignore all keys.
    interrupt_keys: []const terminal.Key = &.{},
};

/// Prompt to select one item from a list. Returns the chosen index,
/// `error.Interrupted` if the user presses one of `config.interrupt_keys`,
/// `error.UserAborted` if the user presses Ctrl-C, `error.EndOfStream` if stdin
/// closes with no line to submit, or `error.InvalidSelection` if a non-TTY reply
/// is not a number naming one of the choices.
pub fn select(p: Prompts, config: SelectConfig) !usize {
    return selection.run(.one, p, selectionConfig(config));
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
    const filtered = try a.alloc(usize, config.choices.len);
    for (filtered, 0..) |*original, i| original.* = i;
    return frameNodeFiltered(a, ctx, config, "", filtered, cursor, ws);
}

/// Build a single-selection frame for an explicit query and filtered
/// original-choice index mapping. Query state is rendered when `config.search`
/// is enabled.
pub fn frameNodeFiltered(
    a: std.mem.Allocator,
    ctx: Prompts.ThemeContext,
    config: SelectConfig,
    query: []const u8,
    filtered: []const usize,
    cursor: usize,
    ws: terminal.Winsize,
) !ui.Node {
    return selection.frameNode(a, ctx, selectionConfig(config), .one, query, filtered, null, cursor, ws);
}

fn selectionConfig(config: SelectConfig) selection.Config {
    return .{
        .message = config.message,
        .choices = config.choices,
        .prefix = config.prefix,
        .unicode = config.unicode,
        .search = config.search,
        .interrupt_keys = config.interrupt_keys,
    };
}

pub const SelectError = error{ NoChoices, InvalidSelection };

test "SelectConfig" {
    const cfg = SelectConfig{ .message = "Pick:", .choices = &.{ "a", "b" } };
    try std.testing.expectEqualStrings("Pick:", cfg.message);
    try std.testing.expect(cfg.choices.len == 2);
    try std.testing.expect(!cfg.search);
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

test "non-TTY: out-of-range number errors instead of defaulting to index 0" {
    var input = "999\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [1024]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    try std.testing.expectError(error.InvalidSelection, select(.{ .writer = &output_writer, .reader = &input_reader, .allocator = std.testing.allocator }, .{
        .message = "Pick:",
        .choices = &.{ "a", "b" },
    }));
}

test "non-TTY: non-numeric input errors instead of defaulting to index 0" {
    var input = "banana\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [1024]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    try std.testing.expectError(error.InvalidSelection, select(.{ .writer = &output_writer, .reader = &input_reader, .allocator = std.testing.allocator }, .{
        .message = "Pick:",
        .choices = &.{ "a", "b" },
    }));
}

test "non-TTY: EOF errors instead of defaulting to index 0" {
    var input = "".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [1024]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    try std.testing.expectError(error.EndOfStream, select(.{ .writer = &output_writer, .reader = &input_reader, .allocator = std.testing.allocator }, .{
        .message = "Pick:",
        .choices = &.{ "a", "b" },
    }));
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

    try std.testing.expectEqualStrings("? Pick:\r\n  1) first\n  2) second\n> ", output_writer.buffer[0..output_writer.end]);
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

test "frameNodeFiltered: searchable header, query, and results measure their rows" {
    var h = FrameHarness.init();
    defer h.deinit();
    const filtered = [_]usize{ 0, 1, 2 };
    const node = try frameNodeFiltered(h.a(), Prompts.default_style, .{ .message = "Pick", .choices = &.{ "alpha", "beta", "gamma" }, .search = true }, "a", &filtered, 0, .{ .row = 24, .col = 80 });
    const rc = h.rctx();
    const size = ui.measure(&rc, &node, .{ .max_w = 100, .max_h = 50 });
    try std.testing.expectEqual(@as(u16, 5), size.h);

    var surface = try ui.Surface.init(std.testing.allocator, 79, 5);
    defer surface.deinit();
    try ui.render(&rc, &node, surface.root());
    const expected = "Pick (space/enter to select)";
    for (expected, 0..) |byte, x| {
        const cell = surface.cell(@intCast(x + 2), 0);
        if (byte == ' ') {
            try std.testing.expect(cell.isBlank());
        } else {
            try std.testing.expectEqualStrings(&.{byte}, surface.cellText(cell));
        }
    }
}

test "frameNodeFiltered: empty query uses the hint style" {
    var h = FrameHarness.init();
    defer h.deinit();
    const custom = Prompts.Theme{
        .prompts = .{ .hint = .{ .style = .{ .foreground = .{ .rgb = .{ .r = 7, .g = 7, .b = 7 } } } } },
    };
    const ctx = Prompts.ThemeContext{
        .theme = &custom,
        .caps = .{ .capability = .true_color, .is_tty = true, .color_enabled = true },
    };
    const node = try frameNodeFiltered(h.a(), ctx, .{ .message = "Pick", .choices = &.{ "a", "b" }, .search = true }, "", &.{ 0, 1 }, 0, .{ .row = 24, .col = 80 });

    var surface = try ui.Surface.init(std.testing.allocator, 79, 4);
    defer surface.deinit();
    const rc = h.rctx();
    try ui.render(&rc, &node, surface.root());

    try std.testing.expectEqualStrings("t", surface.cellText(surface.cell(10, 1)));
    try std.testing.expect(ui.styleEql(ctx.resolveRef(ctx.promptTokens().hint), surface.cell(10, 1).style));
}

test "frameNodeFiltered: no matches uses three rows" {
    var h = FrameHarness.init();
    defer h.deinit();
    const node = try frameNodeFiltered(h.a(), Prompts.default_style, .{ .message = "Pick", .choices = &.{ "a", "b" }, .search = true }, "zz", &.{}, 0, .{ .row = 24, .col = 80 });
    const rc = h.rctx();
    const size = ui.measure(&rc, &node, .{ .max_w = 100, .max_h = 50 });
    try std.testing.expectEqual(@as(u16, 3), size.h);
}
