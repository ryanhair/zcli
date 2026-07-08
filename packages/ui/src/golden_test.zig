//! Golden-frame tests: paint through the diff renderer into a real (virtual)
//! terminal and assert on what a user would see. This is the behavior-level
//! complement to the byte-level tests in diff.zig — vterm parses the actual
//! escape stream, so these tests catch addressing and SGR mistakes that
//! byte-golden strings would bake in.
//!
//! vterm's parser speaks 16-color SGR (bold/italic/underline), so everything
//! here renders at `.ansi_16`.

const std = @import("std");
const vterm = @import("vterm");
const ui = @import("ui.zig");
const diff = @import("diff.zig");
const surface_mod = @import("surface.zig");

const Surface = surface_mod.Surface;
const Renderer = diff.Renderer;
const VTerm = vterm.VTerm;

const testing = std.testing;

fn paintInto(vt: *VTerm, r: Renderer, prev: ?*const Surface, next: *const Surface) !void {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try r.paint(&aw.writer, prev, next);
    vt.write(aw.written());
}

test "full paint: text, attributes, colors land where the surface says" {
    var vt = try VTerm.init(testing.allocator, 12, 4);
    defer vt.deinit();
    var s = try Surface.init(testing.allocator, 12, 3);
    defer s.deinit();

    _ = try s.root().writeText(0, 0, "hello", .{ .bold = true });
    _ = try s.root().writeText(0, 1, "你好", .{});
    _ = try s.root().writeText(2, 2, "end", .{ .foreground = .red });

    try paintInto(&vt, .{ .capability = .ansi_16 }, null, &s);

    try testing.expect(vt.containsText("hello"));
    try testing.expect(vt.hasAttribute(0, 0, .bold));
    try testing.expectEqual(@as(u21, '你'), vt.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, '好'), vt.getCell(2, 1).char);
    try testing.expect(vt.containsText("end"));
    try testing.expectEqual(vterm.Color.red, vt.getTextColor(2, 2));
    // Styles must not bleed between runs: row 1 is unstyled.
    try testing.expect(!vt.hasAttribute(0, 1, .bold));
    // The renderer parks the cursor back at the region's top-left.
    try testing.expect(vt.cursorAt(0, 0));
}

test "full paint erases stale content on painted rows only" {
    var vt = try VTerm.init(testing.allocator, 8, 3);
    defer vt.deinit();
    // Fill the terminal with junk (7 X's per 8-wide row — a full row would
    // autowrap and scroll), then park the cursor at the region origin.
    vt.write("XXXXXXX\r\nXXXXXXX\r\nXXXXXXX\x1b[H");

    var s = try Surface.init(testing.allocator, 8, 2);
    defer s.deinit();
    _ = try s.root().writeText(0, 0, "ok", .{});

    try paintInto(&vt, .{ .capability = .ansi_16 }, null, &s);

    try testing.expect(vt.containsText("ok"));
    // EL cleared the rest of both painted rows...
    try testing.expectEqual(@as(u21, 0), vt.getCell(5, 0).char);
    try testing.expectEqual(@as(u21, 0), vt.getCell(0, 1).char);
    // ...but the row below the region was never touched.
    try testing.expectEqual(@as(u21, 'X'), vt.getCell(0, 2).char);
}

test "diff paint updates the changed cells and leaves the rest intact" {
    var vt = try VTerm.init(testing.allocator, 20, 3);
    defer vt.deinit();

    var frame1 = try Surface.init(testing.allocator, 20, 2);
    defer frame1.deinit();
    _ = try frame1.root().writeText(0, 0, "building...", .{});
    _ = try frame1.root().writeText(0, 1, "elapsed 1s", .{});

    var frame2 = try Surface.init(testing.allocator, 20, 2);
    defer frame2.deinit();
    _ = try frame2.root().writeText(0, 0, "building...", .{});
    _ = try frame2.root().writeText(0, 1, "elapsed 2s", .{});

    const r = Renderer{ .capability = .ansi_16 };
    try paintInto(&vt, r, null, &frame1);
    try testing.expect(vt.containsText("elapsed 1s"));

    try paintInto(&vt, r, &frame1, &frame2);
    try testing.expect(vt.containsText("building..."));
    try testing.expect(vt.containsText("elapsed 2s"));
    try testing.expect(!vt.containsText("elapsed 1s"));
    try testing.expect(vt.cursorAt(0, 0));
}

test "diff paint dissolves a wide grapheme cleanly on screen" {
    var vt = try VTerm.init(testing.allocator, 10, 2);
    defer vt.deinit();

    var frame1 = try Surface.init(testing.allocator, 10, 1);
    defer frame1.deinit();
    _ = try frame1.root().writeText(0, 0, "你", .{});

    var frame2 = try Surface.init(testing.allocator, 10, 1);
    defer frame2.deinit();
    _ = try frame2.root().writeText(1, 0, "x", .{});

    const r = Renderer{ .capability = .ansi_16 };
    try paintInto(&vt, r, null, &frame1);
    try testing.expectEqual(@as(u21, '你'), vt.getCell(0, 0).char);

    try paintInto(&vt, r, &frame1, &frame2);
    // The head column was repainted as a blank, not left as half a glyph.
    try testing.expectEqual(@as(u21, ' '), vt.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'x'), vt.getCell(1, 0).char);
}

/// A frame the way a consumer will build one: a component function returning
/// a node tree from the frame arena, sized by measure, painted, then diffed.
fn statusFrame(a: std.mem.Allocator, glyph: []const u8, elapsed: []const u8) !ui.Node {
    return ui.column(a, .{
        .border = .rounded,
        .padding = .symmetric(1, 0),
        .width = .{ .len = 24 },
    }, &.{
        try ui.row(a, .{ .gap = 1 }, &.{
            ui.text(.{ .bold = true }, glyph),
            ui.text(.{}, "building..."),
            ui.spacer(),
            ui.text(.{}, elapsed),
        }),
    });
}

test "end to end: a bordered status frame builds, paints, and diffs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rctx = ui.RenderCtx{ .allocator = arena.allocator() };

    var vt = try VTerm.init(testing.allocator, 24, 4);
    defer vt.deinit();

    const frame1 = try statusFrame(arena.allocator(), "*", "12s");
    const size = ui.measure(&rctx, &frame1, .{ .max_w = 24, .max_h = 4 });
    try testing.expectEqual(ui.Size{ .w = 24, .h = 3 }, size);

    var prev = try Surface.init(testing.allocator, size.w, size.h);
    defer prev.deinit();
    var next = try Surface.init(testing.allocator, size.w, size.h);
    defer next.deinit();

    const r = Renderer{ .capability = .ansi_16 };
    try ui.render(&rctx, &frame1, prev.root());
    try paintInto(&vt, r, null, &prev);

    try testing.expectEqual(@as(u21, '╭'), vt.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, '╯'), vt.getCell(23, 2).char);
    try testing.expect(vt.containsText("building..."));
    try testing.expect(vt.containsText("12s"));
    try testing.expect(vt.hasAttribute(2, 1, .bold)); // the glyph, inside border+pad

    const frame2 = try statusFrame(arena.allocator(), "*", "13s");
    try ui.render(&rctx, &frame2, next.root());
    try paintInto(&vt, r, &prev, &next);

    try testing.expect(vt.containsText("building..."));
    try testing.expect(vt.containsText("13s"));
    try testing.expect(!vt.containsText("12s"));
    try testing.expect(vt.cursorAt(0, 0));
}

test "style-only change repaints in place" {
    var vt = try VTerm.init(testing.allocator, 10, 1);
    defer vt.deinit();

    var frame1 = try Surface.init(testing.allocator, 10, 1);
    defer frame1.deinit();
    _ = try frame1.root().writeText(0, 0, "warn", .{});

    var frame2 = try Surface.init(testing.allocator, 10, 1);
    defer frame2.deinit();
    _ = try frame2.root().writeText(0, 0, "warn", .{ .foreground = .yellow, .bold = true });

    const r = Renderer{ .capability = .ansi_16 };
    try paintInto(&vt, r, null, &frame1);
    try testing.expectEqual(vterm.Color.default, vt.getTextColor(0, 0));

    try paintInto(&vt, r, &frame1, &frame2);
    try testing.expect(vt.containsText("warn"));
    try testing.expectEqual(vterm.Color.yellow, vt.getTextColor(0, 0));
    try testing.expect(vt.hasAttribute(0, 0, .bold));
}
