//! Golden-frame tests: drive the indicators through a virtual terminal and
//! assert what a user sees — the finish-line contract (result persists as a
//! static line, live region gone) is the heart of the ui-engine port.

const std = @import("std");
const vterm = @import("vterm");
const progress = @import("Progress.zig");

const testing = std.testing;
const VTerm = vterm.VTerm;

const Capture = struct {
    aw: std.Io.Writer.Allocating,
    vt: VTerm,
    fed: usize = 0,

    fn init(w: u16, h: u16) !Capture {
        return .{
            .aw = std.Io.Writer.Allocating.init(testing.allocator),
            .vt = try VTerm.init(testing.allocator, w, h),
        };
    }

    fn deinit(self: *Capture) void {
        self.vt.deinit();
        self.aw.deinit();
    }

    fn replay(self: *Capture) void {
        self.vt.write(self.aw.written()[self.fed..]);
        self.fed = self.aw.written().len;
    }
};

fn force(app: anytype, w: u16, h: u16) void {
    app.options.interactive = true;
    app.options.term_size = .{ .w = w, .h = h };
}

test "spinner succeed replaces the live line with one static result line" {
    var c = try Capture.init(40, 6);
    defer c.deinit();

    var s = try progress.Spinner.init(testing.allocator, &c.aw.writer, testing.io, .fallback, .{});
    force(&s.app, 40, 6);

    s.start("working on it");
    c.replay();
    try testing.expect(c.vt.containsText("working on it"));

    s.succeed("all done");
    c.replay();
    try testing.expect(c.vt.containsText("all done"));
    try testing.expect(!c.vt.containsText("working on it"));
    // The result is a static line at the top; the cursor is restored and
    // parked at the start of the next line, ready for normal output.
    const line0 = try c.vt.getLine(testing.allocator, 0);
    defer testing.allocator.free(line0);
    try testing.expect(std.mem.indexOf(u8, line0, "all done") != null);
    try testing.expect(c.vt.cursor_visible);
    try testing.expect(c.vt.cursorAt(0, 1));
}

test "progress bar final frame persists below earlier output" {
    var c = try Capture.init(60, 6);
    defer c.deinit();

    var bar = try progress.ProgressBar.init(testing.allocator, &c.aw.writer, testing.io, .fallback, .{
        .total = 10,
        .width = 10,
        .show_eta = false,
    });
    force(&bar.app, 60, 6);

    bar.update(5, "importing");
    c.replay();
    try testing.expect(c.vt.containsText("importing"));
    try testing.expect(c.vt.containsText("50%"));

    bar.finish();
    c.replay();
    try testing.expect(c.vt.containsText("100%"));
    try testing.expect(c.vt.containsText("10/10"));
    try testing.expect(c.vt.cursor_visible);
}

test "multi bar stacks one row per item and updates in place" {
    var c = try Capture.init(60, 8);
    defer c.deinit();

    var mb = try progress.MultiBar.init(testing.allocator, &c.aw.writer, testing.io, .fallback, .{});
    defer mb.deinit();
    force(&mb.app, 60, 8);

    const api = try mb.add("api", 100);
    const assets = try mb.add("assets", 100);
    c.replay();
    try testing.expect(c.vt.containsText("api"));
    try testing.expect(c.vt.containsText("assets"));
    try testing.expect(c.vt.containsText("  0%"));

    mb.set(api, 50);
    mb.set(assets, 100);
    c.replay();
    try testing.expect(c.vt.containsText(" 50%"));
    try testing.expect(c.vt.containsText("100%"));

    // Rows are stable: api on row 0, assets on row 1.
    const line0 = try c.vt.getLine(testing.allocator, 0);
    defer testing.allocator.free(line0);
    const line1 = try c.vt.getLine(testing.allocator, 1);
    defer testing.allocator.free(line1);
    try testing.expect(std.mem.startsWith(u8, line0, "api"));
    try testing.expect(std.mem.startsWith(u8, line1, "assets"));

    mb.finish();
    c.replay();
    try testing.expect(c.vt.cursor_visible);
}
