//! Frame-diff renderer: turns a (previous, next) surface pair into a minimal
//! byte stream of relative cursor moves and SGR runs (ADR-0013).
//!
//! Addressing contract: the cursor is at column 0 of the region's TOP row on
//! entry and is returned there on exit. All vertical movement is relative
//! (CUD/CUU) and columns are addressed with CR + CUF, never absolute CUP —
//! the live region floats in normal-screen scrollback, where absolute rows
//! are meaningless. The App loop owns creating the region's rows; the parked
//! cursor is owned and enforced by `RegionCursor` (region_cursor.zig) — the
//! App asserts `isParked()` before every paint. This renderer never scrolls.

const std = @import("std");
const theme = @import("theme");
const surface_mod = @import("surface.zig");

const Surface = surface_mod.Surface;
const Cell = surface_mod.Cell;
const Style = surface_mod.Style;
const styleEql = surface_mod.styleEql;

pub const Renderer = struct {
    capability: theme.TerminalCapability,
    /// Wrap paints in synchronized output (DECSET 2026) so the terminal
    /// presents the frame atomically. An anti-flicker optimization, never a
    /// correctness dependency — terminals that don't know the mode ignore it.
    sync: bool = true,

    /// Paint `next` given that the terminal currently shows `prev`. Passing
    /// `prev = null` (or surfaces of different sizes) forces a full repaint
    /// that assumes nothing about what's on screen. Emits nothing at all for
    /// an unchanged frame.
    pub fn paint(
        self: Renderer,
        writer: *std.Io.Writer,
        prev: ?*const Surface,
        next: *const Surface,
    ) !void {
        const full = prev == null or
            prev.?.width != next.width or prev.?.height != next.height;

        var st = EmitState{
            .writer = writer,
            .capability = self.capability,
            .sync = self.sync,
        };

        var row: u16 = 0;
        while (row < next.height) : (row += 1) {
            if (full) {
                try self.paintRowFull(&st, next, row);
            } else {
                try self.paintRowDiff(&st, prev.?, next, row);
            }
        }
        try st.finish();
    }

    /// Full repaint of one row: emit from column 0 through the last cell that
    /// is visibly non-empty, then erase the unknown remainder with EL.
    fn paintRowFull(self: Renderer, st: *EmitState, next: *const Surface, row: u16) !void {
        _ = self;
        var last: u16 = 0;
        var has_content = false;
        var x: u16 = 0;
        while (x < next.width) : (x += 1) {
            const c = next.cell(x, row);
            if (!(c.isBlank() and styleEql(c.style, .{}))) {
                last = x;
                has_content = true;
            }
        }
        try st.moveTo(row, 0);
        if (has_content) try st.emitCells(next, row, 0, last);
        // Erase the unknown remainder — unless the row ran through the last
        // column, where there is nothing right of the cursor to erase (and
        // with autowrap disabled the cursor is clamped ON the last cell, so
        // EL would eat it). Normalize style first: EL fills with the SGR
        // background.
        if (!has_content or last + 1 < next.width) {
            try st.setStyle(.{});
            try st.writer.writeAll("\x1b[K");
        }
    }

    /// Diff one row: emit the single span from the first to the last changed
    /// cell (unchanged cells inside the span repaint — cheaper than extra
    /// cursor moves). A span never starts on a wide continuation: either half
    /// changing repaints from the head, so a wide grapheme is always whole.
    fn paintRowDiff(
        self: Renderer,
        st: *EmitState,
        prev: *const Surface,
        next: *const Surface,
        row: u16,
    ) !void {
        _ = self;
        var first: u16 = 0;
        var last: u16 = 0;
        var dirty = false;
        var x: u16 = 0;
        while (x < next.width) : (x += 1) {
            if (cellEql(prev, prev.cell(x, row), next, next.cell(x, row))) continue;
            if (!dirty) first = x;
            last = x;
            dirty = true;
        }
        if (!dirty) return;

        while (first > 0 and next.cell(first, row).isContinuation()) first -= 1;
        // Extend the span over a wide grapheme's continuation. Bound-check so a
        // torn head at the last column (width 2 with no continuation cell) can
        // never push `last` past the surface edge.
        if (last + 1 < next.width and next.cell(last, row).width == 2) last += 1;

        try st.moveTo(row, first);
        try st.emitCells(next, row, first, last);
    }
};

fn cellEql(ps: *const Surface, a: Cell, ns: *const Surface, b: Cell) bool {
    return a.width == b.width and
        styleEql(a.style, b.style) and
        std.mem.eql(u8, ps.cellText(a), ns.cellText(b));
}

const EmitState = struct {
    writer: *std.Io.Writer,
    capability: theme.TerminalCapability,
    sync: bool,
    started: bool = false,
    cur_row: u16 = 0,
    cur_col: u16 = 0,
    cur_style: Style = .{},

    /// Lazily open the paint: the sync guard, autowrap OFF, and an SGR reset
    /// (the terminal's current attributes are unknown). Only runs if
    /// something gets painted, so an unchanged frame emits zero bytes.
    ///
    /// Autowrap (DECAWM) is disabled for the paint's duration because this
    /// renderer legitimately writes the last column (borders, full-width
    /// rows), and a wrap there desynchronizes relative row addressing —
    /// worse, terminals disagree on WHEN it happens (deferred on the xterm
    /// family, immediate on the legacy Windows console). With wrap off the
    /// cursor deterministically clamps and CR/CUU stay exact.
    fn start(self: *EmitState) !void {
        if (self.started) return;
        self.started = true;
        if (self.sync) try self.writer.writeAll("\x1b[?2026h");
        try self.writer.writeAll("\x1b[?7l");
        if (self.capability != .no_color) try self.writer.writeAll("\x1b[0m");
    }

    /// Return the cursor to the region's top-left, restore default SGR and
    /// autowrap, and close the sync guard.
    fn finish(self: *EmitState) !void {
        if (!self.started) return;
        try self.setStyle(.{});
        try self.writer.writeByte('\r');
        if (self.cur_row > 0) try self.writer.print("\x1b[{d}A", .{self.cur_row});
        try self.writer.writeAll("\x1b[?7h");
        if (self.sync) try self.writer.writeAll("\x1b[?2026l");
    }

    /// Move to (row, col) in region coordinates. Rows are visited in order,
    /// so vertical movement is always downward.
    fn moveTo(self: *EmitState, row: u16, col: u16) !void {
        try self.start();
        std.debug.assert(row >= self.cur_row);
        if (row > self.cur_row) {
            try self.writer.print("\x1b[{d}B", .{row - self.cur_row});
            self.cur_row = row;
        }
        try self.writer.writeByte('\r');
        if (col > 0) try self.writer.print("\x1b[{d}C", .{col});
        self.cur_col = col;
    }

    fn setStyle(self: *EmitState, style: Style) !void {
        if (self.capability == .no_color) return;
        if (styleEql(style, self.cur_style)) return;
        try self.writer.writeAll("\x1b[0m");
        _ = try style.writeSequence(self.writer, self.capability);
        self.cur_style = style;
    }

    /// Emit the cells first..=last of `row`. A wide grapheme's head advances
    /// `x` by 2, stepping over its continuation cell so both columns are
    /// painted by the head's write. An orphan continuation — reachable only
    /// when a span begins mid-character during a full repaint of a
    /// blank-headed row — falls through to the general path below, which
    /// paints it as a styled space (`text_len == 0`) and advances one column
    /// (`@max(c.width, 1)`), keeping `cur_col` in lockstep with the model.
    fn emitCells(self: *EmitState, s: *const Surface, row: u16, first: u16, last: u16) !void {
        var x = first;
        while (x <= last) {
            const c = s.cell(x, row);
            try self.setStyle(c.style);
            if (c.text_len == 0) {
                try self.writer.writeByte(' ');
            } else {
                try self.writer.writeAll(s.cellText(c));
            }
            self.cur_col += @max(c.width, 1);
            x += @max(c.width, 1);
        }
    }
};

// ============================================================================
// Tests (byte-level; behavior-level golden tests live in golden_test.zig)
// ============================================================================

const testing = std.testing;

fn paintToString(
    allocator: std.mem.Allocator,
    r: Renderer,
    prev: ?*const Surface,
    next: *const Surface,
) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try r.paint(&aw.writer, prev, next);
    return allocator.dupe(u8, aw.written());
}

test "unchanged frame emits zero bytes" {
    var a = try Surface.init(testing.allocator, 8, 2);
    defer a.deinit();
    var b = try Surface.init(testing.allocator, 8, 2);
    defer b.deinit();
    _ = try a.root().writeText(0, 0, "same", .{});
    _ = try b.root().writeText(0, 0, "same", .{});

    const out = try paintToString(testing.allocator, .{ .capability = .ansi_16 }, &a, &b);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "diff paints only the changed span" {
    var a = try Surface.init(testing.allocator, 20, 2);
    defer a.deinit();
    var b = try Surface.init(testing.allocator, 20, 2);
    defer b.deinit();
    _ = try a.root().writeText(0, 0, "stable line", .{});
    _ = try a.root().writeText(0, 1, "count 1", .{});
    _ = try b.root().writeText(0, 0, "stable line", .{});
    _ = try b.root().writeText(0, 1, "count 2", .{});

    const out = try paintToString(testing.allocator, .{ .capability = .ansi_16, .sync = false }, &a, &b);
    defer testing.allocator.free(out);
    // Only the one changed cell on row 1: move down, column 6, paint "2",
    // return. No trace of the unchanged text.
    try testing.expect(std.mem.indexOf(u8, out, "stable") == null);
    try testing.expect(std.mem.indexOf(u8, out, "2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "count") == null);
    try testing.expect(out.len < 32);
}

test "sync guard wraps the paint when enabled" {
    var next = try Surface.init(testing.allocator, 4, 1);
    defer next.deinit();
    _ = try next.root().writeText(0, 0, "x", .{});

    const out = try paintToString(testing.allocator, .{ .capability = .ansi_16 }, null, &next);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "\x1b[?2026h"));
    try testing.expect(std.mem.endsWith(u8, out, "\x1b[?2026l"));
}

test "diff never extends a span past the surface edge on a torn wide head" {
    var prev = try Surface.init(testing.allocator, 4, 1);
    defer prev.deinit();
    var next = try Surface.init(testing.allocator, 4, 1);
    defer next.deinit();
    // Synthesize a torn wide head at the last column: a width-2 cell whose
    // continuation would fall at column 4, off the surface edge. copyRows now
    // prevents this tear at the source, but the diff's wide-span extension must
    // still stay in bounds — `last + 1 < next.width` guards `last += 1` from
    // ever addressing column `width`.
    next.cells[3] = .{ .width = 2 };

    const out = try paintToString(testing.allocator, .{ .capability = .ansi_16, .sync = false }, &prev, &next);
    defer testing.allocator.free(out);
    try testing.expect(out.len > 0);
}

test "span starting on an orphan continuation paints a space so the cursor stays in lockstep" {
    var prev = try Surface.init(testing.allocator, 4, 1);
    defer prev.deinit();
    var next = try Surface.init(testing.allocator, 4, 1);
    defer next.deinit();
    // Synthesize an orphan continuation at column 0: a width-0 cell with no
    // head to its left. `paintRowDiff` cannot back `first` off column 0
    // (the `first > 0` guard), so `emitCells` begins the span on the
    // continuation itself. It must paint a space and advance `cur_col`, or the
    // following real cell would be written one column too far left.
    next.cells[0] = .{ .width = 0 };
    _ = try next.root().writeText(1, 0, "X", .{});

    const out = try paintToString(testing.allocator, .{ .capability = .no_color, .sync = false }, &prev, &next);
    defer testing.allocator.free(out);
    // The continuation renders as a space, immediately followed by the head of
    // the next cell — no shift.
    try testing.expect(std.mem.indexOf(u8, out, " X") != null);
}

test "no_color paints text but never SGR" {
    var next = try Surface.init(testing.allocator, 6, 1);
    defer next.deinit();
    _ = try next.root().writeText(0, 0, "hi", .{ .bold = true, .foreground = .red });

    const out = try paintToString(testing.allocator, .{ .capability = .no_color, .sync = false }, null, &next);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "hi") != null);
    try testing.expect(std.mem.indexOf(u8, out, "m") == null); // no SGR final byte
}
