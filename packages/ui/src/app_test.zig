//! App loop tests: drive emit/frame against a vterm and assert on what a
//! user would see — the static stream flowing above, the live region
//! repainting in place below, and terminal state restored on deinit.

const std = @import("std");
const vterm = @import("vterm");
const ui = @import("ui.zig");

const testing = std.testing;
const VTerm = vterm.VTerm;

/// An App writing into a capture buffer, replayed into a vterm on demand.
const Harness = struct {
    aw: std.Io.Writer.Allocating,
    vt: VTerm,
    app: ui.App,
    fed: usize = 0,

    fn init(w: u16, h: u16) !*Harness {
        return initMode(w, h, .hybrid);
    }

    fn initMode(w: u16, h: u16, mode: ui.App.Mode) !*Harness {
        const self = try testing.allocator.create(Harness);
        errdefer testing.allocator.destroy(self);
        self.* = .{
            .aw = std.Io.Writer.Allocating.init(testing.allocator),
            .vt = try VTerm.init(testing.allocator, w, h),
            .app = undefined,
        };
        const opts = ui.App.Options{ .term_size = .{ .w = w, .h = h } };
        self.app = switch (mode) {
            .hybrid => try ui.App.init(testing.allocator, &self.aw.writer, opts),
            .full_screen => try ui.App.initFullScreen(testing.allocator, &self.aw.writer, opts),
        };
        return self;
    }

    fn deinit(self: *Harness) void {
        self.app.deinit();
        self.vt.deinit();
        self.aw.deinit();
        testing.allocator.destroy(self);
    }

    /// Feed everything newly written into the terminal.
    fn replay(self: *Harness) void {
        self.vt.write(self.aw.written()[self.fed..]);
        self.fed = self.aw.written().len;
    }

    fn statusFrame(self: *Harness, msg: []const u8) !ui.Node {
        const a = self.app.arena();
        return ui.column(a, .{ .border = .single, .width = .{ .len = 20 } }, &.{
            ui.text(.{}, msg),
        });
    }
};

test "frame paints the live region at the cursor" {
    var h = try Harness.init(30, 8);
    defer h.deinit();

    try h.app.frame(try h.statusFrame("working"));
    h.replay();

    try testing.expect(h.vt.containsText("working"));
    try testing.expectEqual(@as(u21, '┌'), h.vt.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, '┘'), h.vt.getCell(19, 2).char);
    // Parked at the region's top-left, hidden.
    try testing.expect(h.vt.cursorAt(0, 0));
    try testing.expect(!h.vt.cursor_visible);
}

test "second frame diffs in place" {
    var h = try Harness.init(30, 8);
    defer h.deinit();

    try h.app.frame(try h.statusFrame("step 1"));
    h.replay();
    const before = h.fed;

    try h.app.frame(try h.statusFrame("step 2"));
    h.replay();

    try testing.expect(h.vt.containsText("step 2"));
    try testing.expect(!h.vt.containsText("step 1"));
    // A one-cell change costs a fraction of the first full paint.
    try testing.expect(h.fed - before < before / 2);
}

test "emit prints static above and repaints the live region below" {
    var h = try Harness.init(30, 8);
    defer h.deinit();

    try h.app.frame(try h.statusFrame("running"));
    try h.app.emit("compiled {s}", .{"zcli"}); // no trailing \n: App adds it
    h.replay();

    // Static line sits above the live frame.
    const line0 = try h.vt.getLine(testing.allocator, 0);
    defer testing.allocator.free(line0);
    try testing.expect(std.mem.startsWith(u8, line0, "compiled zcli"));
    // Live region repainted intact below it.
    try testing.expectEqual(@as(u21, '┌'), h.vt.getCell(0, 1).char);
    try testing.expect(h.vt.containsText("running"));
    try testing.expect(h.vt.cursorAt(0, 1));

    // And the next frame still diffs against the repainted region.
    try h.app.frame(try h.statusFrame("almost!"));
    h.replay();
    try testing.expect(h.vt.containsText("compiled zcli"));
    try testing.expect(h.vt.containsText("almost!"));
    try testing.expect(!h.vt.containsText("running"));
}

test "emit works before any frame exists" {
    var h = try Harness.init(30, 8);
    defer h.deinit();

    try h.app.emit("hello\n", .{});
    h.replay();
    try testing.expect(h.vt.containsText("hello"));
    // No live region: nothing reserved, cursor not hidden.
    try testing.expect(h.vt.cursor_visible);
}

test "live region grows and shrinks between frames" {
    var h = try Harness.init(30, 10);
    defer h.deinit();

    const a1 = h.app.arena();
    try h.app.frame(try ui.column(a1, .{}, &.{ui.text(.{}, "one")}));
    h.replay();
    try testing.expect(h.vt.containsText("one"));

    const a2 = h.app.arena();
    try h.app.frame(try ui.column(a2, .{}, &.{
        ui.text(.{}, "alpha"),
        ui.text(.{}, "beta"),
        ui.text(.{}, "gamma"),
    }));
    h.replay();
    try testing.expect(h.vt.containsText("alpha"));
    try testing.expect(h.vt.containsText("gamma"));
    try testing.expect(!h.vt.containsText("one"));

    const a3 = h.app.arena();
    try h.app.frame(try ui.column(a3, .{}, &.{ui.text(.{}, "small")}));
    h.replay();
    try testing.expect(h.vt.containsText("small"));
    try testing.expect(!h.vt.containsText("alpha"));
    try testing.expect(!h.vt.containsText("gamma"));
}

test "width resize re-lays-out the live region" {
    var h = try Harness.init(30, 8);
    defer h.deinit();

    const a1 = h.app.arena();
    try h.app.frame(try ui.column(a1, .{ .width = .{ .fill = 1 } }, &.{
        ui.text(.{}, "hello world resize"),
    }));
    h.replay();
    try testing.expect(h.vt.containsText("hello world resize"));

    // Terminal narrows: the same content must rewrap onto two rows.
    h.app.options.term_size = .{ .w = 12, .h = 8 };
    const a2 = h.app.arena();
    try h.app.frame(try ui.column(a2, .{ .width = .{ .fill = 1 } }, &.{
        ui.text(.{}, "hello world resize"),
    }));
    h.replay();
    try testing.expect(h.vt.containsText("hello world"));
    try testing.expect(h.vt.containsText("resize"));
    try testing.expect(!h.vt.containsText("hello world resize"));
}

test "live region height clamps to the viewport" {
    var h = try Harness.init(30, 4);
    defer h.deinit();

    const a = h.app.arena();
    var lines: [8]ui.Node = undefined;
    for (&lines, 0..) |*n, i| {
        n.* = ui.text(.{}, if (i == 0) "first" else "later");
    }
    try h.app.frame(try ui.column(a, .{}, &lines));
    h.replay();

    // 8 content rows offered a 4-row terminal: clamped to 3 (viewport - 1),
    // clipped from the bottom — the top rows win.
    try testing.expect(h.vt.containsText("first"));
    try testing.expectEqual(@as(u16, 3), h.app.live_rows);
}

// ---------------------------------------------------------------------------
// Resize tier 2: the visible static tail reflows on width change.
// vterm is a NON-reflowing terminal (resize truncates/pads rows), so
// everything correct on screen after these resizes is the App's doing.
// ---------------------------------------------------------------------------

test "width shrink rewraps the visible static tail above the live region" {
    var h = try Harness.init(40, 10);
    defer h.deinit();

    // One static line that fits one 40-col row but needs two at 20.
    try h.app.emit("static: the quick brown fox jumps!", .{}); // 34 cols
    try h.app.frame(try h.statusFrame("running"));
    h.replay();
    try testing.expectEqual(@as(u21, '┌'), h.vt.getCell(0, 1).char);

    h.app.options.term_size = .{ .w = 20, .h = 10 };
    try h.vt.resize(20, 10);
    try h.app.frame(try h.statusFrame("running"));
    h.replay();

    // The tail was erased and reprinted: the terminal rewrapped it onto
    // rows 0-1 at the new width, and the live region re-reserved below it.
    const line0 = try h.vt.getLine(testing.allocator, 0);
    defer testing.allocator.free(line0);
    try testing.expect(std.mem.startsWith(u8, line0, "static: the quick br"));
    const line1 = try h.vt.getLine(testing.allocator, 1);
    defer testing.allocator.free(line1);
    try testing.expect(std.mem.startsWith(u8, line1, "own fox jumps!"));
    try testing.expectEqual(@as(u21, '┌'), h.vt.getCell(0, 2).char);
    try testing.expect(h.vt.containsText("running"));
    try testing.expect(h.vt.cursorAt(0, 2));
}

test "width grow unwraps the tail without leaving stale rows" {
    var h = try Harness.init(20, 10);
    defer h.deinit();

    try h.app.emit("static: the quick brown fox jumps!", .{}); // 2 rows at 20
    try h.app.frame(try h.statusFrame("running"));
    h.replay();
    try testing.expectEqual(@as(u21, '┌'), h.vt.getCell(0, 2).char);

    h.app.options.term_size = .{ .w = 40, .h = 10 };
    try h.vt.resize(40, 10);
    try h.app.frame(try h.statusFrame("running"));
    h.replay();

    // The whole line now fits row 0; the old second tail row must not
    // survive as a stale duplicate — the live region moves up to row 1.
    const line0 = try h.vt.getLine(testing.allocator, 0);
    defer testing.allocator.free(line0);
    try testing.expect(std.mem.startsWith(u8, line0, "static: the quick brown fox jumps!"));
    try testing.expectEqual(@as(u21, '┌'), h.vt.getCell(0, 1).char);
    try testing.expect(h.vt.containsText("running"));
    try testing.expect(h.vt.cursorAt(0, 1));
}

test "retention stays bounded at about a screenful" {
    var h = try Harness.init(30, 6);
    defer h.deinit();

    try h.app.frame(try ui.column(h.app.arena(), .{}, &.{ui.text(.{}, "live")}));
    var i: u32 = 0;
    while (i < 12) : (i += 1) {
        try h.app.emit("log line {d}", .{i});
    }
    // Live region is 1 row on a 6-row terminal: at most 5 one-row blocks
    // can still be visible above it.
    try testing.expect(h.app.retained.items.len <= 5);
    // (Leaks in evicted blocks would trip std.testing.allocator on deinit.)
}

test "height-only change does not disturb the static tail" {
    var h = try Harness.init(30, 10);
    defer h.deinit();

    try h.app.emit("keep me", .{});
    try h.app.frame(try h.statusFrame("running"));
    h.replay();
    const fed_before = h.fed;

    h.app.options.term_size = .{ .w = 30, .h = 6 };
    try h.app.frame(try h.statusFrame("running"));
    h.replay();

    // No width change: no tail repaint bytes, no full erase — the frame is
    // an unchanged diff (zero paint bytes).
    try testing.expect(std.mem.indexOf(u8, h.aw.written()[fed_before..], "keep me") == null);
    try testing.expect(h.vt.containsText("keep me"));
    try testing.expect(h.vt.containsText("running"));
}

test "non-interactive App degrades to plain line output" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    var app = try ui.App.init(testing.allocator, &aw.writer, .{
        .term_size = .{ .w = 30, .h = 8 },
        .interactive = false,
    });
    defer app.deinit();

    const a = app.arena();
    try app.frame(try ui.column(a, .{}, &.{ui.text(.{ .bold = true }, "live")}));
    try testing.expectEqual(@as(usize, 0), aw.written().len);

    try app.emit("plain {s}", .{"line"});
    try testing.expectEqualStrings("plain line\n", aw.written());

    app.deinit();
    app = try ui.App.init(testing.allocator, &aw.writer, .{ .interactive = false });
    // No escapes anywhere: no cursor hide/show, no clears, no SGR.
    try testing.expect(std.mem.indexOfScalar(u8, aw.written(), 0x1b) == null);
}

test "clear erases the live region leaving nothing" {
    var h = try Harness.init(30, 8);
    defer h.deinit();

    try h.app.frame(try h.statusFrame("busy"));
    h.replay();
    try testing.expect(h.vt.containsText("busy"));

    try h.app.clear();
    h.replay();
    try testing.expect(!h.vt.containsText("busy"));
    try testing.expectEqual(@as(u16, 0), h.app.live_rows);
    // A following emit must not resurrect the region.
    try h.app.emit("done", .{});
    h.replay();
    try testing.expect(h.vt.containsText("done"));
    try testing.expect(!h.vt.containsText("busy"));
}

test "deinit shows the cursor and parks below the live region" {
    var h = try Harness.init(30, 8);
    defer h.deinit();

    try h.app.frame(try h.statusFrame("bye"));
    h.app.deinit();
    // Re-init so Harness.deinit's second app.deinit is harmless.
    h.app = try ui.App.init(testing.allocator, &h.aw.writer, .{
        .term_size = .{ .w = 30, .h = 8 },
    });
    h.replay();

    try testing.expect(h.vt.cursor_visible);
    // Below the 3-row frame (rows 0-2), on a fresh line.
    try testing.expect(h.vt.cursorAt(0, 3));
    try testing.expect(h.vt.containsText("bye"));
}

test "showCursorAt places the real cursor; the next frame un-places it" {
    var h = try Harness.init(30, 8);
    defer h.deinit();

    try h.app.frame(try h.statusFrame("edit me"));
    try h.app.showCursorAt(9, 1);
    h.replay();
    try testing.expect(h.vt.cursor_visible);
    try testing.expect(h.vt.cursorAt(9, 1));

    // The next frame restores the parking invariant: hidden, top-left —
    // and the diff still lands in the right cells.
    try h.app.frame(try h.statusFrame("edit mf"));
    h.replay();
    try testing.expect(!h.vt.cursor_visible);
    try testing.expect(h.vt.cursorAt(0, 0));
    try testing.expect(h.vt.containsText("edit mf"));
}

test "showCursorAt clamps to the live region" {
    var h = try Harness.init(30, 8);
    defer h.deinit();

    try h.app.frame(try h.statusFrame("hi"));
    try h.app.showCursorAt(999, 999);
    h.replay();
    // Region is 20 wide, 3 tall.
    try testing.expect(h.vt.cursorAt(19, 2));
}

test "emit while the cursor is placed keeps static/live intact" {
    var h = try Harness.init(30, 8);
    defer h.deinit();

    try h.app.frame(try h.statusFrame("typing"));
    try h.app.showCursorAt(5, 1);
    try h.app.emit("saved", .{});
    h.replay();

    const line0 = try h.vt.getLine(testing.allocator, 0);
    defer testing.allocator.free(line0);
    try testing.expect(std.mem.startsWith(u8, line0, "saved"));
    try testing.expect(h.vt.containsText("typing"));
    // Repainted region back under the parking invariant.
    try testing.expect(h.vt.cursorAt(0, 1));
}

test "deinit is idempotent" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    var app = try ui.App.init(testing.allocator, &aw.writer, .{
        .term_size = .{ .w = 30, .h = 8 },
    });
    const a = app.arena();
    try app.frame(try ui.column(a, .{}, &.{ui.text(.{}, "x")}));
    app.deinit();
    app.deinit(); // second call must be a no-op, not a double free
    try testing.expect(std.mem.endsWith(u8, aw.written(), "\x1b[?25h"));
}

// ----------------------------------------------------------------------
// Full-screen mode (ADR-0015). A fixed term_size keeps these headless: the
// alt-screen takeover byte stream runs, but raw mode / input do not (those
// need a real terminal, exercised by the example + e2e).
// ----------------------------------------------------------------------

/// A `fill`×`fill` root — the shape a full-screen app uses to take the
/// whole viewport.
fn fullRoot(a: std.mem.Allocator, msg: []const u8) !ui.Node {
    return ui.column(a, .{ .width = .{ .fill = 1 }, .height = .{ .fill = 1 } }, &.{ui.text(.{}, msg)});
}

test "full_screen enters the alt-screen and paints the whole viewport" {
    var h = try Harness.initMode(20, 6, .full_screen);
    defer h.deinit();
    // init already switched to the alternate screen and hid the cursor.
    h.replay();
    try testing.expect(h.vt.alt_screen);
    try testing.expect(!h.vt.cursor_visible);

    try h.app.frame(try fullRoot(h.app.arena(), "dashboard"));
    h.replay();

    try testing.expect(h.vt.containsText("dashboard"));
    // The frame is granted the full viewport height (no held-back row).
    try testing.expectEqual(@as(u16, 6), h.app.live_rows);
    // Parked at the origin (the diff renderer's anchor), still hidden.
    try testing.expect(h.vt.cursorAt(0, 0));
    try testing.expect(!h.vt.cursor_visible);
}

test "full_screen deinit leaves the alt-screen and shows the cursor" {
    var h = try Harness.initMode(20, 6, .full_screen);
    defer h.deinit();

    try h.app.frame(try fullRoot(h.app.arena(), "bye"));
    h.app.deinit();
    // Re-init (hybrid, non-interactive so it touches nothing) so Harness.deinit's
    // second app.deinit is a harmless no-op.
    h.app = try ui.App.init(testing.allocator, &h.aw.writer, .{ .interactive = false });
    h.replay();

    try testing.expect(!h.vt.alt_screen);
    try testing.expect(h.vt.cursor_visible);
}

test "emit is unavailable in full_screen" {
    var h = try Harness.initMode(20, 6, .full_screen);
    defer h.deinit();
    try testing.expectError(error.EmitInFullScreen, h.app.emit("nope", .{}));
}

test "full_screen on a non-TTY is an error at init" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try testing.expectError(error.NotATerminal, ui.App.initFullScreen(testing.allocator, &aw.writer, .{
        .term_size = .{ .w = 20, .h = 6 },
        .interactive = false,
    }));
}

test "full_screen enables mouse + focus on enter and disables them on deinit" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    var app = try ui.App.initFullScreen(testing.allocator, &aw.writer, .{
        .term_size = .{ .w = 20, .h = 6 },
        .mouse = true,
        .focus = true,
    });
    // Enter emitted the DECSET enables (SGR mouse + drag tracking, focus).
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[?1002h") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[?1006h") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[?1004h") != null);

    app.deinit();
    const out = aw.written();
    // Teardown disabled them before leaving the alt-screen (the disables precede
    // the `?1049l` in the stream).
    const mouse_off = std.mem.indexOf(u8, out, "\x1b[?1002l").?;
    const focus_off = std.mem.indexOf(u8, out, "\x1b[?1004l").?;
    const alt_off = std.mem.lastIndexOf(u8, out, "\x1b[?1049l").?;
    try testing.expect(mouse_off < alt_off and focus_off < alt_off);
}

test "full_screen leaves mouse/focus/paste modes untouched when not requested" {
    var h = try Harness.initMode(20, 6, .full_screen);
    defer h.deinit();
    try testing.expect(std.mem.indexOf(u8, h.aw.written(), "\x1b[?1002h") == null);
    try testing.expect(std.mem.indexOf(u8, h.aw.written(), "\x1b[?1004h") == null);
    try testing.expect(std.mem.indexOf(u8, h.aw.written(), "\x1b[?2004h") == null);
}

test "full_screen enables paste on enter and disables it on deinit" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    var app = try ui.App.initFullScreen(testing.allocator, &aw.writer, .{
        .term_size = .{ .w = 20, .h = 6 },
        .paste = true,
    });
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[?2004h") != null);
    app.deinit();
    const out = aw.written();
    const paste_off = std.mem.indexOf(u8, out, "\x1b[?2004l").?;
    const alt_off = std.mem.lastIndexOf(u8, out, "\x1b[?1049l").?;
    try testing.expect(paste_off < alt_off);
}

test "full_screen resize repaints the whole new viewport" {
    var h = try Harness.initMode(20, 6, .full_screen);
    defer h.deinit();

    try h.app.frame(try fullRoot(h.app.arena(), "before"));
    h.replay();
    try testing.expectEqual(@as(u16, 6), h.app.live_rows);

    // Grow the viewport (as a SIGWINCH would) and repaint.
    h.app.options.term_size = .{ .w = 30, .h = 10 };
    try h.vt.resize(30, 10);
    try h.app.frame(try fullRoot(h.app.arena(), "after"));
    h.replay();

    try testing.expectEqual(@as(u16, 10), h.app.live_rows);
    try testing.expect(h.vt.containsText("after"));
    try testing.expect(!h.vt.containsText("before"));
    try testing.expect(h.vt.cursorAt(0, 0));
}

// ---- Short-terminal Table clipping regression ------------------------------
//
// The fullscreen example (`examples/fullscreen.zig`) once passed the process
// `Table` a hand-counted `visible_rows = 8` for both `view` and `handle`. On a
// terminal too short to fit the whole grid, the surrounding box clipped the
// table's bottom body row, but the widget still believed it owned 8 rows — so
// walking the selection down parked it on a row the layout never painted (the
// selection sat "one row below the view", scrolling but staying out of sight).
//
// The fix sizes the window from the *measured* space: the table node fills the
// vertical gap, `ui.probe` reports how many rows it actually got, and the next
// frame's window is `probed.h - header_rows`. These tests reproduce the demo's
// shape at a deliberately short height and assert the highlighted row's text is
// always painted while walking the selection to the bottom.

const Table = ui.widgets.Table;

const clip_cols = [_]Table.Column{
    .{ .header = "PID", .width = .{ .len = 5 } },
    .{ .header = "NAME", .width = .{ .fill = 1 } },
};

const clip_rows_n = 28;

/// A frame shaped like the fullscreen demo: title + tab-bar row + blank, then
/// the process `Table`, then a status line. `fill` mirrors the fixed example
/// (table node fills the gap so `probe` measures the real body height); when
/// false it reproduces the old hand-counted layout for the failing test.
fn clipFrame(a: std.mem.Allocator, table: *Table, visible: usize, rect: *ui.Rect, fill: bool) !ui.Node {
    var rows = std.ArrayList(ui.Node).empty;
    try rows.append(a, ui.text(.{ .bold = true }, "zcli top"));
    try rows.append(a, ui.text(.{}, "1 Processes  2 About"));
    try rows.append(a, ui.text(.{}, ""));

    const grid = try a.alloc([]const []const u8, clip_rows_n);
    for (grid, 0..) |*cells, i| {
        const rc = try a.alloc([]const u8, 2);
        rc[0] = try std.fmt.allocPrint(a, "{d}", .{1000 + i});
        rc[1] = try std.fmt.allocPrint(a, "row{d:0>2}", .{i});
        cells.* = rc;
    }
    var node = try table.view(a, .{
        .focused = true,
        .columns = &clip_cols,
        .rows = grid,
        .height = @intCast(visible),
        .scrollbar = true,
    });
    if (fill) node.height = .{ .fill = 1 };
    try rows.append(a, try ui.probe(a, rect, node));
    if (!fill) try rows.append(a, ui.spacer());
    try rows.append(a, ui.text(.{}, "status line here"));

    return ui.column(a, .{ .width = .{ .fill = 1 }, .height = .{ .fill = 1 }, .padding = .all(1) }, rows.items);
}

fn selectionVisible(h: *Harness, table: *const Table) !bool {
    const want = try std.fmt.allocPrint(testing.allocator, "row{d:0>2}", .{table.highlighted});
    defer testing.allocator.free(want);
    return h.vt.containsText(want);
}

test "short-terminal Table keeps the selection painted (fill + probed window)" {
    // 13 rows: two rows short of fitting the header + 8-row window plus chrome.
    var h = try Harness.initMode(80, 13, .full_screen);
    defer h.deinit();

    var table = Table{};
    var rect = ui.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
    var visible: usize = 8; // seed; overwritten from the probe below

    // Walk the selection from the top to the last row; the highlighted row must
    // stay on screen the whole way down.
    for (0..clip_rows_n) |_| {
        if (rect.h > Table.header_rows) visible = @max(1, rect.h - Table.header_rows);
        try h.app.frame(try clipFrame(h.app.arena(), &table, visible, &rect, true));
        h.replay();
        try testing.expect(try selectionVisible(h, &table));
        _ = table.handle(.down, clip_rows_n, @intCast(visible));
    }
}

test "REGRESSION: hand-counted window clips the selection on a short terminal" {
    // The pre-fix layout: a fixed visible = 8 passed to both view and handle,
    // with the table at natural height + a trailing spacer. On this short
    // terminal the box clips the bottom body row, so the selection parks off
    // screen — this asserts the broken behavior the fix removes, so the fixed
    // test above is a genuine guard.
    var h = try Harness.initMode(80, 13, .full_screen);
    defer h.deinit();

    var table = Table{};
    var rect = ui.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
    const visible: usize = 8;

    var ever_missed = false;
    for (0..clip_rows_n) |_| {
        try h.app.frame(try clipFrame(h.app.arena(), &table, visible, &rect, false));
        h.replay();
        if (!(try selectionVisible(h, &table))) ever_missed = true;
        _ = table.handle(.down, clip_rows_n, @intCast(visible));
    }
    try testing.expect(ever_missed); // the bug: selection went off screen
}
