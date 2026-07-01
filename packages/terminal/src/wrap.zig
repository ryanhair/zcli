//! Display-width measurement and word-wrapping for terminal rendering.
//!
//! Width is grapheme-cluster aware (via zg's Graphemes/DisplayWidth data), so
//! CJK, emoji (including ZWJ sequences, flags, and skin-tone modifiers), and
//! combining marks all measure to their true column count. ANSI SGR/CSI/OSC
//! escape sequences are treated as zero width so colored strings measure by
//! what's actually painted.
//!
//! `wrapToWidth` breaks text at spaces where it can and hard-breaks words with
//! no break opportunity. It returns slices into the original `text` (the spaces
//! it breaks at are dropped from the output), so the caller can prepend its own
//! per-line prefix — this is what lets a prompt hang-indent continuation lines
//! past the left bullet.

const std = @import("std");
const Graphemes = @import("Graphemes");

/// Index just past the ANSI escape sequence that starts at `text[i]` (which the
/// caller has already confirmed is ESC, 0x1b). Handles CSI (`ESC [ … final`),
/// OSC (`ESC ] … BEL`/`ST`), and the two-byte `ESC x` forms; a truncated
/// sequence consumes to end of string.
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
                if (text[j] == 0x07) return j + 1; // BEL terminator
                if (text[j] == 0x1b and j + 1 < text.len and text[j + 1] == '\\') return j + 2; // ST
            }
            return text.len;
        },
        else => return i + 2,
    }
}

/// Display width of a grapheme, clamped to a non-negative column count
/// (zg returns -1 for BACKSPACE/DEL, 0 for control codes).
fn graphemeCols(g: Graphemes.Grapheme, text: []const u8) usize {
    const w = g.displayWidth(text);
    return if (w > 0) @intCast(w) else 0;
}

/// Total display width of `text` in terminal cells, grapheme-aware and skipping
/// ANSI escape sequences.
pub fn displayWidth(text: []const u8) usize {
    var total: usize = 0;
    var skip_until: usize = 0;
    var it = Graphemes.iterator(text);
    while (it.next()) |g| {
        if (g.offset < skip_until) continue;
        if (text[g.offset] == 0x1b) {
            skip_until = escapeSeqEnd(text, g.offset);
            continue;
        }
        total += graphemeCols(g, text);
    }
    return total;
}

fn isBreakSpace(text: []const u8, g: Graphemes.Grapheme) bool {
    return g.len == 1 and (text[g.offset] == ' ' or text[g.offset] == '\t');
}

/// Streaming greedy word-wrapper. Walks `text` once, with no allocation, and
/// calls `emitLine(context, line)` for each wrapped line — a slice into `text`.
/// Words are broken at spaces where possible (the break space is dropped) and
/// any word longer than `width` is hard-broken at grapheme boundaries. ANSI
/// escapes are zero width. `width` clamps to at least 1; empty (or all-space)
/// input emits one empty line. This is the primitive behind `wrapToWidth`,
/// `wrapCount`, and the prompt renderers.
pub fn wrapForEach(
    text: []const u8,
    width: usize,
    context: anytype,
    comptime emitLine: fn (@TypeOf(context), []const u8) anyerror!void,
) anyerror!void {
    const W = Wrapper(@TypeOf(context), emitLine);
    var w = W{ .text = text, .avail = @max(width, 1), .ctx = context };

    var word_start: ?usize = null;
    var word_end: usize = 0;
    var word_w: usize = 0;
    var gap_w: usize = 0;

    var skip_until: usize = 0;
    var it = Graphemes.iterator(text);
    while (it.next()) |g| {
        if (g.offset < skip_until) continue;
        if (text[g.offset] == 0x1b) {
            skip_until = escapeSeqEnd(text, g.offset);
            continue;
        }
        const gw = graphemeCols(g, text);
        if (isBreakSpace(text, g)) {
            if (word_start) |ws| {
                try w.place(ws, word_end, word_w, gap_w);
                word_start = null;
                word_w = 0;
                gap_w = 0;
            }
            gap_w += gw;
        } else {
            if (word_start == null) word_start = g.offset;
            word_w += gw;
            word_end = g.offset + g.len;
        }
    }
    if (word_start) |ws| try w.place(ws, word_end, word_w, gap_w);

    if (w.line_w > 0) {
        try w.emit(text[w.line_start..w.committed_end]);
    } else if (!w.produced) {
        try w.emit(text[0..0]);
    }
}

fn Wrapper(comptime Ctx: type, comptime emitLine: fn (Ctx, []const u8) anyerror!void) type {
    return struct {
        text: []const u8,
        avail: usize,
        ctx: Ctx,
        line_start: usize = 0,
        line_w: usize = 0,
        committed_end: usize = 0,
        produced: bool = false,

        const Self = @This();

        fn emit(self: *Self, line: []const u8) anyerror!void {
            self.produced = true;
            try emitLine(self.ctx, line);
        }

        /// Start a fresh line with a word, hard-breaking it if it alone exceeds
        /// the width. Full-width chunks are emitted; the trailing chunk becomes
        /// the current line so a following word can still share it.
        fn placeFresh(self: *Self, w_start: usize, w_end: usize, w_width: usize) anyerror!void {
            if (w_width <= self.avail) {
                self.line_start = w_start;
                self.line_w = w_width;
                self.committed_end = w_end;
                return;
            }
            const sub = self.text[w_start..w_end];
            var seg_start = w_start;
            var seg_w: usize = 0;
            var git = Graphemes.iterator(sub);
            while (git.next()) |g| {
                const gw = graphemeCols(g, sub);
                if (seg_w > 0 and seg_w + gw > self.avail) {
                    try self.emit(self.text[seg_start .. w_start + g.offset]);
                    seg_start = w_start + g.offset;
                    seg_w = gw;
                } else {
                    seg_w += gw;
                }
            }
            self.line_start = seg_start;
            self.line_w = seg_w;
            self.committed_end = w_end;
        }

        /// Place a completed word (preceded by `gap` columns of spaces) onto the
        /// current line, wrapping to a new line if it doesn't fit.
        fn place(self: *Self, w_start: usize, w_end: usize, w_width: usize, gap: usize) anyerror!void {
            if (self.line_w == 0) {
                try self.placeFresh(w_start, w_end, w_width);
            } else if (self.line_w + gap + w_width <= self.avail) {
                self.line_w += gap + w_width;
                self.committed_end = w_end;
            } else {
                try self.emit(self.text[self.line_start..self.committed_end]);
                self.line_w = 0;
                try self.placeFresh(w_start, w_end, w_width);
            }
        }
    };
}

/// Number of lines `text` wraps to at `width` display columns (no allocation).
pub fn wrapCount(text: []const u8, width: usize) usize {
    const Counter = struct {
        n: usize = 0,
        fn add(self: *@This(), _: []const u8) anyerror!void {
            self.n += 1;
        }
    };
    var c = Counter{};
    wrapForEach(text, width, &c, Counter.add) catch {};
    return c.n;
}

/// Break `text` into lines that each fit within `width` display columns,
/// collecting them into an allocated list. Wraps at spaces where possible and
/// hard-breaks over-long words; the break spaces are dropped. `width` clamps to
/// at least 1; empty input yields a single empty segment.
///
/// The returned outer slice is owned by the caller (`allocator.free`); the
/// element slices point into `text` and must not be freed. Prefer `wrapForEach`
/// or `wrapCount` in hot paths — this exists for callers that want the list.
pub fn wrapToWidth(allocator: std.mem.Allocator, text: []const u8, width: usize) ![][]const u8 {
    const Collector = struct {
        list: *std.ArrayList([]const u8),
        allocator: std.mem.Allocator,
        fn add(self: *@This(), line: []const u8) anyerror!void {
            try self.list.append(self.allocator, line);
        }
    };
    var list = std.ArrayList([]const u8).empty;
    errdefer list.deinit(allocator);
    var c = Collector{ .list = &list, .allocator = allocator };
    try wrapForEach(text, width, &c, Collector.add);
    return list.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "displayWidth: ascii" {
    try testing.expectEqual(@as(usize, 5), displayWidth("hello"));
    try testing.expectEqual(@as(usize, 0), displayWidth(""));
}

test "displayWidth: wide CJK counts 2 cells each" {
    try testing.expectEqual(@as(usize, 4), displayWidth("你好"));
}

test "displayWidth: emoji and combining marks" {
    try testing.expectEqual(@as(usize, 2), displayWidth("😊"));
    // 'e' + combining acute accent = one grapheme, one column.
    try testing.expectEqual(@as(usize, 1), displayWidth("\u{0065}\u{0301}"));
    // Flag = one grapheme, two columns.
    try testing.expectEqual(@as(usize, 2), displayWidth("🇪🇸"));
}

test "displayWidth: skips ANSI escapes" {
    // Without skipping, zg would count the '[36m' bytes → 6.
    try testing.expectEqual(@as(usize, 2), displayWidth("\x1b[36mhi\x1b[0m"));
}

fn expectWrap(text: []const u8, width: usize, expected: []const []const u8) !void {
    const segs = try wrapToWidth(testing.allocator, text, width);
    defer testing.allocator.free(segs);
    try testing.expectEqual(expected.len, segs.len);
    for (expected, segs) |e, s| try testing.expectEqualStrings(e, s);
}

test "wrapToWidth: fits on one line" {
    try expectWrap("hello world", 20, &.{"hello world"});
}

test "wrapToWidth: breaks at word boundary, dropping the break space" {
    try expectWrap("hello world", 7, &.{ "hello", "world" });
}

test "wrapToWidth: packs greedily" {
    try expectWrap("aa bb cc dd", 5, &.{ "aa bb", "cc dd" });
}

test "wrapToWidth: hard-breaks a word with no break opportunity" {
    try expectWrap("abcdefghij", 4, &.{ "abcd", "efgh", "ij" });
}

test "wrapToWidth: hard-break tail can share a line with the next word" {
    // "abcdef" hard-breaks to "abcd"/"ef"; "gh" then fits after "ef" (ef gh = 5).
    try expectWrap("abcdef gh", 4, &.{ "abcd", "ef", "gh" });
}

test "wrapToWidth: empty input yields one empty segment" {
    try expectWrap("", 10, &.{""});
    try expectWrap("   ", 10, &.{""});
}

test "wrapToWidth: width clamps to at least 1" {
    try expectWrap("ab", 0, &.{ "a", "b" });
}

test "wrapToWidth: wide grapheme respected across the boundary" {
    // Each CJH char is 2 cols; width 3 fits one per line (2 + 2 > 3).
    try expectWrap("你好", 3, &.{ "你", "好" });
}

test "wrapCount matches wrapToWidth length" {
    const cases = [_]struct { text: []const u8, width: usize }{
        .{ .text = "hello world", .width = 20 },
        .{ .text = "hello world", .width = 7 },
        .{ .text = "abcdefghij", .width = 4 },
        .{ .text = "", .width = 10 },
        .{ .text = "   ", .width = 10 },
        .{ .text = "你好世界 wide", .width = 5 },
    };
    for (cases) |c| {
        const segs = try wrapToWidth(testing.allocator, c.text, c.width);
        defer testing.allocator.free(segs);
        try testing.expectEqual(segs.len, wrapCount(c.text, c.width));
    }
}

test "wrapForEach emits slices into the original text" {
    const Ctx = struct {
        seen: usize = 0,
        fn add(self: *@This(), _: []const u8) anyerror!void {
            self.seen += 1;
        }
    };
    var ctx = Ctx{};
    try wrapForEach("one two three", 7, &ctx, Ctx.add);
    try testing.expect(ctx.seen >= 2);
}
