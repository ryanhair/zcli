//! Compatibility wrapper for searchable single selection.

const std = @import("std");
const terminal = @import("terminal");
const Prompts = @import("Prompts.zig");
const selection = @import("selection.zig");
const ui = @import("list_render.zig").ui;

/// Compatibility configuration for `search`. New code can equivalently call
/// `select` with `.search = true`.
pub const SearchConfig = struct {
    message: []const u8,
    choices: []const []const u8,
    prefix: []const u8 = "? ",
    unicode: bool = true,
    interrupt_keys: []const terminal.Key = &.{},
};

/// Searchable single selection, retained as a compatibility surface. This is
/// exactly `select` with search forced on.
pub fn search(p: Prompts, config: SearchConfig) !usize {
    return selection.run(.one, p, selectionConfig(config));
}

/// Build a searchable single-selection frame for compatibility with existing
/// render tests and custom renderers.
pub fn frameNode(
    a: std.mem.Allocator,
    ctx: Prompts.ThemeContext,
    config: SearchConfig,
    query: []const u8,
    filtered: []const usize,
    cursor: usize,
    ws: terminal.Winsize,
) !ui.Node {
    return selection.frameNode(a, ctx, selectionConfig(config), .one, query, filtered, null, cursor, ws);
}

fn selectionConfig(config: SearchConfig) selection.Config {
    return .{
        .message = config.message,
        .choices = config.choices,
        .prefix = config.prefix,
        .unicode = config.unicode,
        .search = true,
        .interrupt_keys = config.interrupt_keys,
        .non_tty_header_newline = "\n",
    };
}

test "containsIgnoreCase" {
    try std.testing.expect(selection.containsIgnoreCase("Fastify", "fast"));
    try std.testing.expect(selection.containsIgnoreCase("fastify", "FAST"));
    try std.testing.expect(selection.containsIgnoreCase("express", "press"));
    try std.testing.expect(!selection.containsIgnoreCase("koa", "express"));
    try std.testing.expect(selection.containsIgnoreCase("anything", ""));
}

test "buildFiltered preserves original indices" {
    const result = try selection.buildFiltered(std.testing.allocator, &.{ "express", "fastify", "koa" }, "fa");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(usize, &.{1}, result);
}

test "buildFiltered failure leaves an existing slice owned by its caller" {
    const allocator = std.testing.allocator;
    const choices = &[_][]const u8{ "alpha", "beta", "gamma" };
    const filtered = try selection.buildFiltered(allocator, choices, "");
    defer allocator.free(filtered);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, selection.buildFiltered(failing.allocator(), choices, "a"));
    try std.testing.expectEqual(@as(usize, 3), filtered.len);
}

test "SearchConfig compatibility defaults" {
    const cfg = SearchConfig{ .message = "Pick:", .choices = &.{ "a", "b" } };
    try std.testing.expectEqualStrings("? ", cfg.prefix);
    try std.testing.expectEqual(@as(usize, 0), cfg.interrupt_keys.len);
}

test "non-TTY search uses select parsing" {
    var input = "2\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [1024]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try search(.{ .writer = &output_writer, .reader = &input_reader, .allocator = std.testing.allocator }, .{
        .message = "Pick:",
        .choices = &.{ "a", "b" },
    });
    try std.testing.expectEqual(@as(usize, 1), result);
    try std.testing.expectEqualStrings("? Pick:\n  1) a\n  2) b\n> ", output_writer.buffer[0..output_writer.end]);
}

test "non-TTY search rejects EOF, invalid, and out-of-range replies" {
    for ([_][]const u8{ "", "banana\n", "999\n" }, 0..) |bytes, i| {
        var input_reader: std.Io.Reader = .fixed(bytes);
        var output: [1024]u8 = undefined;
        var output_writer: std.Io.Writer = .fixed(&output);
        const result = search(.{ .writer = &output_writer, .reader = &input_reader, .allocator = std.testing.allocator }, .{
            .message = "Pick:",
            .choices = &.{ "a", "b" },
        });
        if (i == 0) {
            try std.testing.expectError(error.EndOfStream, result);
        } else {
            try std.testing.expectError(error.InvalidSelection, result);
        }
    }
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

test "frameNode: header, query, and results measure their rows" {
    var h = FrameHarness.init();
    defer h.deinit();
    const filtered = [_]usize{ 0, 1, 2 };
    const node = try frameNode(h.a(), Prompts.default_style, .{ .message = "Pick", .choices = &.{ "alpha", "beta", "gamma" } }, "a", &filtered, 0, .{ .row = 24, .col = 80 });
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

test "frameNode: empty query shows the hint-styled placeholder" {
    var h = FrameHarness.init();
    defer h.deinit();
    const custom = Prompts.Theme{
        .prompts = .{ .hint = .{ .style = .{ .foreground = .{ .rgb = .{ .r = 7, .g = 7, .b = 7 } } } } },
    };
    const ctx = Prompts.ThemeContext{
        .theme = &custom,
        .caps = .{ .capability = .true_color, .is_tty = true, .color_enabled = true },
    };
    const node = try frameNode(h.a(), ctx, .{ .message = "Pick", .choices = &.{ "a", "b" } }, "", &.{ 0, 1 }, 0, .{ .row = 24, .col = 80 });

    var surface = try ui.Surface.init(std.testing.allocator, 79, 4);
    defer surface.deinit();
    const rc = h.rctx();
    try ui.render(&rc, &node, surface.root());

    try std.testing.expectEqualStrings("t", surface.cellText(surface.cell(10, 1)));
    try std.testing.expect(ui.styleEql(ctx.resolveRef(ctx.promptTokens().hint), surface.cell(10, 1).style));
}

test "frameNode: no matches renders only the hint row after the query" {
    var h = FrameHarness.init();
    defer h.deinit();
    const node = try frameNode(h.a(), Prompts.default_style, .{ .message = "Pick", .choices = &.{ "a", "b" } }, "zz", &.{}, 0, .{ .row = 24, .col = 80 });
    const rc = h.rctx();
    const size = ui.measure(&rc, &node, .{ .max_w = 100, .max_h = 50 });
    try std.testing.expectEqual(@as(u16, 3), size.h);
}
