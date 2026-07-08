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

/// Pick the visible window over `n` items. `rowCount(ctx, i)` returns the
/// physical (wrapped) row count of item `i` — computed on demand so callers
/// need no allocated counts array. Grows from the cursor outward (upward first,
/// matching the existing scroll feel) until `budget` rows are used.
pub fn viewport(
    n: usize,
    cursor: usize,
    budget: usize,
    ctx: anytype,
    comptime rowCount: fn (@TypeOf(ctx), usize) usize,
) Window {
    if (n == 0) return .{ .start = 0, .end = 0 };
    var used = rowCount(ctx, cursor);
    var start = cursor;
    while (start > 0) {
        const c = rowCount(ctx, start - 1);
        if (used + c > budget) break;
        used += c;
        start -= 1;
    }
    var end = cursor + 1;
    while (end < n) {
        const c = rowCount(ctx, end);
        if (used + c > budget) break;
        used += c;
        end += 1;
    }
    return .{ .start = start, .end = end };
}

const testing = std.testing;

const CountSlice = struct {
    counts: []const usize,
    fn at(self: *const CountSlice, i: usize) usize {
        return self.counts[i];
    }
};

test "viewport keeps cursor visible within budget" {
    const cs = CountSlice{ .counts = &.{ 1, 1, 1, 1, 1, 1, 1, 1 } };
    const win = viewport(cs.counts.len, 5, 3, &cs, CountSlice.at);
    try testing.expect(win.start <= 5 and 5 < win.end);
    try testing.expect(win.end - win.start <= 3);
}

test "viewport shows everything when it fits" {
    const cs = CountSlice{ .counts = &.{ 2, 1, 3 } };
    const win = viewport(cs.counts.len, 0, 100, &cs, CountSlice.at);
    try testing.expectEqual(@as(usize, 0), win.start);
    try testing.expectEqual(@as(usize, 3), win.end);
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
