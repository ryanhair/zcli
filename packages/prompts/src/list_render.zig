//! Shared rendering machinery for the list-style prompts (select, multi_select,
//! search): physical-row-accurate wrapping with a hang indent, a viewport that
//! scrolls to keep the cursor visible, and region erase that survives terminal
//! resize. Prompts supply their own per-item prefixes/colors via `ItemStyle`
//! and drive their own key loops; everything about *how many rows* get painted
//! and *how to wipe them* lives here.

const std = @import("std");
const terminal = @import("terminal");

/// Current terminal size, defaulting to a sane 24x80 when it can't be queried
/// (e.g. output isn't a console).
pub fn windowSize() terminal.Winsize {
    return terminal.getWindowSize(std.Io.File.stdout().handle) catch .{ .row = 24, .col = 80 };
}

/// Styling for one rendered item. `first_prefix` is printed on the item's first
/// physical line (the bullet/marker) and must have a display width equal to
/// `prefix_w`; continuation lines are padded to `prefix_w` so wrapped text
/// hang-indents under the label. `line_open`/`line_close` wrap every physical
/// line, letting a prompt colour the whole row (open) or just the marker
/// (baked into `first_prefix`) as it prefers.
pub const ItemStyle = struct {
    line_open: []const u8 = "",
    first_prefix: []const u8,
    prefix_w: usize,
    line_close: []const u8 = "",
};

/// Render `label` wrapped to `avail` display columns using `style`, returning
/// the number of physical rows emitted. `first_line` tracks whether a CRLF
/// separator is needed; rows are CRLF-*separated*, not terminated, so the
/// caller's cursor ends at the end of the last row (see `eraseRegion`).
pub fn renderItem(
    writer: anytype,
    first_line: *bool,
    style: ItemStyle,
    label: []const u8,
    avail: usize,
) !usize {
    const Ctx = struct {
        w: @TypeOf(writer),
        first_line: *bool,
        style: ItemStyle,
        seg: usize = 0,
        rows: usize = 0,

        fn emit(self: *@This(), line: []const u8) anyerror!void {
            if (!self.first_line.*) try self.w.writeAll("\r\n");
            self.first_line.* = false;
            try self.w.writeAll(self.style.line_open);
            if (self.seg == 0) {
                try self.w.writeAll(self.style.first_prefix);
            } else {
                try writePad(self.w, self.style.prefix_w);
            }
            try self.w.writeAll(line);
            try self.w.writeAll(self.style.line_close);
            self.seg += 1;
            self.rows += 1;
        }
    };
    var ctx = Ctx{ .w = writer, .first_line = first_line, .style = style };
    try terminal.wrapForEach(label, avail, &ctx, Ctx.emit);
    return ctx.rows;
}

pub fn writePad(writer: anytype, n: usize) !void {
    for (0..n) |_| try writer.writeAll(" ");
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

/// Erase the previously rendered region. The cursor is at the end of the last
/// row (rows are CRLF-separated, not terminated), so return to column 0, move up
/// to the first row, and clear to the end of the display.
pub fn eraseRegion(writer: anytype, rows: usize) !void {
    if (rows == 0) return;
    try writer.writeAll("\r");
    if (rows > 1) try writer.print("\x1b[{d}A", .{rows - 1});
    try writer.writeAll("\x1b[0J");
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

test "eraseRegion is a no-op for zero rows" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try eraseRegion(&w, 0);
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "renderItem hang-indents continuation lines under the label" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var first = true;
    // 4-column prefix; a label that must wrap at width 12 (avail 8).
    const rows = try renderItem(&w, &first, .{ .first_prefix = "  > ", .prefix_w = 4 }, "alpha bravo charlie", 8);
    try testing.expect(rows >= 2);
    // First line carries the prefix; a continuation line is padded to 4 spaces.
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "  > alpha") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\r\n    ") != null);
}

// ---------------------------------------------------------------------------
// Node builders for the ui-engine render path (ADR-0013 migration). The
// imperative renderItem/eraseRegion machinery above remains until the line
// prompts migrate too, then gets swept.
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
