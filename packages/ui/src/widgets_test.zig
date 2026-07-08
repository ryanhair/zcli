//! Widget tests: pure component functions rendered onto a Surface.

const std = @import("std");
const theme_mod = @import("theme");
const ui = @import("ui.zig");
const widgets = @import("widgets.zig");

const testing = std.testing;

const Harness = struct {
    arena: std.heap.ArenaAllocator,

    fn init() Harness {
        return .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    }

    fn deinit(self: *Harness) void {
        self.arena.deinit();
    }

    fn a(self: *Harness) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn render(self: *Harness, node: ui.Node, s: *ui.Surface, unicode: bool) !void {
        const rctx = ui.RenderCtx{ .allocator = self.a(), .unicode = unicode };
        try ui.render(&rctx, &node, s.root());
    }
};

fn rowString(h: *Harness, s: *ui.Surface, y: u16) ![]u8 {
    var list = std.ArrayList(u8).empty;
    var x: u16 = 0;
    while (x < s.width) : (x += 1) {
        const c = s.cell(x, y);
        if (c.isContinuation()) continue;
        if (c.text_len == 0) {
            try list.append(h.a(), ' ');
        } else {
            try list.appendSlice(h.a(), s.cellText(c));
        }
    }
    return list.items;
}

test "spinner cycles its frames by tick and wears the theme token" {
    const t = theme_mod.default_theme;
    const s0 = widgets.spinner(.{}, 0);
    const s1 = widgets.spinner(.{}, 1);
    const wrapped = widgets.spinner(.{}, widgets.dots_frames.len);

    try testing.expectEqualStrings("⠋", s0.kind.text.content);
    try testing.expectEqualStrings("⠙", s1.kind.text.content);
    try testing.expectEqualStrings("⠋", wrapped.kind.text.content);
    const expected = t.progress.spinner.resolve(t.palette);
    try testing.expect(ui.styleEql(expected, s0.kind.text.style));
}

test "bar paints floor(fraction*width) filled cells in the token styles" {
    var h = Harness.init();
    defer h.deinit();
    var s = try ui.Surface.init(testing.allocator, 10, 1);
    defer s.deinit();

    try h.render(try widgets.bar(h.a(), .{}, 0.5), &s, true);
    try testing.expectEqualStrings("█████░░░░░", try rowString(&h, &s, 0));

    const t = theme_mod.default_theme;
    const fill_style = t.progress.bar_fill.resolve(t.palette);
    const empty_style = t.progress.bar_empty.resolve(t.palette);
    try testing.expect(ui.styleEql(fill_style, s.cell(0, 0).style));
    try testing.expect(ui.styleEql(empty_style, s.cell(9, 0).style));
}

test "bar clamps fraction and falls back to ascii without unicode" {
    var h = Harness.init();
    defer h.deinit();
    var s = try ui.Surface.init(testing.allocator, 8, 1);
    defer s.deinit();

    try h.render(try widgets.bar(h.a(), .{}, 1.7), &s, false);
    try testing.expectEqualStrings("########", try rowString(&h, &s, 0));

    s.clear();
    try h.render(try widgets.bar(h.a(), .{}, -3.0), &s, false);
    try testing.expectEqualStrings("--------", try rowString(&h, &s, 0));
}

test "multiBar aligns labels, bars, and percents into columns" {
    var h = Harness.init();
    defer h.deinit();
    var s = try ui.Surface.init(testing.allocator, 24, 2);
    defer s.deinit();

    const node = try widgets.multiBar(h.a(), .{}, &.{
        .{ .label = "api", .fraction = 0.5 },
        .{ .label = "assets", .fraction = 1.0 },
    });
    try h.render(node, &s, true);

    // label column = widest label (6), gap, bar fills 12, gap, percent 4.
    try testing.expectEqualStrings("api    ██████░░░░░░  50%", try rowString(&h, &s, 0));
    try testing.expectEqualStrings("assets ████████████ 100%", try rowString(&h, &s, 1));
}

test "multiBar truncates labels to a fixed label_width" {
    var h = Harness.init();
    defer h.deinit();
    var s = try ui.Surface.init(testing.allocator, 20, 1);
    defer s.deinit();

    const node = try widgets.multiBar(h.a(), .{ .label_width = 5, .show_percent = false }, &.{
        .{ .label = "very-long-name", .fraction = 0.0 },
    });
    try h.render(node, &s, true);
    try testing.expectEqualStrings("very… ░░░░░░░░░░░░░░", try rowString(&h, &s, 0));
}
