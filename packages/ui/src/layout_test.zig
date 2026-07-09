//! Layout tests: measure and render as pure functions over Limits, painted
//! onto a Surface directly (no terminal, no escape parsing — those live in
//! golden_test.zig).

const std = @import("std");
const ui = @import("ui.zig");
const node_mod = @import("node.zig");

const testing = std.testing;

const Harness = struct {
    arena: std.heap.ArenaAllocator,

    fn init() Harness {
        return .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    }

    fn deinit(self: *Harness) void {
        self.arena.deinit();
    }

    fn ctx(self: *Harness) ui.RenderCtx {
        return .{ .allocator = self.arena.allocator() };
    }

    fn a(self: *Harness) std.mem.Allocator {
        return self.arena.allocator();
    }
};

/// Render `node` into a fresh surface of the given size and return the given
/// row as a plain string (blanks as spaces) for easy assertions.
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

fn renderInto(h: *Harness, node: ui.Node, s: *ui.Surface) !void {
    const rctx = h.ctx();
    try ui.render(&rctx, &node, s.root());
}

// ============================================================================
// Measure
// ============================================================================

test "text measures wrapped: constrained width produces lines" {
    var h = Harness.init();
    defer h.deinit();
    const rctx = h.ctx();

    const n = ui.text(.{}, "hello world");
    try testing.expectEqual(ui.Size{ .w = 11, .h = 1 }, ui.measure(&rctx, &n, .{ .max_w = 20, .max_h = 10 }));
    try testing.expectEqual(ui.Size{ .w = 5, .h = 2 }, ui.measure(&rctx, &n, .{ .max_w = 7, .max_h = 10 }));
    // Height offer caps the reported lines.
    try testing.expectEqual(ui.Size{ .w = 5, .h = 1 }, ui.measure(&rctx, &n, .{ .max_w = 5, .max_h = 1 }));
}

test "truncating text is always one line" {
    var h = Harness.init();
    defer h.deinit();
    const rctx = h.ctx();

    const n = ui.textOpts(.{ .wrap = .truncate }, "hello world");
    try testing.expectEqual(ui.Size{ .w = 7, .h = 1 }, ui.measure(&rctx, &n, .{ .max_w = 7, .max_h = 10 }));
}

test "column stacks fit children; gap counts" {
    var h = Harness.init();
    defer h.deinit();
    const rctx = h.ctx();

    const plain = try ui.column(h.a(), .{}, &.{
        ui.text(.{}, "aa"),
        ui.text(.{}, "bbb"),
    });
    try testing.expectEqual(ui.Size{ .w = 3, .h = 2 }, ui.measure(&rctx, &plain, .{ .max_w = 20, .max_h = 20 }));

    const gapped = try ui.column(h.a(), .{ .gap = 1 }, &.{
        ui.text(.{}, "aa"),
        ui.text(.{}, "bbb"),
    });
    try testing.expectEqual(ui.Size{ .w = 3, .h = 3 }, ui.measure(&rctx, &gapped, .{ .max_w = 20, .max_h = 20 }));
}

test "border and padding are chrome on both axes" {
    var h = Harness.init();
    defer h.deinit();
    const rctx = h.ctx();

    const n = try ui.column(h.a(), .{ .border = .single, .padding = .all(1) }, &.{
        ui.text(.{}, "hi"),
    });
    try testing.expectEqual(ui.Size{ .w = 6, .h = 5 }, ui.measure(&rctx, &n, .{ .max_w = 20, .max_h = 20 }));
}

test "a .len dim measures as exactly n, not content size" {
    var h = Harness.init();
    defer h.deinit();
    const rctx = h.ctx();

    const n = ui.textOpts(.{ .width = .{ .len = 10 } }, "ab");
    try testing.expectEqual(ui.Size{ .w = 10, .h = 1 }, ui.measure(&rctx, &n, .{ .max_w = 20, .max_h = 20 }));
    // ...but never more than the offer.
    try testing.expectEqual(ui.Size{ .w = 6, .h = 1 }, ui.measure(&rctx, &n, .{ .max_w = 6, .max_h = 20 }));
}

test "min_width raises a measured size within the offer" {
    var h = Harness.init();
    defer h.deinit();
    const rctx = h.ctx();

    var n = ui.text(.{}, "ab");
    n.min_width = 8;
    try testing.expectEqual(ui.Size{ .w = 8, .h = 1 }, ui.measure(&rctx, &n, .{ .max_w = 20, .max_h = 20 }));
    try testing.expectEqual(ui.Size{ .w = 5, .h = 1 }, ui.measure(&rctx, &n, .{ .max_w = 5, .max_h = 20 }));
}

test "fill children contribute nothing at measure time" {
    var h = Harness.init();
    defer h.deinit();
    const rctx = h.ctx();

    const n = try ui.row(h.a(), .{}, &.{
        ui.text(.{}, "ab"),
        ui.spacer(),
        ui.text(.{}, "cd"),
    });
    try testing.expectEqual(ui.Size{ .w = 4, .h = 1 }, ui.measure(&rctx, &n, .{ .max_w = 40, .max_h = 5 }));
}

// ============================================================================
// Render
// ============================================================================

test "spacer pushes trailing content to the right edge" {
    var h = Harness.init();
    defer h.deinit();
    var s = try ui.Surface.init(testing.allocator, 10, 1);
    defer s.deinit();

    const n = try ui.row(h.a(), .{}, &.{
        ui.text(.{}, "ab"),
        ui.spacer(),
        ui.text(.{}, "cd"),
    });
    try renderInto(&h, n, &s);
    try testing.expectEqualStrings("ab      cd", try rowString(&h, &s, 0));
}

test "fill weights split leftover space with exact sum" {
    var h = Harness.init();
    defer h.deinit();
    var s = try ui.Surface.init(testing.allocator, 10, 1);
    defer s.deinit();

    // budget 10, weights 1:3 → floor 2/7, remainders tie, first child wins → 3/7.
    const n = try ui.row(h.a(), .{}, &.{
        ui.textOpts(.{ .width = .{ .fill = 1 }, .wrap = .clip }, "aaaaaaaaaa"),
        ui.textOpts(.{ .width = .{ .fill = 3 }, .wrap = .clip }, "bbbbbbbbbb"),
    });
    try renderInto(&h, n, &s);
    try testing.expectEqualStrings("aaabbbbbbb", try rowString(&h, &s, 0));
}

test "equal weights: largest-remainder gives earlier children the extras" {
    var h = Harness.init();
    defer h.deinit();
    var s = try ui.Surface.init(testing.allocator, 10, 1);
    defer s.deinit();

    const n = try ui.row(h.a(), .{}, &.{
        ui.textOpts(.{ .width = .{ .fill = 1 }, .wrap = .clip }, "aaaaaaaaaa"),
        ui.textOpts(.{ .width = .{ .fill = 1 }, .wrap = .clip }, "bbbbbbbbbb"),
        ui.textOpts(.{ .width = .{ .fill = 1 }, .wrap = .clip }, "cccccccccc"),
    });
    try renderInto(&h, n, &s);
    try testing.expectEqualStrings("aaaabbbccc", try rowString(&h, &s, 0));
}

test "fit is measured in declaration order against what remains" {
    var h = Harness.init();
    defer h.deinit();
    var s = try ui.Surface.init(testing.allocator, 8, 1);
    defer s.deinit();

    // First fit child takes its natural 6; the second gets the leftover 2.
    const n = try ui.row(h.a(), .{}, &.{
        ui.textOpts(.{ .wrap = .clip }, "aaaaaa"),
        ui.textOpts(.{ .wrap = .clip }, "bbbbbb"),
    });
    try renderInto(&h, n, &s);
    try testing.expectEqualStrings("aaaaaabb", try rowString(&h, &s, 0));
}

test "column wraps text at the box width" {
    var h = Harness.init();
    defer h.deinit();
    var s = try ui.Surface.init(testing.allocator, 7, 2);
    defer s.deinit();

    const n = try ui.column(h.a(), .{}, &.{
        ui.text(.{}, "hello world"),
    });
    try renderInto(&h, n, &s);
    try testing.expectEqualStrings("hello  ", try rowString(&h, &s, 0));
    try testing.expectEqualStrings("world  ", try rowString(&h, &s, 1));
}

test "border draws around padded content" {
    var h = Harness.init();
    defer h.deinit();
    var s = try ui.Surface.init(testing.allocator, 6, 3);
    defer s.deinit();

    const n = try ui.column(h.a(), .{ .border = .rounded, .width = .{ .fill = 1 }, .height = .{ .fill = 1 } }, &.{
        ui.text(.{}, "hi"),
    });
    try renderInto(&h, n, &s);
    try testing.expectEqualStrings("╭────╮", try rowString(&h, &s, 0));
    try testing.expectEqualStrings("│hi  │", try rowString(&h, &s, 1));
    try testing.expectEqualStrings("╰────╯", try rowString(&h, &s, 2));
}

test "align_self centers and ends on the cross axis" {
    var h = Harness.init();
    defer h.deinit();
    var s = try ui.Surface.init(testing.allocator, 10, 2);
    defer s.deinit();

    const n = try ui.column(h.a(), .{}, &.{
        ui.textOpts(.{ .width = .fit, .align_self = .center }, "ab"),
        ui.textOpts(.{ .width = .fit, .align_self = .end }, "cd"),
    });
    try renderInto(&h, n, &s);
    try testing.expectEqualStrings("    ab    ", try rowString(&h, &s, 0));
    try testing.expectEqualStrings("        cd", try rowString(&h, &s, 1));
}

test "truncate renders an ellipsis at the clip point" {
    var h = Harness.init();
    defer h.deinit();
    var s = try ui.Surface.init(testing.allocator, 5, 1);
    defer s.deinit();

    const n = ui.textOpts(.{ .wrap = .truncate }, "abcdefgh");
    try renderInto(&h, n, &s);
    try testing.expectEqualStrings("abcd…", try rowString(&h, &s, 0));
}

test "custom leaf measures and renders through its vtable" {
    var h = Harness.init();
    defer h.deinit();
    var s = try ui.Surface.init(testing.allocator, 8, 1);
    defer s.deinit();

    const Gauge = struct {
        fn measureFn(_: *anyopaque, _: *const ui.RenderCtx, limits: ui.Limits) ui.Size {
            return .{ .w = @min(3, limits.max_w), .h = @min(1, limits.max_h) };
        }
        fn renderFn(_: *anyopaque, _: *const ui.RenderCtx, region: ui.Region) anyerror!void {
            _ = try region.writeText(0, 0, "xyz", .{});
        }
    };
    var payload: u8 = 0;
    const n = ui.Node{ .kind = .{ .custom = .{
        .context = @ptrCast(&payload),
        .measureFn = Gauge.measureFn,
        .renderFn = Gauge.renderFn,
    } } };

    const rctx = h.ctx();
    try testing.expectEqual(ui.Size{ .w = 3, .h = 1 }, ui.measure(&rctx, &n, .{ .max_w = 8, .max_h = 4 }));
    try renderInto(&h, n, &s);
    try testing.expectEqualStrings("xyz     ", try rowString(&h, &s, 0));
}

test "component functions compose: children are arena-copied, not borrowed" {
    var h = Harness.init();
    defer h.deinit();
    var s = try ui.Surface.init(testing.allocator, 12, 1);
    defer s.deinit();

    const Component = struct {
        // The child slice literal here is a stack temporary of THIS call —
        // the builder must copy it for the returned node to stay valid.
        fn statusLine(a: std.mem.Allocator) !ui.Node {
            return ui.row(a, .{}, &.{
                ui.text(.{}, "ok"),
                ui.spacer(),
                ui.text(.{}, "3s"),
            });
        }
    };

    const n = try ui.column(h.a(), .{}, &.{
        try Component.statusLine(h.a()),
    });
    try renderInto(&h, n, &s);
    try testing.expectEqualStrings("ok        3s", try rowString(&h, &s, 0));
}

// ============================================================================
// Stack (z-layers / overlays, ADR-0016)
// ============================================================================

test "stack measures to its largest child on both axes" {
    var h = Harness.init();
    defer h.deinit();
    const rctx = h.ctx();

    const n = try ui.stack(h.a(), .{}, &.{
        ui.textOpts(.{ .wrap = .clip }, "wide text"), // 9 x 1
        try ui.column(h.a(), .{}, &.{ ui.text(.{}, "a"), ui.text(.{}, "b") }), // 1 x 2
    });
    // Layers overlap, so the stack is the widest AND the tallest child.
    try testing.expectEqual(
        ui.Size{ .w = 9, .h = 2 },
        ui.measure(&rctx, &n, .{ .max_w = 20, .max_h = 10 }),
    );
}

test "stack paints layers back to front; a later layer wins shared cells" {
    var h = Harness.init();
    defer h.deinit();
    var s = try ui.Surface.init(testing.allocator, 4, 1);
    defer s.deinit();

    const n = try ui.stack(h.a(), .{}, &.{
        ui.textOpts(.{ .wrap = .clip }, "...."), // base fills the row
        ui.textOpts(.{ .wrap = .clip }, "AB"), // top layer covers two cells
    });
    try renderInto(&h, n, &s);
    // Top layer wins cols 0-1; its untouched cols 2-3 show the base through.
    try testing.expectEqualStrings("AB..", try rowString(&h, &s, 0));
}

test "an opaque layer erases the base beneath while the scaffold stays transparent" {
    var h = Harness.init();
    defer h.deinit();
    var s = try ui.Surface.init(testing.allocator, 3, 3);
    defer s.deinit();

    const n = try ui.stack(h.a(), .{}, &.{
        // Base: fills 3x3 with a reverse-styled background.
        try ui.column(h.a(), .{ .style = .{ .reverse = true } }, &.{}),
        // Modal: a 1x1 bold cell, centered → lands on the middle cell (1,1).
        try ui.center(h.a(), try ui.column(h.a(), .{
            .width = .{ .len = 1 },
            .height = .{ .len = 1 },
            .style = .{ .bold = true },
        }, &.{})),
    });
    try renderInto(&h, n, &s);
    // The opaque modal replaced the base on its own cell...
    try testing.expect(s.cell(1, 1).style.bold and !s.cell(1, 1).style.reverse);
    // ...but the style-less centering scaffold left the base intact elsewhere.
    try testing.expect(s.cell(0, 0).style.reverse and !s.cell(0, 0).style.bold);
    try testing.expect(s.cell(2, 2).style.reverse);
}

test "a stack carries box chrome: a border insets its layers" {
    var h = Harness.init();
    defer h.deinit();
    var s = try ui.Surface.init(testing.allocator, 4, 3);
    defer s.deinit();

    const n = try ui.stack(h.a(), .{ .border = .single }, &.{
        ui.textOpts(.{ .wrap = .clip }, "XX"),
    });
    try renderInto(&h, n, &s);
    try testing.expectEqualStrings("┌──┐", try rowString(&h, &s, 0));
    try testing.expectEqualStrings("│XX│", try rowString(&h, &s, 1));
    try testing.expectEqualStrings("└──┘", try rowString(&h, &s, 2));
}

// ============================================================================
// Viewport (scrollable window, ADR-0017)
// ============================================================================

fn sixLines(a: std.mem.Allocator) !ui.Node {
    const labels = [_][]const u8{ "L0", "L1", "L2", "L3", "L4", "L5" };
    var lines: [6]ui.Node = undefined;
    for (&lines, labels) |*n, lbl| n.* = ui.textOpts(.{ .wrap = .clip }, lbl);
    return ui.column(a, .{}, &lines);
}

test "viewport windows tall content at scroll_y" {
    var h = Harness.init();
    defer h.deinit();

    var top = try ui.Surface.init(testing.allocator, 4, 3);
    defer top.deinit();
    try renderInto(&h, try ui.viewport(h.a(), .{ .scroll_y = 0 }, try sixLines(h.a())), &top);
    try testing.expectEqualStrings("L0  ", try rowString(&h, &top, 0));
    try testing.expectEqualStrings("L1  ", try rowString(&h, &top, 1));
    try testing.expectEqualStrings("L2  ", try rowString(&h, &top, 2));

    var mid = try ui.Surface.init(testing.allocator, 4, 3);
    defer mid.deinit();
    try renderInto(&h, try ui.viewport(h.a(), .{ .scroll_y = 2 }, try sixLines(h.a())), &mid);
    try testing.expectEqualStrings("L2  ", try rowString(&h, &mid, 0));
    try testing.expectEqualStrings("L3  ", try rowString(&h, &mid, 1));
    try testing.expectEqualStrings("L4  ", try rowString(&h, &mid, 2));
}

test "viewport clamps an overscroll to the last page" {
    var h = Harness.init();
    defer h.deinit();
    var s = try ui.Surface.init(testing.allocator, 4, 3);
    defer s.deinit();
    // 6 lines, 3-row window, scroll_y way past the end → rests on L3,L4,L5.
    try renderInto(&h, try ui.viewport(h.a(), .{ .scroll_y = 100 }, try sixLines(h.a())), &s);
    try testing.expectEqualStrings("L3  ", try rowString(&h, &s, 0));
    try testing.expectEqualStrings("L4  ", try rowString(&h, &s, 1));
    try testing.expectEqualStrings("L5  ", try rowString(&h, &s, 2));
}

test "viewport shorter than its window leaves trailing rows untouched" {
    var h = Harness.init();
    defer h.deinit();
    var s = try ui.Surface.init(testing.allocator, 4, 4);
    defer s.deinit();
    _ = try s.root().writeText(0, 3, "ZZ", .{}); // sits beneath the viewport

    const content = try ui.column(h.a(), .{}, &.{
        ui.textOpts(.{ .wrap = .clip }, "AA"),
        ui.textOpts(.{ .wrap = .clip }, "BB"),
    });
    try renderInto(&h, try ui.viewport(h.a(), .{}, content), &s);
    try testing.expectEqualStrings("AA  ", try rowString(&h, &s, 0));
    try testing.expectEqualStrings("BB  ", try rowString(&h, &s, 1));
    try testing.expectEqualStrings("    ", try rowString(&h, &s, 2)); // no content, untouched
    try testing.expectEqualStrings("ZZ  ", try rowString(&h, &s, 3)); // shows through
}
