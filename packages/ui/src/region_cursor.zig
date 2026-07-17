//! RegionCursor: the owner of the diff renderer's addressing invariant.
//!
//! The invariant (ADR-0013): between operations, the real terminal cursor is
//! PARKED at column 0 of the live region's top row. `diff.zig` addresses
//! every paint relative to that cell — relative moves only, no absolute CUP,
//! because the region floats in normal-screen scrollback where absolute rows
//! are meaningless. Every paint, emit, and clear assumes the park; a cursor
//! left anywhere else corrupts the next paint's addressing.
//!
//! This type is where the invariant lives in code rather than prose:
//!
//! - `place` is the one sanctioned excursion — show the hardware cursor at a
//!   region-relative cell (a line editor's insertion point, a focused
//!   field's caret, ADR-0019). It records the excursion so it can be undone.
//! - `park` reverses the excursion: hide the cursor and return it to the
//!   region's top-left. Idempotent — parking a parked cursor writes nothing.
//! - `isParked` is the checkable form: anything about to hand bytes to the
//!   diff renderer asserts it (see `App.frame`).
//! - `anchor` re-establishes the park at the screen origin from an unknown
//!   cursor position — full-screen entry and resize, the two moments the
//!   terminal itself invalidates the parked position (ADR-0015 choice 2).
//!
//! The cursor-hide/show escapes emitted here are the region-excursion pair
//! only; session-level cursor ownership (hide on takeover, show on restore)
//! stays with `App`/`TerminalSession`.

const std = @import("std");

pub const RegionCursor = struct {
    pub const Pos = struct { x: u16, y: u16 };

    /// Where the cursor currently sits within the live region
    /// (region-relative), if it is away from the park. `null` == parked.
    placed: ?Pos = null,

    /// Whether the invariant holds right now — the assertable form.
    pub fn isParked(self: *const RegionCursor) bool {
        return self.placed == null;
    }

    /// The sanctioned excursion: show the real cursor at `pos`
    /// (region-relative). Re-parks any previous excursion first, so the
    /// relative moves always start from the region's top-left. The caller
    /// clamps `pos` to the region — this type tracks position, not geometry.
    pub fn place(self: *RegionCursor, writer: *std.Io.Writer, pos: Pos) !void {
        try self.park(writer);
        if (pos.y > 0) try writer.print("\x1b[{d}B", .{pos.y});
        try writer.writeByte('\r');
        if (pos.x > 0) try writer.print("\x1b[{d}C", .{pos.x});
        try writer.writeAll("\x1b[?25h");
        self.placed = pos;
    }

    /// Restore the invariant: hide the placed cursor and return it to the
    /// region's top-left. Idempotent — a parked cursor writes zero bytes.
    pub fn park(self: *RegionCursor, writer: *std.Io.Writer) !void {
        const pos = self.placed orelse return;
        self.placed = null;
        try writer.writeAll("\x1b[?25l\r");
        if (pos.y > 0) try writer.print("\x1b[{d}A", .{pos.y});
    }

    /// Establish the park at the screen origin from an unknown cursor
    /// position: CR plus a viewport-height CUU that clamps at the top row.
    /// One relative sequence, so the diff renderer stays CUP-free. Used on
    /// full-screen entry and after a resize — must not be called with an
    /// outstanding excursion (`park` first; asserted).
    pub fn anchor(self: *const RegionCursor, writer: *std.Io.Writer, viewport_h: u16) !void {
        std.debug.assert(self.isParked());
        try writer.writeByte('\r');
        if (viewport_h > 0) try writer.print("\x1b[{d}A", .{viewport_h});
    }
};

// ============================================================================
// Tests: the invariant, enforced at the byte level.
// ============================================================================

const testing = std.testing;

test "place moves down/right from the park and shows the cursor" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    var cur = RegionCursor{};

    try cur.place(&aw.writer, .{ .x = 5, .y = 2 });
    try testing.expectEqualStrings("\x1b[2B\r\x1b[5C\x1b[?25h", aw.written());
    try testing.expect(!cur.isParked());
}

test "park reverses the excursion exactly and is idempotent" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    var cur = RegionCursor{};

    try cur.place(&aw.writer, .{ .x = 5, .y = 2 });
    aw.clearRetainingCapacity();

    try cur.park(&aw.writer);
    // Hide, CR, and undo the vertical move — back at the region's top-left.
    try testing.expectEqualStrings("\x1b[?25l\r\x1b[2A", aw.written());
    try testing.expect(cur.isParked());

    // Parking a parked cursor writes nothing (the invariant already holds).
    aw.clearRetainingCapacity();
    try cur.park(&aw.writer);
    try testing.expectEqual(@as(usize, 0), aw.written().len);
}

test "place while placed re-parks first so moves stay region-relative" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    var cur = RegionCursor{};

    try cur.place(&aw.writer, .{ .x = 3, .y = 1 });
    aw.clearRetainingCapacity();
    try cur.place(&aw.writer, .{ .x = 0, .y = 2 });
    // The second place starts by undoing the first (hide + up 1), then moves
    // from the park — never a diagonal from the old excursion.
    try testing.expectEqualStrings("\x1b[?25l\r\x1b[1A\x1b[2B\r\x1b[?25h", aw.written());
    try testing.expectEqual(RegionCursor.Pos{ .x = 0, .y = 2 }, cur.placed.?);
}

test "row-0 place and park emit no vertical moves" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    var cur = RegionCursor{};

    try cur.place(&aw.writer, .{ .x = 4, .y = 0 });
    try testing.expectEqualStrings("\r\x1b[4C\x1b[?25h", aw.written());
    aw.clearRetainingCapacity();
    try cur.park(&aw.writer);
    try testing.expectEqualStrings("\x1b[?25l\r", aw.written());
}

test "anchor emits CR + clamping CUU for the viewport height" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    var cur = RegionCursor{};

    try cur.anchor(&aw.writer, 24);
    try testing.expectEqualStrings("\r\x1b[24A", aw.written());

    aw.clearRetainingCapacity();
    try cur.anchor(&aw.writer, 0);
    try testing.expectEqualStrings("\r", aw.written());
}
