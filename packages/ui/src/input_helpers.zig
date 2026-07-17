//! Private helpers shared by the input widgets. Not part of the public API.
//!
//! UTF-8 boundary helpers are used by both TextInput and TextArea.
//! Scroll/scrollbar helpers are used by both Select and Table.

const std = @import("std");
const theme_mod = @import("theme");
const terminal = @import("terminal");
const node_mod = @import("node.zig");
const surface_mod = @import("surface.zig");

const Node = node_mod.Node;
const Limits = node_mod.Limits;
const Size = node_mod.Size;
const RenderCtx = node_mod.RenderCtx;
const Style = surface_mod.Style;
const Region = surface_mod.Region;
const Theme = theme_mod.Theme;

// ============================================================================
// UTF-8 helpers (codepoint boundaries; editing is codepoint-granular)
// ============================================================================

pub fn prevBoundary(s: []const u8, i: usize) usize {
    var j = i;
    while (j > 0) {
        j -= 1;
        if (s[j] & 0xc0 != 0x80) break; // not a UTF-8 continuation byte
    }
    return j;
}

pub fn nextBoundary(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    return @min(i + n, s.len);
}

pub fn utf8Count(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) i = nextBoundary(s, i);
    return n;
}

/// The left edge of a horizontally scrolled field: the byte offset in `text` at
/// which the cumulative display width first reaches `target_col`, paired with the
/// actual column that offset lands on. Graphemes are never split, so when a
/// wide-cell grapheme straddles `target_col` the whole grapheme is stepped over
/// and `col` overshoots to the first column *past* it (`col >= target_col`).
/// Callers must anchor their caret math on `col`, not `target_col`, to stay
/// aligned with what is painted.
pub const ColumnStart = struct { byte: usize, col: u16 };

pub fn byteAtColumn(text: []const u8, target_col: u16) ColumnStart {
    var col: u16 = 0;
    var i: usize = 0;
    while (i < text.len and col < target_col) {
        const end = nextBoundary(text, i);
        col += @intCast(terminal.displayWidth(text[i..end]));
        i = end;
    }
    return .{ .byte = i, .col = col };
}

// ============================================================================
// Scroll helpers (shared by Select and Table)
// ============================================================================

/// Slide `scroll` the minimum needed to keep `hi` within a `visible`-row window
/// over `count` items — the single persistent-scroll rule, shared by every
/// single-line list widget (`Select`, `Table`). Both `handle` (to update state)
/// and `view` (to correct it) call it, so the window slides only when the
/// cursor crosses an edge and never drifts off the content.
pub fn scrollFor(scroll: usize, hi: usize, visible: u16, count: usize) usize {
    const v = @max(@as(usize, visible), 1);
    var s = @min(scroll, count -| v);
    if (hi < s) s = hi;
    if (hi >= s + v) s = hi - v + 1;
    return s;
}

/// Wrap a built list/grid `body` (whose rightmost column is the 1-cell gutter)
/// in a `custom` leaf that paints a proportional scrollbar down that gutter
/// (ADR-0021 incr5). The body is rendered first, then the thumb overpaints the
/// gutter column — so the scrollbar *replaces* the overflow arrows when a caller
/// opts in (the richer indicator in the same reserved column), rather than adding
/// a second gutter. `total`/`visible`/`scroll` are the same window facts `view`
/// already computed. Theme-derived: thumb = `surface.border`, track = `prompts.hint`.
pub fn scrollbarWrap(a: std.mem.Allocator, th: *const Theme, body: Node, total: usize, visible: usize, scroll: usize) !Node {
    const ctx = try a.create(ScrollbarWrap);
    ctx.* = .{
        .body = body,
        .total = total,
        .visible = visible,
        .scroll = scroll,
        .track = th.prompts.hint.resolve(th.palette),
        .thumb = th.surface.border.resolve(th.palette),
    };
    return .{ .kind = .{ .custom = .{
        .context = ctx,
        .measureFn = ScrollbarWrap.measureFn,
        .renderFn = ScrollbarWrap.renderFn,
    } } };
}

const ScrollbarWrap = struct {
    body: Node,
    total: usize,
    visible: usize,
    scroll: usize,
    track: Style,
    thumb: Style,

    fn measureFn(context: *anyopaque, rctx: *const RenderCtx, limits: Limits) Size {
        const self: *const ScrollbarWrap = @ptrCast(@alignCast(context));
        return node_mod.measure(rctx, &self.body, limits);
    }

    fn renderFn(context: *anyopaque, rctx: *const RenderCtx, region: Region) anyerror!void {
        const self: *const ScrollbarWrap = @ptrCast(@alignCast(context));
        try node_mod.render(rctx, &self.body, region);
        const w = region.width();
        const h = region.height();
        if (w == 0 or h == 0) return;
        region.sub(.{ .x = w - 1, .y = 0, .w = 1, .h = h })
            .paintScrollbar(self.total, self.visible, self.scroll, self.track, self.thumb);
    }
};
