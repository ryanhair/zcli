//! TextArea widget (ADR-0018): a multi-line text field.

const std = @import("std");
const theme_mod = @import("theme");
const terminal = @import("terminal");
const node_mod = @import("node.zig");
const surface_mod = @import("surface.zig");
const helpers = @import("input_helpers.zig");

const Node = node_mod.Node;
const Dim = node_mod.Dim;
const Limits = node_mod.Limits;
const Size = node_mod.Size;
const RenderCtx = node_mod.RenderCtx;
const Style = surface_mod.Style;
const Region = surface_mod.Region;
const Point = surface_mod.Point;
const Key = terminal.Key;
const Theme = theme_mod.Theme;

const prevBoundary = helpers.prevBoundary;
const nextBoundary = helpers.nextBoundary;
const scrollFor = helpers.scrollFor;

/// A multi-line text field over a caller-owned buffer (capacity is the caller's
/// choice — allocation-free), the multi-line counterpart to `TextInput`. Editing
/// is codepoint-granular over a buffer with embedded `\n`s (insert, backspace/
/// delete, ←/→ across newlines), sharing `TextInput`'s boundary/insert/delete
/// logic verbatim. The content soft-wraps at the granted width; ↑/↓ move by one
/// *visual* row, Home/End go to the current visual row's ends, Enter inserts a
/// newline (the multi-line distinction from `TextInput`, where Enter submits),
/// and PgUp/PgDn move by `height` visual rows. Vertical scroll keeps the caret
/// in view. The caret's `(visual_row, col)` and the scroll window are derived
/// from `cursor` (a byte offset) against the wrap each frame — the only
/// persistent state is the bytes, the cursor, and `scroll_row`.
pub const TextArea = struct {
    /// Caller-owned storage. `value()` is `buffer[0..len]`.
    buffer: []u8,
    len: usize = 0,
    /// Insertion point, a byte offset into `buffer` (always on a codepoint
    /// boundary) — the single source of truth. The `(row, col)` the arrows and
    /// paging operate on is derived from it against the wrap each frame.
    cursor: usize = 0,
    /// First visible visual row — persistent, kept in view by `handle`/`view`.
    scroll_row: u16 = 0,

    pub const ViewOpts = struct {
        focused: bool = false,
        /// Shown dimmed when the field is empty.
        placeholder: []const u8 = "",
        width: Dim = .{ .fill = 1 },
        /// Visible visual rows (the field's height).
        height: u16 = 6,
        theme: *const Theme = theme_mod.appTheme(),
        /// When set (and focused), the field reports its caret's absolute cell
        /// here during render and draws NO block cursor — the caller places the
        /// real terminal cursor there (`App.cursorAt`, ADR-0019), the identical
        /// channel `TextInput` uses. Left null, the field paints the reverse-video
        /// block caret as a fallback (a block caret reads poorly across wrapped
        /// lines, so a real hardware cursor is preferred).
        cursor_out: ?*?Point = null,
    };

    pub fn value(self: *const TextArea) []const u8 {
        return self.buffer[0..self.len];
    }

    /// Handle a key; returns whether it was consumed. `width` and `height` are
    /// the field's granted content width and visible-row count (what the caller
    /// passes to `view`), so vertical motion and paging resolve against the same
    /// wrap the render uses. Editing keys are always consumed (they belong to the
    /// field, even when they can't move); Tab/Shift-Tab/Esc bubble to navigation.
    pub fn handle(self: *TextArea, key: Key, width: u16, height: u16) bool {
        const w = @max(width, 1);
        switch (key) {
            .char => |c| self.insert(c),
            .enter => self.insertByte('\n'),
            .backspace => self.deleteBack(),
            .delete => self.deleteForward(),
            .left => self.cursor = prevBoundary(self.value(), self.cursor),
            .right => self.cursor = nextBoundary(self.value(), self.cursor),
            .up => self.moveVertical(w, -1),
            .down => self.moveVertical(w, 1),
            .home => self.cursor = rowBounds(self.value(), w, self.cursor).start,
            .end => self.cursor = rowBounds(self.value(), w, self.cursor).end,
            .pageup => self.moveVertical(w, -@as(i64, @max(height, 1))),
            .pagedown => self.moveVertical(w, @max(height, 1)),
            else => return false,
        }
        // Keep the caret in the visible window (the same `scrollFor` rule the list
        // widgets use, in visual rows). `view` re-derives it too, so a directly-set
        // cursor still shows, but maintaining it here keeps `scroll_row` truthful
        // between frames.
        const caret = caretRowCol(self.value(), w, self.cursor);
        const total = visualRowCount(self.value(), w);
        self.scroll_row = @intCast(scrollFor(self.scroll_row, caret.row, @max(height, 1), total));
        return true;
    }

    /// Move the caret `delta` visual rows (negative up), preserving the target
    /// column where possible. Target-column policy (see the ADR): a plain
    /// per-press clamp to the destination row's length, with NO sticky goal
    /// column — the cursor stays a byte offset and everything is re-derived from
    /// it each press, so successive ↑/↓ can drift left through a short row rather
    /// than remembering the original column. That is the simplest reading
    /// consistent with the ADR's "derive from the offset each frame" and avoids
    /// the extra state a sticky goal column would need.
    fn moveVertical(self: *TextArea, width: u16, delta: i64) void {
        const text = self.value();
        const cur = caretRowCol(text, width, self.cursor);
        const total = visualRowCount(text, width);
        const dest: usize = if (delta < 0)
            cur.row -| @as(usize, @intCast(-delta))
        else
            @min(cur.row + @as(usize, @intCast(delta)), total -| 1);
        self.cursor = offsetAtRowCol(text, width, dest, cur.col);
    }

    fn insert(self: *TextArea, cp: u21) void {
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &enc) catch return;
        self.insertBytes(enc[0..n]);
    }

    fn insertByte(self: *TextArea, b: u8) void {
        self.insertBytes(&[_]u8{b});
    }

    fn insertBytes(self: *TextArea, bytes: []const u8) void {
        const n = bytes.len;
        if (self.len + n > self.buffer.len) return; // full — drop the keystroke
        std.mem.copyBackwards(u8, self.buffer[self.cursor + n .. self.len + n], self.buffer[self.cursor..self.len]);
        @memcpy(self.buffer[self.cursor..][0..n], bytes);
        self.len += n;
        self.cursor += n;
    }

    fn deleteBack(self: *TextArea) void {
        if (self.cursor == 0) return;
        const start = prevBoundary(self.value(), self.cursor);
        const n = self.cursor - start;
        std.mem.copyForwards(u8, self.buffer[start .. self.len - n], self.buffer[self.cursor..self.len]);
        self.len -= n;
        self.cursor = start;
    }

    fn deleteForward(self: *TextArea) void {
        if (self.cursor >= self.len) return;
        const end = nextBoundary(self.value(), self.cursor);
        const n = end - self.cursor;
        std.mem.copyForwards(u8, self.buffer[self.cursor .. self.len - n], self.buffer[end..self.len]);
        self.len -= n;
    }

    pub fn view(self: *const TextArea, a: std.mem.Allocator, opts: ViewOpts) !Node {
        const th = opts.theme;
        const ctx = try a.create(AreaView);
        ctx.* = .{
            .text = self.value(),
            .cursor = self.cursor,
            .scroll_row = self.scroll_row,
            .height = @max(opts.height, 1),
            .focused = opts.focused,
            .placeholder = opts.placeholder,
            .hint_style = th.prompts.hint.resolve(th.palette),
            .caret_style = .{ .reverse = true },
            .cursor_out = opts.cursor_out,
        };
        return .{
            .width = opts.width,
            .kind = .{ .custom = .{
                .context = ctx,
                .measureFn = AreaView.measureFn,
                .renderFn = AreaView.renderFn,
            } },
        };
    }
};

/// The custom leaf behind `TextArea`. A `custom` leaf because soft wrap needs the
/// granted width (which the builder can't know) and the caret's absolute cell
/// must be reported for the hardware cursor. It wraps `text` at the granted width
/// (per `\n`-delimited paragraph), derives the caret's `(visual_row, col)` from
/// `cursor`, clamps `scroll_row` to keep the caret visible, and paints only the
/// visible window of visual rows.
const AreaView = struct {
    text: []const u8,
    cursor: usize,
    /// The caller's persistent scroll (first visible visual row). The renderer
    /// only clamps a *local* copy — persisting it back would need a mutable
    /// pointer; instead `TextArea.handle` maintains it and `view` corrects the
    /// window here so a directly-set cursor still shows.
    scroll_row: u16,
    height: u16,
    focused: bool,
    placeholder: []const u8,
    hint_style: Style,
    caret_style: Style,
    cursor_out: ?*?Point,

    fn measureFn(context: *anyopaque, _: *const RenderCtx, limits: Limits) Size {
        const self: *const AreaView = @ptrCast(@alignCast(context));
        const h = @min(@as(usize, self.height), @as(usize, limits.max_h));
        return .{ .w = limits.max_w, .h = @intCast(@max(h, @min(1, limits.max_h))) };
    }

    fn renderFn(context: *anyopaque, _: *const RenderCtx, region: Region) anyerror!void {
        const self: *const AreaView = @ptrCast(@alignCast(context));
        const w = region.width();
        if (w == 0) return;
        const rows_h = @min(self.height, region.height());
        if (rows_h == 0) return;

        // Empty buffer: the placeholder in hint style, caret at the origin.
        if (self.text.len == 0) {
            _ = try region.writeText(0, 0, self.placeholder, self.hint_style);
            if (self.focused) reportCaret(self, region, 0, 0, " ");
            return;
        }

        const caret = caretRowCol(self.text, w, self.cursor);
        const scroll = scrollFor(self.scroll_row, caret.row, rows_h, visualRowCount(self.text, w));

        // Paint the visible window of visual rows directly (the same "I already
        // know the visible slice" shape as `Select`'s wrap path).
        var painter = RowPainter{ .region = region, .from = @intCast(scroll), .rows_h = rows_h };
        rowForEach(self.text, w, &painter, RowPainter.add);

        if (!self.focused) return;
        // The caret's cell within the window; if it scrolled off (only possible
        // when the region is shorter than `height`), clamp to the last row.
        const vis_row: u16 = if (caret.row >= scroll) @intCast(@min(caret.row - scroll, rows_h - 1)) else 0;
        // The glyph under the caret — the byte at `cursor`, or a space when the
        // caret rests at the end of the row / on a `\n`. Only used for the block
        // fallback (so it reverses the real glyph, not a blank, matching TextInput).
        const glyph: []const u8 = if (self.cursor < self.text.len and self.text[self.cursor] != '\n')
            self.text[self.cursor..nextBoundary(self.text, self.cursor)]
        else
            " ";
        reportCaret(self, region, caret.col, vis_row, glyph);
    }

    fn reportCaret(self: *const AreaView, region: Region, col: u16, row: u16, glyph: []const u8) void {
        if (self.cursor_out) |out| {
            out.* = .{ .x = region.rect.x + col, .y = region.rect.y + row };
        } else {
            // Fallback block caret: reverse the glyph under the caret (a space past
            // the row's end) — no hardware cursor placed.
            _ = region.writeText(col, row, glyph, self.caret_style) catch {};
        }
    }
};

/// Paints the visual rows in `[from, from + rows_h)` into the region, one visual
/// row per region line starting at y=0.
const RowPainter = struct {
    region: Region,
    from: usize,
    rows_h: u16,
    idx: usize = 0,
    y: u16 = 0,

    fn add(self: *RowPainter, row: []const u8, _: usize, _: bool) anyerror!void {
        defer self.idx += 1;
        if (self.idx < self.from or self.y >= self.rows_h) return;
        _ = try self.region.writeText(0, self.y, row, .{});
        self.y += 1;
    }
};

// ---- Visual-row geometry (soft wrap, respecting hard `\n`s) -----------------
//
// A `TextArea`'s buffer is a sequence of `\n`-delimited paragraphs; each wraps to
// the granted width independently and the visual rows concatenate. These helpers
// walk that structure with no allocation via `wrapForEach` (the same grapheme/
// ANSI-aware machinery `Select`'s wrap path uses — no new wrap logic here), so
// `handle` (no allocator) and `view` share one source of truth. A visual row is
// the byte span `[start, end)` into the buffer; because `wrapForEach` drops the
// break space between two soft-wrapped rows, a cursor sitting on that dropped
// space is attributed to the row it precedes (`[row.start, next.start)`).

const RowColumn = struct { row: usize, col: u16 };

/// Invoke `emit(ctx, row_slice, start_offset, is_para_end)` for each visual row of
/// `text` at `width`, in order — the single wrap walk the geometry helpers below
/// share. Each `\n`-delimited paragraph wraps independently (respecting hard
/// newlines) and the rows concatenate; `start_offset` is the row's byte offset
/// into `text` (recovered from the slice `wrapForEach` returns, which points into
/// `text`). `is_para_end` marks the row that ends a paragraph. An empty paragraph
/// (a blank line, or the whole empty buffer) still emits one empty row.
fn rowForEach(
    text: []const u8,
    width: u16,
    context: anytype,
    comptime emit: fn (@TypeOf(context), []const u8, usize, bool) anyerror!void,
) void {
    const w = @max(@as(usize, width), 1);
    const base = @intFromPtr(text.ptr);
    var para_start: usize = 0;
    while (true) {
        const nl = std.mem.indexOfScalarPos(u8, text, para_start, '\n');
        const para_end = nl orelse text.len;
        const para = text[para_start..para_end];

        var visitor = RowVisitor(@TypeOf(context), emit){
            .ctx = context,
            .base = base,
            .para_start = para_start,
        };
        terminal.wrapForEach(para, w, &visitor, RowVisitor(@TypeOf(context), emit).onLine) catch {};
        visitor.flush();

        if (nl == null) break;
        para_start = para_end + 1;
    }
}

fn RowVisitor(comptime Ctx: type, comptime emit: fn (Ctx, []const u8, usize, bool) anyerror!void) type {
    return struct {
        ctx: Ctx,
        base: usize, // address of the full text's first byte
        para_start: usize, // byte offset of the paragraph in the full text
        pending: ?[]const u8 = null, // the previous line, emitted once we know if it's last

        const Self = @This();

        /// Buffer one line: we only know whether a line is the paragraph's last
        /// (its End reaches past the glyphs, over the dropped break / `\n`) once
        /// the next arrives or the paragraph flushes.
        fn onLine(self: *Self, line: []const u8) anyerror!void {
            if (self.pending) |p| try self.emitRow(p, false);
            self.pending = line;
        }

        fn flush(self: *Self) void {
            if (self.pending) |p| {
                self.emitRow(p, true) catch {};
                self.pending = null;
            }
        }

        fn emitRow(self: *Self, line: []const u8, para_end: bool) anyerror!void {
            // An empty line ("" — a blank paragraph) has no pointer into the text;
            // anchor it at the paragraph start. Otherwise recover its offset from
            // the slice, which points into `text`.
            const start = if (line.len == 0) self.para_start else @intFromPtr(line.ptr) - self.base;
            try emit(self.ctx, line, start, para_end);
        }
    };
}

/// The number of visual rows `text` wraps to at `width`.
fn visualRowCount(text: []const u8, width: u16) usize {
    const Counter = struct {
        n: usize = 0,
        fn add(self: *@This(), _: []const u8, _: usize, _: bool) anyerror!void {
            self.n += 1;
        }
    };
    var c = Counter{};
    rowForEach(text, width, &c, Counter.add);
    return @max(c.n, 1);
}

/// The caret's `(visual_row, col)` for byte offset `cursor` — the row whose span
/// `[start, next_start)` contains `cursor`, and the display width from that row's
/// start to `cursor`.
fn caretRowCol(text: []const u8, width: u16, cursor: usize) RowColumn {
    const Finder = struct {
        text: []const u8,
        cursor: usize,
        row: usize = 0,
        col: u16 = 0,
        idx: usize = 0,
        prev_start: usize = 0,
        found: bool = false,
        fn add(self: *@This(), _: []const u8, start: usize, _: bool) anyerror!void {
            defer self.idx += 1;
            if (self.found) return;
            // The cursor belongs to the last row whose start is <= cursor.
            if (start <= self.cursor) {
                self.row = self.idx;
                self.prev_start = start;
            } else {
                self.found = true;
            }
        }
    };
    var f = Finder{ .text = text, .cursor = cursor };
    rowForEach(text, width, &f, Finder.add);
    const col: u16 = @intCast(terminal.displayWidth(text[f.prev_start..@min(cursor, text.len)]));
    return .{ .row = f.row, .col = col };
}

/// The byte offset at visual `row`, `target_col` display columns in (clamped to
/// the row's length) — the destination for a vertical move.
fn offsetAtRowCol(text: []const u8, width: u16, row: usize, target_col: u16) usize {
    const Finder = struct {
        text: []const u8,
        want: usize,
        target: u16,
        idx: usize = 0,
        off: usize = 0,
        found: bool = false,
        fn add(self: *@This(), line: []const u8, start: usize, para_end: bool) anyerror!void {
            defer self.idx += 1;
            if (self.found) return;
            if (self.idx == self.want) {
                self.off = colToOffset(self.text, start, line, self.target, para_end);
                self.found = true;
            }
        }
    };
    var f = Finder{ .text = text, .want = row, .target = target_col };
    rowForEach(text, width, &f, Finder.add);
    return f.off;
}

/// The bounds `[start, end)` of the visual row containing `cursor` — Home/End
/// destinations. `end` is the offset past the last glyph of the row (before any
/// dropped break space / `\n`).
fn rowBounds(text: []const u8, width: u16, cursor: usize) struct { start: usize, end: usize } {
    const Finder = struct {
        text: []const u8,
        cursor: usize,
        start: usize = 0,
        end: usize = 0,
        found: bool = false,
        fn add(self: *@This(), line: []const u8, start: usize, _: bool) anyerror!void {
            if (self.found) return;
            if (start <= self.cursor) {
                self.start = start;
                self.end = start + line.len;
            } else {
                self.found = true;
            }
        }
    };
    var f = Finder{ .text = text, .cursor = cursor };
    rowForEach(text, width, &f, Finder.add);
    return .{ .start = f.start, .end = f.end };
}

/// The byte offset within `line` (which starts at `start` in the full text) whose
/// display width from the row start first reaches `target_col`, clamped to the
/// row's end. `para_end` rows are still clamped to the glyphs, not the `\n`.
fn colToOffset(text: []const u8, start: usize, line: []const u8, target_col: u16, para_end: bool) usize {
    _ = text;
    _ = para_end;
    var col: u16 = 0;
    var i: usize = 0;
    while (i < line.len and col < target_col) {
        const end = nextBoundary(line, i);
        col += @intCast(terminal.displayWidth(line[i..end]));
        i = end;
    }
    return start + i;
}
