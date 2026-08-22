//! Shared rendering machinery for the prompts: the viewport that scrolls to
//! keep the cursor visible, and the node builders every prompt frame is
//! assembled from. Prompts drive their own key loops and build frames with
//! these; painting, erasing, and row bookkeeping are the ui engine's job.

const std = @import("std");
const terminal = @import("terminal");

/// Current terminal size, defaulting to a sane 24x80 when it can't be queried
/// (e.g. output isn't a console).
pub fn windowSize() terminal.Winsize {
    return terminal.getWindowSize(std.Io.File.stdout().handle) catch .{ .row = 24, .col = 80 };
}

/// A contiguous window of items to display, chosen so the cursor stays visible
/// and the total physical rows fit within `budget`.
pub const Window = struct { start: usize, end: usize };

/// The scroll anchor of a list, carried across frames. Keeping the anchor is
/// what makes the visible window stable: the highlight moves inside the window
/// and only crossing an edge scrolls it, so reversing direction no longer
/// re-centers the list under the cursor.
pub const Viewport = struct {
    /// Index of the first visible item, written by `window` — which also
    /// clamps it when filtering or a resize leaves it stale.
    start: usize = 0,

    /// Pick the visible window over `n` items and re-anchor. `rowCount(ctx, i)`
    /// returns the physical (wrapped) row count of item `i` — computed on
    /// demand so callers need no allocated counts array. The window holds whole
    /// items whose rows fit `budget`, always including `cursor`.
    pub fn window(
        self: *Viewport,
        n: usize,
        cursor: usize,
        budget: usize,
        ctx: anytype,
        comptime rowCount: fn (@TypeOf(ctx), usize) usize,
    ) Window {
        if (n == 0) {
            self.start = 0;
            return .{ .start = 0, .end = 0 };
        }
        const highlight = @min(cursor, n - 1);

        // The earliest start that still leaves room for the cursor's own rows.
        // A start before it would scroll the highlight off the bottom.
        var lo = highlight;
        var used = rowCount(ctx, highlight);
        while (lo > 0) {
            const c = rowCount(ctx, lo - 1);
            if (used + c > budget) break;
            used += c;
            lo -= 1;
        }

        // Hold the anchor while the cursor is inside the window; a cursor past
        // an edge drags it exactly as far as that edge. Clamping also repairs
        // an anchor left stale by filtering or a resize.
        var start = std.math.clamp(self.start, lo, highlight);

        used = rowCount(ctx, start);
        var end = start + 1;
        while (end < n) {
            const c = rowCount(ctx, end);
            if (used + c > budget) break;
            used += c;
            end += 1;
        }
        // Spend leftover rows upward: the list ran out inside the window, or
        // the next item wraps to more rows than remain.
        while (start > 0) {
            const c = rowCount(ctx, start - 1);
            if (used + c > budget) break;
            used += c;
            start -= 1;
        }

        self.start = start;
        return .{ .start = start, .end = end };
    }
};

const testing = std.testing;

const CountSlice = struct {
    counts: []const usize,
    fn at(self: *const CountSlice, i: usize) usize {
        return self.counts[i];
    }
};

test "viewport keeps cursor visible within budget" {
    const cs = CountSlice{ .counts = &.{ 1, 1, 1, 1, 1, 1, 1, 1 } };
    var vp = Viewport{};
    const win = vp.window(cs.counts.len, 5, 3, &cs, CountSlice.at);
    try testing.expect(win.start <= 5 and 5 < win.end);
    try testing.expect(win.end - win.start <= 3);
}

test "viewport shows everything when it fits" {
    const cs = CountSlice{ .counts = &.{ 2, 1, 3 } };
    var vp = Viewport{};
    const win = vp.window(cs.counts.len, 0, 100, &cs, CountSlice.at);
    try testing.expectEqual(@as(usize, 0), win.start);
    try testing.expectEqual(@as(usize, 3), win.end);
}

test "viewport scrolls one item at a time at each edge and holds still between" {
    const cs = CountSlice{ .counts = &.{ 1, 1, 1, 1, 1, 1, 1, 1 } };
    var vp = Viewport{};

    // Walking down only scrolls once the cursor passes the bottom edge.
    for ([_]usize{ 0, 1, 2 }) |cursor| {
        const win = vp.window(cs.counts.len, cursor, 3, &cs, CountSlice.at);
        try testing.expectEqual(Window{ .start = 0, .end = 3 }, win);
    }
    try testing.expectEqual(Window{ .start = 1, .end = 4 }, vp.window(cs.counts.len, 3, 3, &cs, CountSlice.at));
    try testing.expectEqual(Window{ .start = 2, .end = 5 }, vp.window(cs.counts.len, 4, 3, &cs, CountSlice.at));

    // Reversing direction moves the highlight inside that same window ...
    try testing.expectEqual(Window{ .start = 2, .end = 5 }, vp.window(cs.counts.len, 3, 3, &cs, CountSlice.at));
    try testing.expectEqual(Window{ .start = 2, .end = 5 }, vp.window(cs.counts.len, 2, 3, &cs, CountSlice.at));
    // ... and only scrolls once it passes the top edge.
    try testing.expectEqual(Window{ .start = 1, .end = 4 }, vp.window(cs.counts.len, 1, 3, &cs, CountSlice.at));
}

test "viewport keeps wrapped items whole within the physical row budget" {
    // Item 2 wraps to three rows: it never shares the window with a neighbour.
    const cs = CountSlice{ .counts = &.{ 1, 1, 3, 1, 1 } };
    var vp = Viewport{};

    try testing.expectEqual(Window{ .start = 0, .end = 2 }, vp.window(cs.counts.len, 0, 3, &cs, CountSlice.at));
    try testing.expectEqual(Window{ .start = 2, .end = 3 }, vp.window(cs.counts.len, 2, 3, &cs, CountSlice.at));
    // Past the tall item the leftover budget is spent downward, not on a
    // half-empty window.
    try testing.expectEqual(Window{ .start = 3, .end = 5 }, vp.window(cs.counts.len, 3, 3, &cs, CountSlice.at));
    try testing.expectEqual(Window{ .start = 3, .end = 5 }, vp.window(cs.counts.len, 4, 3, &cs, CountSlice.at));
    // Reversing back over it re-anchors on the tall item alone.
    try testing.expectEqual(Window{ .start = 2, .end = 3 }, vp.window(cs.counts.len, 2, 3, &cs, CountSlice.at));
}

test "viewport repairs a stale anchor after the list shrinks or the terminal resizes" {
    const long = CountSlice{ .counts = &.{ 1, 1, 1, 1, 1, 1, 1, 1 } };
    var vp = Viewport{};
    _ = vp.window(long.counts.len, 7, 3, &long, CountSlice.at);
    try testing.expectEqual(@as(usize, 5), vp.start);

    // Filtering down to two items leaves the anchor past the end.
    const short = CountSlice{ .counts = &.{ 1, 1 } };
    const filtered = vp.window(short.counts.len, 0, 3, &short, CountSlice.at);
    try testing.expectEqual(Window{ .start = 0, .end = 2 }, filtered);

    // A taller terminal reveals more rows without losing the highlight.
    _ = vp.window(long.counts.len, 7, 3, &long, CountSlice.at);
    const grown = vp.window(long.counts.len, 7, 8, &long, CountSlice.at);
    try testing.expectEqual(Window{ .start = 0, .end = 8 }, grown);

    // A shorter one keeps it visible.
    const shrunk = vp.window(long.counts.len, 7, 2, &long, CountSlice.at);
    try testing.expectEqual(Window{ .start = 6, .end = 8 }, shrunk);

    // An empty list resets the anchor.
    const empty = CountSlice{ .counts = &.{} };
    try testing.expectEqual(Window{ .start = 0, .end = 0 }, vp.window(0, 0, 3, &empty, CountSlice.at));
    try testing.expectEqual(@as(usize, 0), vp.start);
}

// ---------------------------------------------------------------------------
// Node builders for the prompt frames.
// ---------------------------------------------------------------------------

pub const ui = @import("ui");

/// One list row for the engine: a fixed-width prefix cell and a wrapped label
/// of `label_w` columns. The hang indent the imperative path computed by hand
/// falls out of the layout — the prefix cell is one line tall, so a wrapped
/// label's continuation lines get blank cells beneath it. The label width is
/// explicit (not `fill`) so the row's measured height includes the wrap — a
/// fill child contributes nothing at measure time (ADR-0013 §5) and would
/// under-reserve the live region.
pub fn itemRow(
    a: std.mem.Allocator,
    prefix: ui.Node,
    prefix_w: u16,
    label: []const u8,
    label_w: u16,
    label_style: ui.Style,
) !ui.Node {
    var p = prefix;
    p.width = .{ .len = prefix_w };
    return ui.row(a, .{}, &.{
        p,
        ui.textOpts(.{ .style = label_style, .width = .{ .len = label_w } }, label),
    });
}

/// A single-style clipped prefix cell (glyphs never word-wrap).
pub fn prefixCell(style: ui.Style, content: []const u8) ui.Node {
    return ui.textOpts(.{ .style = style, .wrap = .clip }, content);
}
