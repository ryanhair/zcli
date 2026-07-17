//! HybridScrollback against a vterm, standalone — no App in the loop. These
//! prove the reflow component honors its cursor contract on a real screen
//! model: entered with the cursor at column 0 of the live region's top row
//! (here: the line just below the tail), it leaves the screen rewrapped at
//! the new width and the cursor at column 0 of the row where the region
//! would be re-reserved. vterm is a NON-reflowing terminal (resize
//! truncates/pads rows), so every correct rewrap is the component's doing.

const std = @import("std");
const vterm = @import("vterm");
const scrollback_mod = @import("hybrid_scrollback.zig");

const testing = std.testing;
const VTerm = vterm.VTerm;
const HybridScrollback = scrollback_mod.HybridScrollback;

const Harness = struct {
    aw: std.Io.Writer.Allocating,
    vt: VTerm,
    sb: HybridScrollback,
    arena: std.heap.ArenaAllocator,
    fed: usize = 0,

    fn init(w: u16, h: u16) !Harness {
        return .{
            .aw = std.Io.Writer.Allocating.init(testing.allocator),
            .vt = try VTerm.init(testing.allocator, w, h),
            .sb = HybridScrollback.init(testing.allocator),
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
        };
    }

    fn deinit(self: *Harness) void {
        self.arena.deinit();
        self.sb.deinit();
        self.vt.deinit();
        self.aw.deinit();
    }

    /// Feed everything newly written into the terminal.
    fn replay(self: *Harness) void {
        self.vt.write(self.aw.written()[self.fed..]);
        self.fed = self.aw.written().len;
    }

    /// What `emit` does with a static block: print it (the cursor advances
    /// past it, landing at column 0 of the would-be region's top row) and
    /// retain the source for later reflow.
    fn emitBlock(self: *Harness, text: []const u8, width: u16, budget: u32) !void {
        try self.aw.writer.writeAll(text);
        const owned = try testing.allocator.dupe(u8, text);
        errdefer testing.allocator.free(owned);
        try self.sb.retain(owned, width, budget);
        self.replay();
    }

    fn reflow(self: *Harness, new_width: u16, budget: u32) !void {
        try self.sb.reflow(&self.aw.writer, self.arena.allocator(), new_width, budget);
        self.replay();
    }

    fn expectLine(self: *Harness, row: u16, prefix: []const u8) !void {
        const line = try self.vt.getLine(testing.allocator, row);
        defer testing.allocator.free(line);
        try testing.expect(std.mem.startsWith(u8, line, prefix));
    }

    fn expectBlank(self: *Harness, row: u16) !void {
        const line = try self.vt.getLine(testing.allocator, row);
        defer testing.allocator.free(line);
        try testing.expectEqual(@as(usize, 0), std.mem.trim(u8, line, " ").len);
    }
};

test "reflow rewraps the tail on a width shrink and parks below it" {
    var h = try Harness.init(40, 10);
    defer h.deinit();

    // 34 cols: one row at width 40.
    try h.emitBlock("static: the quick brown fox jumps!\r\n", 40, 9);
    try testing.expect(h.vt.cursorAt(0, 1));

    // The terminal narrows; vterm truncates the row (no self-reflow).
    try h.vt.resize(20, 10);
    try h.reflow(20, 9);

    // The component erased and reprinted the tail; the terminal rewrapped it
    // onto rows 0-1, and the cursor sits where the live region would be
    // re-reserved: column 0 of row 2.
    try h.expectLine(0, "static: the quick br");
    try h.expectLine(1, "own fox jumps!");
    try testing.expect(h.vt.cursorAt(0, 2));
}

test "reflow unwraps the tail on a width grow without stale rows" {
    var h = try Harness.init(20, 10);
    defer h.deinit();

    // 34 cols: two rows at width 20.
    try h.emitBlock("static: the quick brown fox jumps!\r\n", 20, 9);
    try testing.expect(h.vt.cursorAt(0, 2));

    try h.vt.resize(40, 10);
    try h.reflow(40, 9);

    // The whole line fits row 0 again; the old second row must not survive
    // as a stale duplicate, and the park moves up with the shrunken tail.
    try h.expectLine(0, "static: the quick brown fox jumps!");
    try h.expectBlank(1);
    try testing.expect(h.vt.cursorAt(0, 1));
}

test "multi-block tail survives a shrink-then-grow round trip" {
    var h = try Harness.init(40, 12);
    defer h.deinit();

    try h.emitBlock("first: alpha beta gamma delta epsilon\r\n", 40, 11); // 37 cols
    try h.emitBlock("second: one two three\r\n", 40, 11); // 21 cols
    try testing.expect(h.vt.cursorAt(0, 2));

    // Shrink: both blocks rewrap (37→2 rows, 21→2 rows at width 20).
    try h.vt.resize(20, 12);
    try h.reflow(20, 11);
    try h.expectLine(0, "first: alpha beta ga");
    try h.expectLine(1, "mma delta epsilon");
    try h.expectLine(2, "second: one two thre");
    try h.expectLine(3, "e");
    try testing.expect(h.vt.cursorAt(0, 4));

    // Grow back: both unwrap to one row each, nothing stale below.
    try h.vt.resize(40, 12);
    try h.reflow(40, 11);
    try h.expectLine(0, "first: alpha beta gamma delta epsilon");
    try h.expectLine(1, "second: one two three");
    try h.expectBlank(2);
    try testing.expect(h.vt.cursorAt(0, 2));
}

test "reflow reprints only what the budget keeps" {
    var h = try Harness.init(40, 6);
    defer h.deinit();

    // Five one-row blocks against a 5-row budget (6-row terminal, 1-row
    // region): all retained.
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        var buf: [24]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "log line {d}\r\n", .{i});
        try h.emitBlock(line, 40, 5);
    }
    try testing.expectEqual(@as(usize, 5), h.sb.len());

    // Width shrink with a live region now 3 rows tall: budget drops to 3, so
    // only the newest 3 blocks stay reflowable.
    try h.vt.resize(30, 6);
    try h.reflow(30, 3);
    try testing.expectEqual(@as(usize, 3), h.sb.len());
    try testing.expect(h.vt.containsText("log line 4"));
    try testing.expect(h.vt.containsText("log line 2"));
}
