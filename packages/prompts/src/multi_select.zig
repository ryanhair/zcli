//! Multi-selection prompt with optional focusless type-to-filter search.

const std = @import("std");
const terminal = @import("terminal");
const Prompts = @import("Prompts.zig");
const selection = @import("selection.zig");
const ui = @import("list_render.zig").ui;

pub const MultiSelectConfig = struct {
    message: []const u8,
    choices: []const []const u8,
    defaults: ?[]const bool = null,
    prefix: []const u8 = "? ",
    unicode: bool = true,
    /// Enable type-to-filter. Printable characters except Space update the
    /// query; Space toggles the highlighted result.
    search: bool = false,
    /// Keys the prompt should not handle itself: pressing one aborts the prompt
    /// with `error.Interrupted`. Empty = handle/ignore all keys.
    interrupt_keys: []const terminal.Key = &.{},
};

/// Prompt to select multiple items. Returns an owned slice of original choice
/// indices. Search filtering never clears selections that become hidden.
pub fn multiSelect(p: Prompts, config: MultiSelectConfig) ![]usize {
    return selection.run(.many, p, selectionConfig(config));
}

/// Build the initial header and viewport-limited choice list as one frame.
/// Search-enabled configs include the empty-query search row.
pub fn frameNode(
    a: std.mem.Allocator,
    ctx: Prompts.ThemeContext,
    config: MultiSelectConfig,
    selected: []const bool,
    cursor: usize,
    ws: terminal.Winsize,
) !ui.Node {
    const filtered = try a.alloc(usize, config.choices.len);
    for (filtered, 0..) |*original, i| original.* = i;
    return selection.frameNode(a, ctx, selectionConfig(config), .many, "", filtered, selected, cursor, ws);
}

fn selectionConfig(config: MultiSelectConfig) selection.Config {
    return .{
        .message = config.message,
        .choices = config.choices,
        .defaults = config.defaults,
        .prefix = config.prefix,
        .unicode = config.unicode,
        .search = config.search,
        .interrupt_keys = config.interrupt_keys,
    };
}

test "MultiSelectConfig defaults" {
    const cfg = MultiSelectConfig{ .message = "Pick:", .choices = &.{ "a", "b" } };
    try std.testing.expect(cfg.defaults == null);
    try std.testing.expect(!cfg.search);
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
        .search = true,
    });
    defer allocator.free(result);

    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, result);
    try std.testing.expectEqualStrings("? Pick: (space to toggle, enter to confirm)\r\n  1) [ ] a\n  2) [ ] b\n  3) [ ] c\n> ", output_writer.buffer[0..output_writer.end]);
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

    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, result);
}

test "non-TTY: no defaults returns an owned empty slice" {
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
    var input = "".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [1024]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    try std.testing.expectError(error.EndOfStream, multiSelect(.{ .writer = &output_writer, .reader = &input_reader, .allocator = std.testing.allocator }, .{
        .message = "Pick:",
        .choices = &.{ "a", "b", "c" },
        .defaults = &.{ true, false, true },
    }));
}

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
    try std.testing.expectEqual(@as(u16, 4), size.h);
}

test "frameNode: searchable config adds the focusless query row" {
    var h = FrameHarness.init();
    defer h.deinit();
    const node = try frameNode(h.a(), Prompts.default_style, .{ .message = "Pick", .choices = &.{ "a", "b" }, .search = true }, &.{ false, false }, 0, .{ .row = 24, .col = 80 });
    const rc = h.rctx();
    const size = ui.measure(&rc, &node, .{ .max_w = 100, .max_h = 50 });
    try std.testing.expectEqual(@as(u16, 4), size.h);
}

test "frameNode: a wrapping option measures its true physical rows" {
    var h = FrameHarness.init();
    defer h.deinit();
    const long = "this is a long option label that will certainly wrap at a narrow width";
    const node = try frameNode(h.a(), Prompts.default_style, .{ .message = "Pick", .choices = &.{ "short", long } }, &.{ false, false }, 0, .{ .row = 24, .col = 24 });
    const rc = h.rctx();
    const size = ui.measure(&rc, &node, .{ .max_w = 100, .max_h = 50 });
    try std.testing.expect(size.h > 3);
    const header_rows = terminal.wrapCount("Pick (space to toggle, enter to confirm)", 23 - 2);
    const prefix_w = 5 + terminal.displayWidth(Prompts.default_style.glyphTokens().selected.pick(true));
    const expected = header_rows + 1 + terminal.wrapCount(long, 23 - prefix_w);
    try std.testing.expectEqual(@as(u16, @intCast(expected)), size.h);
}

test "frameNode: cursor and marker use their theme tokens" {
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

    var surface = try ui.Surface.init(std.testing.allocator, 79, 3);
    defer surface.deinit();
    const rc = h.rctx();
    try ui.render(&rc, &node, surface.root());

    try std.testing.expect(ui.styleEql(ctx.resolveRef(ctx.promptTokens().cursor), surface.cell(2, 1).style));
    try std.testing.expect(ui.styleEql(ctx.resolveRef(ctx.promptTokens().marker), surface.cell(4, 1).style));
    try std.testing.expect(ui.styleEql(.{}, surface.cell(4, 2).style));
}

test "frameNode: continuation lines hang-indent under the option text" {
    var h = FrameHarness.init();
    defer h.deinit();
    const node = try frameNode(h.a(), Prompts.default_style, .{ .message = "Pick", .choices = &.{"alpha bravo charlie delta"}, .unicode = false }, &.{false}, 0, .{ .row = 24, .col = 20 });

    var surface = try ui.Surface.init(std.testing.allocator, 19, 8);
    defer surface.deinit();
    const rc = h.rctx();
    try ui.render(&rc, &node, surface.root());

    const option_row: u16 = @intCast(terminal.wrapCount("Pick (space to toggle, enter to confirm)", 19 - 2));
    try std.testing.expectEqualStrings("[", surface.cellText(surface.cell(4, option_row)));
    try std.testing.expectEqualStrings("a", surface.cellText(surface.cell(8, option_row)));
    var x: u16 = 0;
    while (x < 8) : (x += 1) try std.testing.expect(surface.cell(x, option_row + 1).isBlank());
    try std.testing.expect(!surface.cell(8, option_row + 1).isBlank());
}
