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
