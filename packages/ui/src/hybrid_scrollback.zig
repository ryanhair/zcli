//! HybridScrollback: the retained static tail and its width-resize reflow
//! (ADR-0013 resize tier 2), extracted from the App loop so the
//! highest-complexity unit in the package is independently testable.
//!
//! In the hybrid mode, `emit` prints static text above the live region and it
//! flows into scrollback. The blocks that may still be VISIBLE above the
//! region are retained here in SOURCE form — the text, not rendered cells —
//! so a terminal width change can erase and reprint them, letting the
//! terminal rewrap the tail at the new width. Deeper scrollback keeps its old
//! wrap width; that seam is immutable by terminal authority. Retention is
//! bounded to about a screenful by eviction (nothing beyond the viewport can
//! be repainted anyway).
//!
//! Cursor contract (owned by `RegionCursor` in the App loop): `reflow` must
//! be entered with the cursor parked at column 0 of the live region's top
//! row, and it leaves the cursor at column 0 on the row where the live
//! region should be re-reserved, directly below the reprinted tail.

const std = @import("std");
const terminal = @import("terminal");

pub const HybridScrollback = struct {
    /// A static block kept for the resize tail repaint: the source text, plus
    /// the rows it occupies at the width it was last printed at (terminal
    /// character-wrapping, not word-wrapping).
    const Block = struct {
        text: []u8,
        rows: u16,
    };

    gpa: std.mem.Allocator,
    /// Recently emitted blocks that may still be visible above the live
    /// region — the reflowable tail. Oldest first.
    blocks: std.ArrayList(Block) = .empty,

    pub fn init(gpa: std.mem.Allocator) HybridScrollback {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *HybridScrollback) void {
        for (self.blocks.items) |b| self.gpa.free(b.text);
        self.blocks.deinit(self.gpa);
    }

    /// How many blocks are currently retained.
    pub fn len(self: *const HybridScrollback) usize {
        return self.blocks.items.len;
    }

    /// Retain `text` (just printed at `width`), taking ownership, then evict
    /// whatever no longer fits `budget` (the viewport rows above the live
    /// region). Retain-then-evict, in that order: eviction may free the very
    /// block being added. On error, ownership of `text` stays with the caller.
    pub fn retain(self: *HybridScrollback, text: []u8, width: u16, budget: u32) !void {
        try self.blocks.append(self.gpa, .{
            .text = text,
            .rows = textRows(text, width),
        });
        _ = self.evict(budget);
    }

    /// The width-resize repaint (ADR-0013 resize tier 2). The cursor sits at
    /// the live region's top; the retained tail sits directly above it. Move
    /// up over the tail's footprint (bottom-anchored, relative — CUU clamps
    /// at the viewport top exactly when the tail extends into scrollback),
    /// erase from there down, and reprint the tail so the terminal rewraps it
    /// at `new_width`. The caller re-reserves the live region below.
    ///
    /// The erase covers the LARGER of the kept blocks' old footprint and
    /// their new one: a tail that unwraps (width grew) must not leave its
    /// old extra rows stale above the reprint. Content above that is never
    /// touched. `scratch` is per-call working memory (the frame arena).
    pub fn reflow(
        self: *HybridScrollback,
        writer: *std.Io.Writer,
        scratch: std.mem.Allocator,
        new_width: u16,
        budget: u32,
    ) !void {
        // Old footprints, index-aligned with `blocks`.
        const olds = try scratch.alloc(u16, self.blocks.items.len);
        for (self.blocks.items, olds) |*b, *old| {
            old.* = b.rows;
            b.rows = textRows(b.text, new_width);
        }
        const dropped = self.evict(budget);

        var old_tail: u32 = 0;
        for (olds[dropped..]) |r| old_tail += r;
        var new_tail: u32 = 0;
        for (self.blocks.items) |b| new_tail += b.rows;

        try writer.writeByte('\r');
        const up = @max(old_tail, new_tail);
        if (up > 0) try writer.print("\x1b[{d}A", .{up});
        try writer.writeAll("\x1b[0J");
        for (self.blocks.items) |b| try writer.writeAll(b.text);
    }

    /// Drop blocks (oldest first) whose rows no longer fit in `budget` (the
    /// viewport rows above the live region) — they have scrolled beyond the
    /// viewport, where nothing can repaint them anyway. Returns how many were
    /// dropped.
    fn evict(self: *HybridScrollback, budget: u32) usize {
        var total: u32 = 0;
        var keep_from = self.blocks.items.len;
        var i = self.blocks.items.len;
        while (i > 0) {
            i -= 1;
            const rows = self.blocks.items[i].rows;
            if (total + rows > budget) break;
            total += rows;
            keep_from = i;
        }
        if (keep_from == 0) return 0;
        for (self.blocks.items[0..keep_from]) |b| self.gpa.free(b.text);
        const kept = self.blocks.items.len - keep_from;
        std.mem.copyForwards(
            Block,
            self.blocks.items[0..kept],
            self.blocks.items[keep_from..],
        );
        self.blocks.shrinkRetainingCapacity(kept);
        return keep_from;
    }

    /// Rows `text` occupies at `width` — the terminal's own soft-wrapping
    /// (hard character wrap at the last column), NOT `terminal.wrap`'s word
    /// wrap: emit prints raw text and the terminal breaks the lines, so the
    /// bookkeeping must count the way the terminal counts. (Tabs would
    /// desync this — emit output is expected tab-free.)
    pub fn textRows(text: []const u8, width: u16) u16 {
        const w: u32 = @max(width, 1);
        const body = std.mem.trimEnd(u8, text, "\r\n");
        var rows: u32 = 0;
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |line| {
            const cols: u32 = @intCast(terminal.displayWidth(line));
            rows += @max(1, (cols + w - 1) / w);
        }
        return @intCast(@min(rows, std.math.maxInt(u16)));
    }
};

// ============================================================================
// Byte-level tests. Terminal-behavior tests (does the reprint actually rewrap
// on a real screen model?) live in scrollback_test.zig against a vterm.
// ============================================================================

const testing = std.testing;

fn retainDupe(sb: *HybridScrollback, text: []const u8, width: u16, budget: u32) !void {
    const owned = try testing.allocator.dupe(u8, text);
    errdefer testing.allocator.free(owned);
    try sb.retain(owned, width, budget);
}

test "textRows counts terminal hard-wrapping" {
    try testing.expectEqual(@as(u16, 1), HybridScrollback.textRows("hello\r\n", 20));
    try testing.expectEqual(@as(u16, 2), HybridScrollback.textRows("exactly twenty col!!x\r\n", 20));
    // A width-20 line at width 20 is one row, not a phantom second.
    try testing.expectEqual(@as(u16, 1), HybridScrollback.textRows("exactly twenty cols!\r\n", 20));
    // Multi-line blocks count each line's wrap independently.
    try testing.expectEqual(@as(u16, 3), HybridScrollback.textRows("a\nb\nc\r\n", 20));
    // An empty line still occupies a row.
    try testing.expectEqual(@as(u16, 1), HybridScrollback.textRows("\r\n", 20));
}

test "retention stays bounded by the budget, evicting oldest first" {
    var sb = HybridScrollback.init(testing.allocator);
    defer sb.deinit();

    var i: u32 = 0;
    while (i < 12) : (i += 1) {
        var buf: [16]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "line {d}\r\n", .{i});
        try retainDupe(&sb, line, 30, 5);
    }
    // One-row blocks against a 5-row budget: at most 5 survive, the newest.
    try testing.expect(sb.len() <= 5);
    const last = sb.blocks.items[sb.len() - 1];
    try testing.expect(std.mem.startsWith(u8, last.text, "line 11"));
}

test "a block taller than the budget is evicted outright" {
    var sb = HybridScrollback.init(testing.allocator);
    defer sb.deinit();
    // 3 rows at width 10 against a budget of 2.
    try retainDupe(&sb, "aaaaaaaaaabbbbbbbbbbcc\r\n", 10, 2);
    try testing.expectEqual(@as(usize, 0), sb.len());
}

test "reflow erases the larger of old and new footprints" {
    var sb = HybridScrollback.init(testing.allocator);
    defer sb.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // 34 cols: 2 rows at width 20.
    const line = "static: the quick brown fox jumps!\r\n";
    try retainDupe(&sb, line, 20, 9);

    // Width grows to 40: old footprint 2 rows, new 1 — the erase must cover
    // the old 2, or the unwrapped reprint leaves a stale duplicate row.
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try sb.reflow(&aw.writer, arena.allocator(), 40, 9);
    try testing.expectEqualStrings("\r\x1b[2A\x1b[0J" ++ line, aw.written());
    try testing.expectEqual(@as(u16, 1), sb.blocks.items[0].rows);

    // Width shrinks back to 20: footprint 1 → 2, so up = max(1, 2) = 2 —
    // the CUU clamps at the viewport top when it overshoots the screen's
    // actual 1-row tail, which is exactly the bottom-anchored design.
    aw.clearRetainingCapacity();
    try sb.reflow(&aw.writer, arena.allocator(), 20, 9);
    try testing.expectEqualStrings("\r\x1b[2A\x1b[0J" ++ line, aw.written());
    try testing.expectEqual(@as(u16, 2), sb.blocks.items[0].rows);
}

test "reflow drops blocks that no longer fit and does not reprint them" {
    var sb = HybridScrollback.init(testing.allocator);
    defer sb.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try retainDupe(&sb, "old old old\r\n", 40, 9);
    try retainDupe(&sb, "keep me\r\n", 40, 9);

    // Budget collapses to 1 row: only the newest block survives the reflow,
    // and the up-move counts only the KEPT blocks' old footprint (the
    // dropped block has scrolled beyond the viewport).
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try sb.reflow(&aw.writer, arena.allocator(), 40, 1);
    try testing.expectEqual(@as(usize, 1), sb.len());
    try testing.expectEqualStrings("\r\x1b[1A\x1b[0J" ++ "keep me\r\n", aw.written());
}

test "reflow with nothing retained erases nothing above the region" {
    var sb = HybridScrollback.init(testing.allocator);
    defer sb.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try sb.reflow(&aw.writer, arena.allocator(), 40, 9);
    // No up-move (nothing to reflow over), just the clear-below for the
    // region the caller is about to re-reserve.
    try testing.expectEqualStrings("\r\x1b[0J", aw.written());
}
