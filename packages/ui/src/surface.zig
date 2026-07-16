//! Cell surface: the paint target for one live-region frame (ADR-0013).
//!
//! A `Surface` is a grid of styled grapheme cells plus an append-only byte
//! buffer that owns the grapheme text. Cells reference their grapheme by
//! offset into that buffer, so writes never allocate per-cell and the whole
//! surface resets between frames in O(1) (`clear`).
//!
//! All writing goes through a `Region` — a clipped rectangular view. Layout
//! hands each node a region of exactly the rect it was granted, which is what
//! makes "children stick to constraints" structural: writes outside the
//! region are dropped, not clamped into a sibling's cells.

const std = @import("std");
const Graphemes = @import("Graphemes");
const theme = @import("theme");

pub const Style = theme.Style;

pub const Cell = struct {
    text_off: u32 = 0,
    text_len: u8 = 0, // 0 = blank (renders as a styled space)
    width: u8 = 1, // display columns; 0 = continuation of the wide cell to the left
    style: Style = .{},

    pub const blank: Cell = .{};

    pub fn isBlank(self: Cell) bool {
        return self.text_len == 0 and self.width != 0;
    }

    pub fn isContinuation(self: Cell) bool {
        return self.width == 0;
    }
};

/// Style equality by value. `std.meta.eql` is wrong for `Style`: the `.hex`
/// color variant is a slice, which it compares by pointer — two equal hex
/// strings from different buffers would spuriously differ and force the diff
/// renderer to repaint. Colors here compare by content.
pub fn styleEql(a: Style, b: Style) bool {
    return colorEql(a.foreground, b.foreground) and
        colorEql(a.background, b.background) and
        a.bold == b.bold and
        a.dim == b.dim and
        a.italic == b.italic and
        a.underline == b.underline and
        a.strikethrough == b.strikethrough and
        a.reverse == b.reverse;
}

fn colorEql(a: ?theme.Color, b: ?theme.Color) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    const ca = a.?;
    const cb = b.?;
    if (std.meta.activeTag(ca) != std.meta.activeTag(cb)) return false;
    return switch (ca) {
        .indexed => |v| v == cb.indexed,
        .rgb => |v| v.r == cb.rgb.r and v.g == cb.rgb.g and v.b == cb.rgb.b,
        .hex => |v| std.mem.eql(u8, v, cb.hex),
        else => true,
    };
}

pub const Rect = struct { x: u16, y: u16, w: u16, h: u16 };
pub const Point = struct { x: u16, y: u16 };

pub const Surface = struct {
    allocator: std.mem.Allocator,
    width: u16,
    height: u16,
    cells: []Cell,
    bytes: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Surface {
        const cells = try allocator.alloc(Cell, @as(usize, width) * height);
        @memset(cells, Cell.blank);
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .cells = cells,
            .bytes = .empty,
        };
    }

    pub fn deinit(self: *Surface) void {
        self.allocator.free(self.cells);
        self.bytes.deinit(self.allocator);
    }

    /// Reset every cell to blank and drop all grapheme bytes (capacity kept).
    pub fn clear(self: *Surface) void {
        @memset(self.cells, Cell.blank);
        self.bytes.clearRetainingCapacity();
    }

    pub fn resize(self: *Surface, width: u16, height: u16) !void {
        const new_cells = try self.allocator.alloc(Cell, @as(usize, width) * height);
        self.allocator.free(self.cells);
        self.cells = new_cells;
        self.width = width;
        self.height = height;
        self.clear();
    }

    pub fn cell(self: *const Surface, x: u16, y: u16) Cell {
        std.debug.assert(x < self.width and y < self.height);
        return self.cells[self.idx(x, y)];
    }

    /// The grapheme bytes of `c` (empty slice for a blank cell).
    pub fn cellText(self: *const Surface, c: Cell) []const u8 {
        return self.bytes.items[c.text_off..][0..c.text_len];
    }

    /// The whole surface as a writable region.
    pub fn root(self: *Surface) Region {
        return .{
            .surface = self,
            .rect = .{ .x = 0, .y = 0, .w = self.width, .h = self.height },
        };
    }

    fn idx(self: *const Surface, x: u16, y: u16) usize {
        return @as(usize, y) * self.width + x;
    }

    /// Blank the cell at (x, y) with `style`, dissolving any wide grapheme it
    /// overlaps: overwriting either half destroys the other half too (kept
    /// blank in its own style), so a continuation cell can never be orphaned.
    fn blankAt(self: *Surface, x: u16, y: u16, style: Style) void {
        const i = self.idx(x, y);
        const old = self.cells[i];
        if (old.width == 0) {
            // Continuation: a head always sits immediately to its left.
            self.cells[i - 1] = .{ .style = self.cells[i - 1].style };
        } else if (old.width == 2) {
            self.cells[i + 1] = .{ .style = self.cells[i + 1].style };
        }
        self.cells[i] = .{ .style = style };
    }

    /// Place one grapheme at (x, y). Caller has already clipped: the grapheme
    /// fits entirely within the surface.
    fn put(self: *Surface, x: u16, y: u16, text: []const u8, w: u8, style: Style) !void {
        std.debug.assert(w == 1 or w == 2);
        std.debug.assert(x + w <= self.width and y < self.height);
        self.blankAt(x, y, style);
        if (w == 2) self.blankAt(x + 1, y, style);
        // A plain space IS a blank cell (blankAt above already styled it), and
        // a grapheme too long for text_len degrades to blank rather than tearing.
        if (text.len == 1 and text[0] == ' ') return;
        if (text.len > std.math.maxInt(u8)) return;
        const off: u32 = @intCast(self.bytes.items.len);
        try self.bytes.appendSlice(self.allocator, text);
        const i = self.idx(x, y);
        self.cells[i] = .{
            .text_off = off,
            .text_len = @intCast(text.len),
            .width = w,
            .style = style,
        };
        if (w == 2) self.cells[i + 1] = .{ .width = 0, .style = style };
    }

    /// Copy `src`'s cell verbatim into (x, y) — text, width, and style — re-
    /// appending its grapheme bytes into this surface's own store (a cell's
    /// `text_off` is relative to the surface that owns it). Sets the cell
    /// directly, without dissolving whatever it overwrites: the callers
    /// (a viewport blit into its own freshly-cleared rect) copy whole rows,
    /// so a wide grapheme is always overwritten as a head+continuation pair.
    fn putCell(self: *Surface, x: u16, y: u16, c: Cell, text: []const u8) !void {
        const i = self.idx(x, y);
        if (c.text_len == 0) {
            // Blank (width 1) or wide-continuation (width 0): no grapheme bytes.
            self.cells[i] = .{ .width = c.width, .style = c.style };
            return;
        }
        const off: u32 = @intCast(self.bytes.items.len);
        try self.bytes.appendSlice(self.allocator, text);
        self.cells[i] = .{ .text_off = off, .text_len = c.text_len, .width = c.width, .style = c.style };
    }
};

/// A clipped rectangular view of a surface. All coordinates on the API are
/// region-relative; the rect is absolute and pre-clipped to the surface.
pub const Region = struct {
    surface: *Surface,
    rect: Rect,

    pub fn width(self: Region) u16 {
        return self.rect.w;
    }

    pub fn height(self: Region) u16 {
        return self.rect.h;
    }

    /// A sub-view of this region; `rect` is relative to this region and is
    /// clipped against it, so the result can never write outside its parent.
    pub fn sub(self: Region, rect: Rect) Region {
        const base_x: u32 = self.rect.x;
        const base_y: u32 = self.rect.y;
        const x = @min(base_x + rect.x, base_x + self.rect.w);
        const y = @min(base_y + rect.y, base_y + self.rect.h);
        const end_x = @min(x + rect.w, base_x + self.rect.w);
        const end_y = @min(y + rect.h, base_y + self.rect.h);
        return .{
            .surface = self.surface,
            .rect = .{
                .x = @intCast(x),
                .y = @intCast(y),
                .w = @intCast(end_x - x),
                .h = @intCast(end_y - y),
            },
        };
    }

    /// Blank every cell in the region with `style` (a box painting its
    /// background). A wide grapheme straddling the region edge is dissolved.
    pub fn fill(self: Region, style: Style) void {
        var y: u16 = 0;
        while (y < self.rect.h) : (y += 1) {
            var x: u16 = 0;
            while (x < self.rect.w) : (x += 1) {
                self.surface.blankAt(self.rect.x + x, self.rect.y + y, style);
            }
        }
    }

    /// Copy `src`'s rows, starting at `src_y`, into this region — top-left
    /// aligned, one source column per region column. Cells are copied verbatim
    /// (text, width, style). This is the viewport's windowed blit: a child is
    /// rendered into a full-height scratch surface, then the visible slice is
    /// copied here (ADR-0017). Fewer available source rows than the region is
    /// tall leaves the remaining region rows untouched — so short content shows
    /// whatever sits beneath the viewport, consistent with the stack
    /// transparency model. `src` should be at least the region's width.
    pub fn copyRows(self: Region, src: *const Surface, src_y: u16) !void {
        const cols = @min(self.rect.w, src.width);
        var dy: u16 = 0;
        while (dy < self.rect.h) : (dy += 1) {
            const sy = src_y + dy;
            if (sy >= src.height) break;
            var x: u16 = 0;
            while (x < cols) : (x += 1) {
                const c = src.cell(x, sy);
                // A wide grapheme whose continuation falls outside the copied
                // columns would leave a torn head — a width-2 cell with no
                // continuation — which the diff renderer reads past. Dissolve it
                // to a styled blank instead of copying the head verbatim.
                if (c.width == 2 and x + 1 >= cols) {
                    self.surface.blankAt(self.rect.x + x, self.rect.y + dy, c.style);
                } else {
                    try self.surface.putCell(self.rect.x + x, self.rect.y + dy, c, src.cellText(c));
                }
            }
        }
    }

    /// Write a single-line run of styled text starting at (x, y), returning
    /// the number of columns advanced. Clips at the region's right edge; a
    /// wide grapheme that would straddle the edge is dropped. Control bytes
    /// and ANSI escapes are zero width and skipped — styling is structured
    /// (`style`), never embedded escapes — matching how `terminal.wrap`
    /// measures, so layout and paint always agree on width.
    pub fn writeText(self: Region, x: u16, y: u16, text: []const u8, style: Style) !u16 {
        if (y >= self.rect.h or x >= self.rect.w) return 0;
        const abs_y = self.rect.y + y;
        const start: u32 = @as(u32, self.rect.x) + x;
        const right: u32 = @as(u32, self.rect.x) + self.rect.w;
        var col: u32 = start;

        var skip_until: usize = 0;
        var it = Graphemes.iterator(text);
        while (it.next()) |g| {
            if (col >= right) break;
            if (g.offset < skip_until) continue;
            if (text[g.offset] == 0x1b) {
                skip_until = escapeSeqEnd(text, g.offset);
                continue;
            }
            if (text[g.offset] < 0x20 or text[g.offset] == 0x7f) continue;
            const gw = g.displayWidth(text);
            if (gw <= 0) continue;
            const w: u8 = @intCast(@min(gw, 2));
            if (col + w > right) break;
            try self.surface.put(@intCast(col), abs_y, text[g.offset..][0..g.len], w, style);
            col += w;
        }
        return @intCast(col - start);
    }

    /// Paint a vertical scrollbar down this region's full height (ADR-0021 incr5):
    /// a `track` cell in `track_style` on every row, over which a proportional
    /// `thumb` band is drawn in `thumb_style`. The thumb's length and position
    /// come from `scrollThumb` — length ∝ visible/total (min 1), position ∝
    /// scroll/(total − visible). This is the opt-in scroll indicator behind the
    /// `scrollbar` opt on `viewport`/`Select`/`Table`; each reserves a 1-cell
    /// gutter and hands it here. The region should be 1 cell wide.
    pub fn paintScrollbar(
        self: Region,
        total: usize,
        visible: usize,
        scroll: usize,
        track_style: Style,
        thumb_style: Style,
    ) void {
        const h = self.rect.h;
        if (h == 0 or self.rect.w == 0) return;
        const bar = scrollThumb(total, visible, scroll, h);
        var y: u16 = 0;
        while (y < h) : (y += 1) {
            const on_thumb = y >= bar.start and y < bar.start + bar.len;
            _ = self.writeText(0, y, "│", if (on_thumb) thumb_style else track_style) catch {};
        }
    }
};

/// The scrollbar thumb geometry: its `start` row and `len` in a gutter of height
/// `h`, for a window of `visible` rows over `total` content rows at offset
/// `scroll`. A pure function (no I/O), unit-tested directly for the edge cases.
///
/// - No overflow (`total <= visible`): a full-length thumb (`start=0, len=h`) —
///   the least-noisy reading of "everything is in view" for an explicit column.
/// - Length ∝ `visible/total`, at least 1 cell, never past `h`.
/// - Position ∝ `scroll/(total − visible)`, so the thumb touches the top exactly
///   at `scroll=0` and the bottom exactly at the max scroll (`total − visible`).
pub const Thumb = struct { start: u16, len: u16 };

pub fn scrollThumb(total: usize, visible: usize, scroll: usize, h: u16) Thumb {
    if (h == 0) return .{ .start = 0, .len = 0 };
    // Nothing to scroll: the thumb fills the whole track.
    if (total <= visible or visible == 0) return .{ .start = 0, .len = h };

    // Thumb length ∝ visible/total, rounded, clamped to [1, h].
    const raw_len = (@as(usize, h) * visible + total / 2) / total;
    const len: u16 = @intCast(std.math.clamp(raw_len, 1, h));

    // Thumb travel is the rows the thumb can slide over; distribute `scroll` over
    // `total − visible` across it, rounding, so start=0 at scroll=0 and
    // start=travel at max scroll (both extremes touch exactly).
    const travel: usize = h - len;
    const max_scroll = total - visible;
    const s = @min(scroll, max_scroll);
    const start: u16 = if (travel == 0) 0 else @intCast((travel * s + max_scroll / 2) / max_scroll);
    return .{ .start = start, .len = len };
}

/// Index just past the ANSI escape sequence starting at `text[i]` (an ESC the
/// caller already saw). Same recognizer as `terminal.wrap`: CSI, OSC (BEL/ST
/// terminated), and two-byte `ESC x` forms; a truncated sequence consumes to
/// end of string.
fn escapeSeqEnd(text: []const u8, i: usize) usize {
    if (i + 1 >= text.len) return i + 1;
    switch (text[i + 1]) {
        '[' => {
            var j = i + 2;
            while (j < text.len) : (j += 1) {
                if (text[j] >= 0x40 and text[j] <= 0x7e) return j + 1;
            }
            return text.len;
        },
        ']' => {
            var j = i + 2;
            while (j < text.len) : (j += 1) {
                if (text[j] == 0x07) return j + 1;
                if (text[j] == 0x1b and j + 1 < text.len and text[j + 1] == '\\') return j + 2;
            }
            return text.len;
        },
        else => return i + 2,
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "writeText places cells and reports columns" {
    var s = try Surface.init(testing.allocator, 10, 2);
    defer s.deinit();

    const cols = try s.root().writeText(1, 0, "hi", .{ .bold = true });
    try testing.expectEqual(@as(u16, 2), cols);
    try testing.expect(s.cell(0, 0).isBlank());
    try testing.expectEqualStrings("h", s.cellText(s.cell(1, 0)));
    try testing.expectEqualStrings("i", s.cellText(s.cell(2, 0)));
    try testing.expect(s.cell(1, 0).style.bold);
}

test "writeText normalizes a space to a styled blank cell" {
    var s = try Surface.init(testing.allocator, 10, 1);
    defer s.deinit();

    _ = try s.root().writeText(0, 0, "a b", .{ .underline = true });
    const gap = s.cell(1, 0);
    try testing.expect(gap.isBlank());
    try testing.expect(gap.style.underline);
}

test "writeText clips at the region right edge" {
    var s = try Surface.init(testing.allocator, 10, 1);
    defer s.deinit();

    const region = s.root().sub(.{ .x = 0, .y = 0, .w = 4, .h = 1 });
    const cols = try region.writeText(0, 0, "abcdef", .{});
    try testing.expectEqual(@as(u16, 4), cols);
    try testing.expectEqualStrings("d", s.cellText(s.cell(3, 0)));
    try testing.expect(s.cell(4, 0).isBlank());
}

test "wide grapheme occupies head plus continuation" {
    var s = try Surface.init(testing.allocator, 10, 1);
    defer s.deinit();

    const cols = try s.root().writeText(0, 0, "你a", .{});
    try testing.expectEqual(@as(u16, 3), cols);
    try testing.expectEqual(@as(u8, 2), s.cell(0, 0).width);
    try testing.expect(s.cell(1, 0).isContinuation());
    try testing.expectEqualStrings("a", s.cellText(s.cell(2, 0)));
}

test "wide grapheme that would straddle the edge is dropped" {
    var s = try Surface.init(testing.allocator, 3, 1);
    defer s.deinit();

    // "你" fits (cols 0-1); "好" would straddle the edge at col 2 → dropped.
    const cols = try s.root().writeText(0, 0, "你好", .{});
    try testing.expectEqual(@as(u16, 2), cols);
    try testing.expect(s.cell(2, 0).isBlank());
}

test "overwriting either half of a wide grapheme dissolves it" {
    var s = try Surface.init(testing.allocator, 10, 1);
    defer s.deinit();

    _ = try s.root().writeText(0, 0, "你", .{});
    _ = try s.root().writeText(1, 0, "x", .{});
    try testing.expect(s.cell(0, 0).isBlank());
    try testing.expectEqualStrings("x", s.cellText(s.cell(1, 0)));

    _ = try s.root().writeText(2, 0, "好", .{});
    _ = try s.root().writeText(2, 0, "y", .{});
    try testing.expectEqualStrings("y", s.cellText(s.cell(2, 0)));
    try testing.expect(s.cell(3, 0).isBlank());
}

test "writeText skips ANSI escapes and control bytes" {
    var s = try Surface.init(testing.allocator, 10, 1);
    defer s.deinit();

    const cols = try s.root().writeText(0, 0, "\x1b[31ma\tb\x1b]0;t\x07c", .{});
    try testing.expectEqual(@as(u16, 3), cols);
    try testing.expectEqualStrings("a", s.cellText(s.cell(0, 0)));
    try testing.expectEqualStrings("b", s.cellText(s.cell(1, 0)));
    try testing.expectEqualStrings("c", s.cellText(s.cell(2, 0)));
}

test "sub regions clip against their parent" {
    var s = try Surface.init(testing.allocator, 10, 4);
    defer s.deinit();

    const outer = s.root().sub(.{ .x = 2, .y = 1, .w = 5, .h = 2 });
    try testing.expectEqual(@as(u16, 5), outer.width());

    // Inner rect extends past the parent on both axes → clipped.
    const inner = outer.sub(.{ .x = 3, .y = 1, .w = 10, .h = 10 });
    try testing.expectEqual(@as(u16, 2), inner.width());
    try testing.expectEqual(@as(u16, 1), inner.height());

    _ = try inner.writeText(0, 0, "abcdef", .{});
    // Inner origin is absolute (5, 2); only 2 columns fit.
    try testing.expectEqualStrings("a", s.cellText(s.cell(5, 2)));
    try testing.expectEqualStrings("b", s.cellText(s.cell(6, 2)));
    try testing.expect(s.cell(7, 2).isBlank());
}

test "writes outside the region are dropped entirely" {
    var s = try Surface.init(testing.allocator, 10, 2);
    defer s.deinit();

    const region = s.root().sub(.{ .x = 0, .y = 0, .w = 4, .h = 1 });
    try testing.expectEqual(@as(u16, 0), try region.writeText(4, 0, "x", .{}));
    try testing.expectEqual(@as(u16, 0), try region.writeText(0, 1, "x", .{}));
    for (s.cells) |c| try testing.expect(c.isBlank());
}

test "fill styles every cell in the region" {
    var s = try Surface.init(testing.allocator, 4, 2);
    defer s.deinit();

    _ = try s.root().writeText(0, 0, "abcd", .{});
    const region = s.root().sub(.{ .x = 1, .y = 0, .w = 2, .h = 2 });
    region.fill(.{ .reverse = true });

    try testing.expectEqualStrings("a", s.cellText(s.cell(0, 0)));
    try testing.expect(s.cell(1, 0).isBlank());
    try testing.expect(s.cell(1, 0).style.reverse);
    try testing.expect(s.cell(2, 1).style.reverse);
    try testing.expect(!s.cell(3, 0).style.reverse);
    try testing.expectEqualStrings("d", s.cellText(s.cell(3, 0)));
}

test "clear resets cells and byte storage" {
    var s = try Surface.init(testing.allocator, 4, 1);
    defer s.deinit();

    _ = try s.root().writeText(0, 0, "abcd", .{});
    try testing.expect(s.bytes.items.len > 0);
    s.clear();
    try testing.expectEqual(@as(usize, 0), s.bytes.items.len);
    for (s.cells) |c| try testing.expect(c.isBlank());
}

test "copyRows blanks a wide grapheme torn by the clip boundary" {
    // Source: "你" occupies cols 0-1 (head + continuation).
    var src = try Surface.init(testing.allocator, 4, 1);
    defer src.deinit();
    _ = try src.root().writeText(0, 0, "你a", .{});
    try testing.expectEqual(@as(u8, 2), src.cell(0, 0).width);

    // Copy into a 1-wide region: only col 0 (the wide head) fits, so its
    // continuation is clipped off. The head must dissolve to a blank rather
    // than land as a torn width-2 cell.
    var dst = try Surface.init(testing.allocator, 1, 1);
    defer dst.deinit();
    try dst.root().copyRows(&src, 0);

    try testing.expect(dst.cell(0, 0).isBlank());
    try testing.expectEqual(@as(u8, 1), dst.cell(0, 0).width);
}

test "copyRows preserves a wide grapheme that fits within the clip" {
    var src = try Surface.init(testing.allocator, 4, 1);
    defer src.deinit();
    _ = try src.root().writeText(0, 0, "你a", .{});

    // 2-wide region: the wide grapheme fits whole (head + continuation).
    var dst = try Surface.init(testing.allocator, 2, 1);
    defer dst.deinit();
    try dst.root().copyRows(&src, 0);

    try testing.expectEqual(@as(u8, 2), dst.cell(0, 0).width);
    try testing.expect(dst.cell(1, 0).isContinuation());
    try testing.expectEqualStrings("你", dst.cellText(dst.cell(0, 0)));
}

test "styleEql compares hex colors by content" {
    var buf_a = "#FF8040".*;
    var buf_b = "#FF8040".*;
    const a = Style{ .foreground = .{ .hex = &buf_a } };
    const b = Style{ .foreground = .{ .hex = &buf_b } };
    try testing.expect(styleEql(a, b));
    try testing.expect(!styleEql(a, .{}));
    try testing.expect(styleEql(.{}, .{}));
}

// ---- scrollThumb (ADR-0021 incr5) ------------------------------------------

test "scrollThumb: no overflow fills the whole track" {
    // total <= visible → a full-length thumb (nothing to scroll).
    try testing.expectEqual(Thumb{ .start = 0, .len = 10 }, scrollThumb(5, 10, 0, 10));
    try testing.expectEqual(Thumb{ .start = 0, .len = 10 }, scrollThumb(10, 10, 0, 10));
    // visible == 0 degenerates to the same full-track reading.
    try testing.expectEqual(Thumb{ .start = 0, .len = 10 }, scrollThumb(100, 0, 0, 10));
}

test "scrollThumb: length is proportional to visible/total, at least 1" {
    // 10 visible of 100 over a 10-row gutter → 1-cell thumb.
    try testing.expectEqual(@as(u16, 1), scrollThumb(100, 10, 0, 10).len);
    // 50 visible of 100 → half the gutter.
    try testing.expectEqual(@as(u16, 5), scrollThumb(100, 50, 0, 10).len);
    // A tiny window over huge content never rounds to 0 — the min-1 floor holds.
    try testing.expectEqual(@as(u16, 1), scrollThumb(10000, 1, 0, 10).len);
}

test "scrollThumb: touches the top at scroll 0 and the bottom at max scroll" {
    // 20 rows, 5 visible, gutter 10 → len 3 (round(10*5/20)=2.5→3), travel 7.
    const at_top = scrollThumb(20, 5, 0, 10);
    try testing.expectEqual(@as(u16, 0), at_top.start); // top exactly
    const max_scroll = 20 - 5;
    const at_bottom = scrollThumb(20, 5, max_scroll, 10);
    try testing.expectEqual(@as(u16, 10), at_bottom.start + at_bottom.len); // bottom exactly
    // Overshooting max scroll clamps to the same bottom-touching position.
    const over = scrollThumb(20, 5, 999, 10);
    try testing.expectEqual(@as(u16, 10), over.start + over.len);
}

test "scrollThumb: tiny gutters stay in bounds" {
    // h = 1: the thumb is the whole single cell at both extremes.
    try testing.expectEqual(Thumb{ .start = 0, .len = 1 }, scrollThumb(100, 10, 0, 1));
    try testing.expectEqual(Thumb{ .start = 0, .len = 1 }, scrollThumb(100, 10, 90, 1));
    // h = 2: a 1-cell thumb slides from the top row to the bottom row.
    try testing.expectEqual(Thumb{ .start = 0, .len = 1 }, scrollThumb(100, 10, 0, 2));
    try testing.expectEqual(Thumb{ .start = 1, .len = 1 }, scrollThumb(100, 10, 90, 2));
    // h = 0 is degenerate: no thumb.
    try testing.expectEqual(Thumb{ .start = 0, .len = 0 }, scrollThumb(100, 10, 0, 0));
}

test "scrollThumb: position advances monotonically with scroll" {
    // As scroll grows, the thumb start never moves backward and stays in bounds.
    var prev: u16 = 0;
    var sc: usize = 0;
    while (sc <= 95) : (sc += 1) {
        const t = scrollThumb(100, 5, sc, 10);
        try testing.expect(t.start >= prev);
        try testing.expect(t.start + t.len <= 10);
        prev = t.start;
    }
}

test "paintScrollbar draws a track with a proportional thumb band" {
    var s = try Surface.init(testing.allocator, 1, 10);
    defer s.deinit();
    // 20 rows, 5 visible, at the top: len 3, start 0 (see scrollThumb test).
    s.root().paintScrollbar(20, 5, 0, .{ .dim = true }, .{ .bold = true });
    // Thumb rows 0-2 are bold; track rows below are dim.
    try testing.expect(s.cell(0, 0).style.bold);
    try testing.expect(s.cell(0, 2).style.bold);
    try testing.expect(s.cell(0, 3).style.dim);
    try testing.expect(!s.cell(0, 3).style.bold);
    try testing.expect(s.cell(0, 9).style.dim);
}
