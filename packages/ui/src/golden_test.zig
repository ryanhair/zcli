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

test "a centered overlay composites over the base through the renderer" {
    var vt = try VTerm.init(testing.allocator, 9, 3);
    defer vt.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var s = try Surface.init(testing.allocator, 9, 3);
    defer s.deinit();

    const rctx = ui.RenderCtx{ .allocator = a };
    const n = try ui.stack(a, .{}, &.{
        try ui.column(a, .{}, &.{
            ui.textOpts(.{ .wrap = .clip }, "........."),
            ui.textOpts(.{ .wrap = .clip }, "........."),
            ui.textOpts(.{ .wrap = .clip }, "........."),
        }),
        try ui.center(a, ui.textOpts(.{ .wrap = .clip }, "MID")),
    });
    try ui.render(&rctx, &n, s.root());
    try paintInto(&vt, .{ .capability = .ansi_16 }, null, &s);

    // The overlay sits on the middle row, base dots on either side of it —
    // compositing survives the diff renderer and lands where the surface says.
    try testing.expect(vt.containsText("MID"));
    try testing.expectEqual(@as(u21, 'M'), vt.getCell(3, 1).char);
    try testing.expectEqual(@as(u21, '.'), vt.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, '.'), vt.getCell(8, 1).char);
    // Rows above and below the overlay stay pure base.
    try testing.expectEqual(@as(u21, '.'), vt.getCell(4, 0).char);
    try testing.expectEqual(@as(u21, '.'), vt.getCell(4, 2).char);
}

test "closing an overlay repaints the base underneath it" {
    var vt = try VTerm.init(testing.allocator, 9, 3);
    defer vt.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rctx = ui.RenderCtx{ .allocator = a };

    const baseLayer = struct {
        fn build(alloc: std.mem.Allocator) !ui.Node {
            return ui.column(alloc, .{}, &.{
                ui.textOpts(.{ .wrap = .clip }, "........."),
                ui.textOpts(.{ .wrap = .clip }, "........."),
                ui.textOpts(.{ .wrap = .clip }, "........."),
            });
        }
    }.build;

    // Frame 1: base with a centered overlay.
    var withOverlay = try Surface.init(testing.allocator, 9, 3);
    defer withOverlay.deinit();
    const f1 = try ui.stack(a, .{}, &.{
        try baseLayer(a),
        try ui.center(a, ui.textOpts(.{ .wrap = .clip }, "MID")),
    });
    try ui.render(&rctx, &f1, withOverlay.root());
    try paintInto(&vt, .{ .capability = .ansi_16 }, null, &withOverlay);
    try testing.expect(vt.containsText("MID"));

    // Frame 2: overlay removed — the base cells it covered must come back.
    var baseOnly = try Surface.init(testing.allocator, 9, 3);
    defer baseOnly.deinit();
    const f2 = try baseLayer(a);
    try ui.render(&rctx, &f2, baseOnly.root());
    try paintInto(&vt, .{ .capability = .ansi_16 }, &withOverlay, &baseOnly);

    try testing.expect(!vt.containsText("MID"));
    try testing.expectEqual(@as(u21, '.'), vt.getCell(3, 1).char);
    try testing.expectEqual(@as(u21, '.'), vt.getCell(5, 1).char);
}

test "a viewport blits styled and wide content through the renderer" {
    var vt = try VTerm.init(testing.allocator, 6, 2);
    defer vt.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Surface.init(testing.allocator, 6, 2);
    defer s.deinit();
    const rctx = ui.RenderCtx{ .allocator = a };

    const content = try ui.column(a, .{}, &.{
        ui.textOpts(.{ .wrap = .clip, .style = .{ .bold = true } }, "top"),
        ui.textOpts(.{ .wrap = .clip }, "你好"), // wide graphemes
        ui.textOpts(.{ .wrap = .clip, .style = .{ .underline = true } }, "last"),
    });
    // Window rows 1-2: scroll the bold "top" out of view.
    const vp = try ui.viewport(a, .{ .scroll_y = 1 }, content);
    try ui.render(&rctx, &vp, s.root());
    try paintInto(&vt, .{ .capability = .ansi_16 }, null, &s);

    // Wide graphemes survive the blit (head + continuation land intact)...
    try testing.expectEqual(@as(u21, '你'), vt.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, '好'), vt.getCell(2, 0).char);
    // ...and so does per-cell style.
    try testing.expect(vt.containsText("last"));
    try testing.expect(vt.hasAttribute(0, 1, .underline));
    // The scrolled-out row is gone.
    try testing.expect(!vt.containsText("top"));
}

test "a scrollbar viewport reserves a gutter and paints a thumb" {
    var vt = try VTerm.init(testing.allocator, 6, 4);
    defer vt.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Surface.init(testing.allocator, 6, 4);
    defer s.deinit();
    const rctx = ui.RenderCtx{ .allocator = a };

    // Eight lines "0".."7" in a 4-row window scrolled to the bottom (scroll_y past
    // the end clamps to 4). The gutter is column 5; the content blits into 0..4.
    const lines = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7" };
    const kids = try a.alloc(ui.Node, lines.len);
    for (lines, kids) |line, *k| k.* = ui.textOpts(.{ .wrap = .clip }, line);
    const content = try ui.column(a, .{}, kids);
    const vp = try ui.viewport(a, .{ .scroll_y = 99, .scrollbar = true }, content);
    try ui.render(&rctx, &vp, s.root());
    try paintInto(&vt, .{ .capability = .ansi_16 }, null, &s);

    // Content occupies columns 0..4; the bottom four lines "4".."7" show.
    try testing.expectEqual(@as(u21, '4'), vt.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, '7'), vt.getCell(0, 3).char);
    // The scrollbar gutter (column 5) carries a │ glyph on every row — a track
    // with a thumb, both the same glyph, distinguished only by style (which the
    // 16-color path can't reliably assert; the styles are covered in the unit
    // test). The addressing — a full gutter column — is what this verifies.
    try testing.expectEqual(@as(u21, '│'), vt.getCell(5, 0).char);
    try testing.expectEqual(@as(u21, '│'), vt.getCell(5, 3).char);
    // Scrolled to the bottom: the top line "0" is gone.
    try testing.expect(!vt.containsText("0"));
}

// ---- Table (ADR-0021 incr1) ------------------------------------------------

const table_columns = [_]ui.widgets.Table.Column{
    .{ .header = "PID", .width = .{ .len = 4 } },
    .{ .header = "COMMAND", .width = .fit },
};
const table_rows = [_][]const []const u8{
    &.{ "1001", "zig" },
    &.{ "1138", "firefox" },
    &.{ "1275", "kernel_task" },
    &.{ "1412", "postgres" },
    &.{ "1549", "nginx" },
};

test "a Table paints an aligned header and body through the renderer" {
    var vt = try VTerm.init(testing.allocator, 20, 5);
    defer vt.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Surface.init(testing.allocator, 20, 4);
    defer s.deinit();
    const rctx = ui.RenderCtx{ .allocator = a };

    var t = ui.widgets.Table{};
    const node = try t.view(a, .{ .focused = true, .columns = &table_columns, .rows = &table_rows, .height = 3 });
    try ui.render(&rctx, &node, s.root());
    try paintInto(&vt, .{ .capability = .ansi_16 }, null, &s);

    // Header and body land, addressed to the right cells.
    try testing.expect(vt.containsText("PID"));
    try testing.expect(vt.containsText("COMMAND"));
    try testing.expect(vt.containsText("zig"));
    // The COMMAND column starts at the same x on the header and every body row —
    // the `.fit`/`.len` columns line up through the renderer (PID .len(4) + 1 gap
    // → column 5), which is exactly the addressing a byte-golden string would bake
    // in and this test verifies against a real parsed frame.
    try testing.expectEqual(@as(u21, 'C'), vt.getCell(5, 0).char); // COMMAND
    try testing.expectEqual(@as(u21, 'z'), vt.getCell(5, 1).char); // zig
    try testing.expectEqual(@as(u21, 'f'), vt.getCell(5, 2).char); // firefox
    // The PID column is left-aligned in its fixed 4-cell width on every row.
    try testing.expectEqual(@as(u21, '1'), vt.getCell(0, 1).char);
}

test "a Table truncates an overwide cell and draws the overflow arrow" {
    var vt = try VTerm.init(testing.allocator, 12, 5);
    defer vt.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Surface.init(testing.allocator, 12, 4);
    defer s.deinit();
    const rctx = ui.RenderCtx{ .allocator = a };

    var t = ui.widgets.Table{};
    // A 12-wide surface can't hold "kernel_task"; the COMMAND cell truncates with
    // an ellipsis, and the 3-row window over 5 rows shows a ↓ on the last body row.
    const node = try t.view(a, .{ .focused = true, .columns = &table_columns, .rows = &table_rows, .height = 3 });
    try ui.render(&rctx, &node, s.root());
    try paintInto(&vt, .{ .capability = .ansi_16 }, null, &s);

    // The last body row is "1275 kerne…" — the COMMAND cell truncates with an
    // ellipsis, and its gutter carries the ↓ overflow arrow. (`containsText` is
    // byte-wise, so multibyte glyphs are checked per-cell via `getCell`.)
    try testing.expectEqual(@as(u21, '…'), vt.getCell(10, 3).char); // truncation ellipsis
    try testing.expectEqual(@as(u21, '↓'), vt.getCell(11, 3).char); // overflow arrow
    try testing.expect(!vt.containsText("kernel_task")); // the full text did not fit
}

test "a scrollbar Table paints a thumb gutter over its scrolling body" {
    var vt = try VTerm.init(testing.allocator, 20, 5);
    defer vt.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Surface.init(testing.allocator, 20, 4);
    defer s.deinit();
    const rctx = ui.RenderCtx{ .allocator = a };

    // A 3-row body window over 5 rows with the scrollbar on: the body's rightmost
    // column (19) carries a │ thumb/track on each of the 3 body rows, replacing the
    // ↑/↓ overflow arrows. The header (row 0) keeps a blank gutter cell.
    var t = ui.widgets.Table{};
    const node = try t.view(a, .{ .focused = true, .columns = &table_columns, .rows = &table_rows, .height = 3, .scrollbar = true });
    try ui.render(&rctx, &node, s.root());
    try paintInto(&vt, .{ .capability = .ansi_16 }, null, &s);

    // Header and body still land.
    try testing.expect(vt.containsText("PID"));
    try testing.expect(vt.containsText("zig"));
    // The scrollbar occupies the gutter on the three body rows (1..3), not the
    // header — and it replaced the arrows, so no ↓ is drawn there.
    try testing.expectEqual(@as(u21, '│'), vt.getCell(19, 1).char);
    try testing.expectEqual(@as(u21, '│'), vt.getCell(19, 3).char);
    try testing.expect(vt.getCell(19, 0).char != @as(u21, '│')); // header gutter is blank
    try testing.expect(vt.getCell(19, 3).char != @as(u21, '↓')); // arrow suppressed
}

// ---- Tabs (ADR-0021 incr2) -------------------------------------------------

test "a Tabs bar paints its labels in a spaced row through the renderer" {
    var vt = try VTerm.init(testing.allocator, 20, 1);
    defer vt.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Surface.init(testing.allocator, 20, 1);
    defer s.deinit();
    const rctx = ui.RenderCtx{ .allocator = a };

    const labels = [_][]const u8{ "One", "Two", "Three" };
    var tabs = ui.widgets.Tabs{ .active = 1 };
    const node = try tabs.view(a, .{ .focused = true, .labels = &labels });
    try ui.render(&rctx, &node, s.root());
    try paintInto(&vt, .{ .capability = .ansi_16 }, null, &s);

    // Labels land, each separated by a single space, addressed to the right cells:
    // "One"(0-2) space(3) "Two"(4-6) space(7) "Three"(8-12). Precise active/inactive
    // styling is asserted in input_test.zig via `styleEql` — accent-color
    // downsampling through the diff renderer is unreliable, so here we verify the
    // addressing/alignment a byte-golden string would otherwise bake in.
    try testing.expect(vt.containsText("One Two Three"));
    try testing.expectEqual(@as(u21, 'T'), vt.getCell(4, 0).char); // Two (active)
    try testing.expectEqual(@as(u21, 'T'), vt.getCell(8, 0).char); // Three
    try testing.expectEqual(@as(u21, ' '), vt.getCell(3, 0).char); // separator
    try testing.expectEqual(@as(u21, ' '), vt.getCell(7, 0).char); // separator
}

// ---- TextArea (ADR-0021 incr3) ---------------------------------------------

test "a TextArea soft-wraps a paragraph across visual rows through the renderer" {
    var vt = try VTerm.init(testing.allocator, 6, 4);
    defer vt.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Surface.init(testing.allocator, 6, 4);
    defer s.deinit();
    const rctx = ui.RenderCtx{ .allocator = a };

    var ta = ui.widgets.TextArea{ .buffer = try a.dupe(u8, "aaa bbb ccc") };
    ta.len = 11;
    // Width 6 wraps "aaa bbb ccc" → "aaa" / "bbb" / "ccc", each its own row.
    const node = try ta.view(a, .{ .width = .{ .len = 6 }, .height = 4 });
    try ui.render(&rctx, &node, s.root());
    try paintInto(&vt, .{ .capability = .ansi_16 }, null, &s);

    // Each soft-wrapped visual row lands on its own line, addressed to (0, row).
    try testing.expectEqual(@as(u21, 'a'), vt.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'b'), vt.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, 'c'), vt.getCell(0, 2).char);
    try testing.expect(vt.containsText("aaa"));
    try testing.expect(vt.containsText("bbb"));
    try testing.expect(vt.containsText("ccc"));
}

test "a TextArea paints the scrolled window and its placeholder through the renderer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Scrolled window: six lines "0".."5", a 3-row field, cursor on the last row.
    {
        var vt = try VTerm.init(testing.allocator, 8, 3);
        defer vt.deinit();
        var s = try Surface.init(testing.allocator, 8, 3);
        defer s.deinit();
        const rctx = ui.RenderCtx{ .allocator = a };

        var ta = ui.widgets.TextArea{ .buffer = try a.dupe(u8, "0\n1\n2\n3\n4\n5") };
        ta.len = ta.buffer.len;
        for (0..5) |_| _ = ta.handle(.down, 8, 3); // walk the caret to the last row
        const node = try ta.view(a, .{ .focused = true, .width = .{ .len = 8 }, .height = 3 });
        try ui.render(&rctx, &node, s.root());
        try paintInto(&vt, .{ .capability = .ansi_16 }, null, &s);

        // The 3-row window slid to the bottom three lines "3","4","5".
        try testing.expectEqual(@as(u21, '3'), vt.getCell(0, 0).char);
        try testing.expectEqual(@as(u21, '4'), vt.getCell(0, 1).char);
        try testing.expectEqual(@as(u21, '5'), vt.getCell(0, 2).char);
        try testing.expect(!vt.containsText("0")); // scrolled off the top
    }

    // Placeholder: an empty field shows its hint text, addressed at the origin.
    {
        var vt = try VTerm.init(testing.allocator, 10, 3);
        defer vt.deinit();
        var s = try Surface.init(testing.allocator, 10, 3);
        defer s.deinit();
        const rctx = ui.RenderCtx{ .allocator = a };

        var ta = ui.widgets.TextArea{ .buffer = try a.alloc(u8, 16) };
        const node = try ta.view(a, .{ .placeholder = "notes...", .width = .{ .len = 10 }, .height = 3 });
        try ui.render(&rctx, &node, s.root());
        try paintInto(&vt, .{ .capability = .ansi_16 }, null, &s);
        try testing.expect(vt.containsText("notes..."));
    }
}
