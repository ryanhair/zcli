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
        const self = try testing.allocator.create(Harness);
        errdefer testing.allocator.destroy(self);
        self.* = .{
            .aw = std.Io.Writer.Allocating.init(testing.allocator),
            .vt = try VTerm.init(testing.allocator, w, h),
            .app = undefined,
        };
        self.app = try ui.App.init(testing.allocator, &self.aw.writer, .{
            .term_size = .{ .w = w, .h = h },
        });
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
