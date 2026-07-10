//! Focusable input widgets (ADR-0018): the interactive counterpart to the
//! progress widgets in `widgets.zig`. Each widget is a plain struct the caller
//! embeds in its own state — the immediate-mode contract holds:
//!
//!   - `view(self, a, opts) !Node`  — render from current state (opts carries
//!     `focused`); the caret/highlight is a styled cell, no hardware cursor.
//!   - `handle(self, key) bool`      — mutate on a key; returns whether it was
//!     consumed. A widget eats the keys it uses (a text field eats ←/→/char);
//!     everything else bubbles, so the form treats *unconsumed* keys as
//!     navigation (Tab/Enter/Escape). That one bool is the whole routing model.
//!
//! Focus itself is caller-owned (an index or an enum); the loop routes an event
//! to the focused widget, and on an unconsumed key does form-level navigation.
//! `focusNext`/`focusPrev` are the only helpers the library adds. No retained
//! widget tree, no IDs, no framework loop.
//!
//! Styling flows through the theme's prompt tokens (`PromptTheme`: cursor,
//! selected, marker, hint) — the same tokens the `prompts` package uses, so the
//! full-screen widgets and the line-oriented prompts share one look. The
//! `theme` option defaults to the app theme (root `zcli_theme`, ADR-0020), so
//! a custom theme flows in with no per-call threading.

const std = @import("std");
const theme_mod = @import("theme");
const terminal = @import("terminal");
const node_mod = @import("node.zig");
const surface_mod = @import("surface.zig");

const Node = node_mod.Node;
const Dim = node_mod.Dim;
const Limits = node_mod.Limits;
const Size = node_mod.Size;
const RenderCtx = node_mod.RenderCtx;
const Region = surface_mod.Region;
const Style = surface_mod.Style;
const Point = surface_mod.Point;
const Key = terminal.Key;

pub const Theme = theme_mod.Theme;

// ============================================================================
// Focus helpers
// ============================================================================

/// The next focus target with wrap-around (Tab). `E` is the app's focus enum
/// whose variants are its focusable fields, in order.
pub fn focusNext(comptime E: type, current: E) E {
    const n = @typeInfo(E).@"enum".fields.len;
    return @enumFromInt((@intFromEnum(current) + 1) % n);
}

/// The previous focus target with wrap-around (Shift-Tab / `.back_tab`).
pub fn focusPrev(comptime E: type, current: E) E {
    const n = @typeInfo(E).@"enum".fields.len;
    return @enumFromInt((@intFromEnum(current) + n - 1) % n);
}

/// A field type joins the focus ring iff it is a struct exposing a `pub`
/// `handle` method — the same duck-typed "convention, not interface" stance
/// ADR-0018 takes for `view`/`handle`. Plain data, rects, and the focus value
/// itself are skipped.
fn isWidget(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "handle");
}

/// The widget-field names of `State`, in declaration order — that array *is*
/// the ring. Frozen into a `const` so the returned type doesn't capture a
/// comptime var.
fn ringOf(comptime State: type) []const [:0]const u8 {
    comptime var names: []const [:0]const u8 = &.{};
    inline for (@typeInfo(State).@"struct".fields) |f| {
        if (isWidget(f.type)) names = names ++ &[_][:0]const u8{f.name};
    }
    return names;
}

/// A comptime focus-routing helper — **sugar over the ADR-0018 switch, not a
/// layer**. It derives the focus ring from `State`'s widget fields (in
/// declaration order) and generalizes `focusNext`/`focusPrev` plus the manual
/// `switch (focus) { .a => a.handle(key), ... }` dispatch. No framework loop,
/// no registry, no retained state — the caller can bypass it entirely.
///
/// `FocusRing(State)` gives you:
///   - `Focus`, a named enum reified from the widget-field names (index = tag),
///   - `next(Focus) Focus` / `prev(Focus) Focus`, wrapping over the ring,
///   - `dispatch(state, focus, key, extras) bool`, which routes `key` to the
///     focused widget's `handle` and returns *consumed*.
///
/// **Where focus lives.** A `State` field can't be typed `FocusRing(State).Focus`
/// — that makes `@typeInfo(State)` depend on itself ("type … depends on itself
/// for type information"). So the caller keeps focus *outside* `State` (a local
/// `Ring.Focus`, as `examples/form.zig` does) — the ring type is still derived
/// from the widget fields, focus just isn't one of them.
///
/// **Extras (`dispatch`).** Widgets have heterogeneous `handle` arities
/// (`TextInput.handle(key)` vs `Select.handle(key, count, visible)`). `extras`
/// is an anon struct mapping a widget field name to a tuple of its *extra* args;
/// `dispatch` appends `@field(extras, name)` after `.{ widget, key }` when the
/// field is present. Because `focus` is a runtime value, `dispatch`'s `inline for`
/// compiles *every* arm — so `extras` must describe **every** multi-arg widget
/// field, not only the focused one (single-arg widgets need no entry).
pub fn FocusRing(comptime State: type) type {
    const names = ringOf(State);
    const Tag = std.math.IntFittingRange(0, if (names.len <= 1) 0 else names.len - 1);
    return struct {
        /// The ring: widget-field names of `State`, in declaration order.
        pub const ring = names;
        /// A named enum over the ring (`@intFromEnum` is the ring index).
        pub const Focus = @Enum(Tag, .exhaustive, names, &std.simd.iota(Tag, names.len));

        /// Next focus target, wrapping (Tab). Widens through `usize` so a
        /// one-bit tag can't overflow on `+ 1`.
        pub fn next(f: Focus) Focus {
            return @enumFromInt((@as(usize, @intFromEnum(f)) + 1) % names.len);
        }

        /// Previous focus target, wrapping (Shift-Tab / `.back_tab`).
        pub fn prev(f: Focus) Focus {
            return @enumFromInt((@as(usize, @intFromEnum(f)) + names.len - 1) % names.len);
        }

        /// Route `key` to the focused widget's `handle` and return *consumed*.
        /// `extras` supplies each multi-arg widget's extra args (see the type
        /// doc). Identical codegen to a hand-written switch — no vtable.
        pub fn dispatch(state: *State, f: Focus, key: Key, extras: anytype) bool {
            inline for (names, 0..) |name, i| {
                if (i == @intFromEnum(f)) {
                    const w = &@field(state, name);
                    const Widget = @TypeOf(w.*);
                    if (@hasField(@TypeOf(extras), name)) {
                        return @call(.auto, Widget.handle, .{ w, key } ++ @field(extras, name));
                    } else {
                        return @call(.auto, Widget.handle, .{ w, key });
                    }
                }
            }
            unreachable;
        }
    };
}

// ============================================================================
// TextInput
// ============================================================================

/// A single-line text field over a caller-owned buffer (capacity is the
/// caller's choice — allocation-free). Editing is codepoint-granular: insert,
/// backspace/delete, ←/→, home/end. The caret and horizontal scroll are derived
/// from `cursor` each frame, so the only persistent state is the bytes and the
/// cursor.
pub const TextInput = struct {
    /// Caller-owned storage. `value()` is `buffer[0..len]`.
    buffer: []u8,
    len: usize = 0,
    /// Insertion point, as a byte offset into `buffer` (always on a codepoint
    /// boundary).
    cursor: usize = 0,
    /// Render each codepoint as this glyph instead of itself (e.g. `'*'` for a
    /// password). Editing still operates on the real bytes.
    mask: ?u8 = null,

    pub const ViewOpts = struct {
        focused: bool = false,
        /// Shown dimmed when the field is empty.
        placeholder: []const u8 = "",
        width: Dim = .{ .fill = 1 },
        theme: *const Theme = theme_mod.appTheme(),
        /// When set (and focused), the field reports its caret's absolute cell
        /// here during render and draws NO block cursor — the caller places the
        /// real terminal cursor there (`App.cursorAt`, ADR-0019). The target is
        /// an *optional* Point: only a focused field writes it, so the caller
        /// resets it to null each frame and reads "no caret" when nothing did.
        /// Left null, the field paints the reverse-video block caret as before.
        cursor_out: ?*?Point = null,
    };

    pub fn value(self: *const TextInput) []const u8 {
        return self.buffer[0..self.len];
    }

    /// Handle a key; returns whether it was consumed (so the form knows to treat
    /// an unconsumed key as navigation). Editing keys are always consumed, even
    /// when they can't move (←at column 0), because they belong to the field.
    pub fn handle(self: *TextInput, key: Key) bool {
        switch (key) {
            .char => |c| self.insert(c),
            .backspace => self.deleteBack(),
            .delete => self.deleteForward(),
            .left => self.cursor = prevBoundary(self.value(), self.cursor),
            .right => self.cursor = nextBoundary(self.value(), self.cursor),
            .home => self.cursor = 0,
            .end => self.cursor = self.len,
            else => return false,
        }
        return true;
    }

    fn insert(self: *TextInput, cp: u21) void {
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &enc) catch return;
        if (self.len + n > self.buffer.len) return; // full — drop the keystroke
        std.mem.copyBackwards(u8, self.buffer[self.cursor + n .. self.len + n], self.buffer[self.cursor..self.len]);
        @memcpy(self.buffer[self.cursor..][0..n], enc[0..n]);
        self.len += n;
        self.cursor += n;
    }

    fn deleteBack(self: *TextInput) void {
        if (self.cursor == 0) return;
        const start = prevBoundary(self.value(), self.cursor);
        const n = self.cursor - start;
        std.mem.copyForwards(u8, self.buffer[start .. self.len - n], self.buffer[self.cursor..self.len]);
        self.len -= n;
        self.cursor = start;
    }

    fn deleteForward(self: *TextInput) void {
        if (self.cursor >= self.len) return;
        const end = nextBoundary(self.value(), self.cursor);
        const n = end - self.cursor;
        std.mem.copyForwards(u8, self.buffer[self.cursor .. self.len - n], self.buffer[end..self.len]);
        self.len -= n;
    }

    pub fn view(self: *const TextInput, a: std.mem.Allocator, opts: ViewOpts) !Node {
        const th = opts.theme;
        const empty = self.len == 0;

        const ctx = try a.create(FieldView);
        if (empty) {
            // Placeholder in hint style; the caret rests at column 0.
            ctx.* = .{
                .text = opts.placeholder,
                .cursor_col = 0,
                .caret = " ",
                .focused = opts.focused,
                .text_style = th.prompts.hint.resolve(th.palette),
                .caret_style = .{ .reverse = true },
                .cursor_out = opts.cursor_out,
            };
        } else {
            const shown = if (self.mask) |m| try maskOf(a, self.value(), m) else self.value();
            const before = if (self.mask) |m| try maskOf(a, self.value()[0..self.cursor], m) else self.value()[0..self.cursor];
            ctx.* = .{
                .text = shown,
                .cursor_col = @intCast(terminal.displayWidth(before)),
                .caret = try caretGlyph(a, self, shown, before.len),
                .focused = opts.focused,
                .text_style = .{},
                .caret_style = .{ .reverse = true },
                .cursor_out = opts.cursor_out,
            };
        }
        return .{
            .width = opts.width,
            .kind = .{ .custom = .{
                .context = ctx,
                .measureFn = FieldView.measureFn,
                .renderFn = FieldView.renderFn,
            } },
        };
    }
};

/// One mask glyph per codepoint of `s`.
fn maskOf(a: std.mem.Allocator, s: []const u8, m: u8) ![]const u8 {
    const out = try a.alloc(u8, utf8Count(s));
    @memset(out, m);
    return out;
}

/// The glyph under the caret in the displayed text — a space past the end.
fn caretGlyph(a: std.mem.Allocator, self: *const TextInput, shown: []const u8, shown_cursor: usize) ![]const u8 {
    if (self.cursor >= self.len) return " ";
    const end = nextBoundary(shown, shown_cursor);
    return a.dupe(u8, shown[shown_cursor..end]);
}

const FieldView = struct {
    text: []const u8,
    cursor_col: u16,
    caret: []const u8,
    focused: bool,
    text_style: Style,
    caret_style: Style,
    cursor_out: ?*?Point,

    fn measureFn(_: *anyopaque, _: *const RenderCtx, limits: Limits) Size {
        return .{ .w = limits.max_w, .h = @min(1, limits.max_h) };
    }

    fn renderFn(context: *anyopaque, _: *const RenderCtx, region: Region) anyerror!void {
        const self: *const FieldView = @ptrCast(@alignCast(context));
        const w = region.width();
        if (w == 0) return;
        // Scroll horizontally so the caret stays in view (right-anchored once
        // the text outgrows the field).
        const scroll: u16 = if (self.cursor_col < w) 0 else self.cursor_col - w + 1;
        const start = byteAtColumn(self.text, scroll);
        _ = try region.writeText(0, 0, self.text[start..], self.text_style);
        if (!self.focused) return;

        const vis_col = self.cursor_col - scroll;
        if (self.cursor_out) |out| {
            // Report the caret's absolute cell for a real terminal cursor; no
            // block (the App draws the cursor there instead).
            out.* = .{ .x = region.rect.x + vis_col, .y = region.rect.y };
        } else {
            _ = try region.writeText(vis_col, 0, self.caret, self.caret_style);
        }
    }
};

// ============================================================================
// TextArea
// ============================================================================

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

// ============================================================================
// Checkbox
// ============================================================================

/// A boolean toggle rendered as `[x] label` / `[ ] label`. Space toggles it;
/// Enter is left for the form (submit), so a checkbox never swallows it.
pub const Checkbox = struct {
    checked: bool = false,

    pub const ViewOpts = struct {
        focused: bool = false,
        label: []const u8 = "",
        theme: *const Theme = theme_mod.appTheme(),
    };

    pub fn handle(self: *Checkbox, key: Key) bool {
        switch (key) {
            .char => |c| if (c == ' ') {
                self.checked = !self.checked;
                return true;
            },
            else => {},
        }
        return false;
    }

    pub fn view(self: *const Checkbox, a: std.mem.Allocator, opts: ViewOpts) !Node {
        const th = opts.theme;
        const box: []const u8 = if (self.checked) "[x]" else "[ ]";
        const label = try std.fmt.allocPrint(a, " {s}", .{opts.label});
        const label_style: Style = if (opts.focused) th.prompts.selected.resolve(th.palette) else .{};
        // Built as node literals directly (not via `ui.zig`, which imports this).
        const children = try a.dupe(Node, &.{
            .{ .kind = .{ .text = .{ .content = box, .style = th.prompts.marker.resolve(th.palette), .wrap = .clip } } },
            .{ .kind = .{ .text = .{ .content = label, .style = label_style, .wrap = .clip } } },
        });
        return .{ .kind = .{ .box = .{ .dir = .row, .children = children } } };
    }
};

// ============================================================================
// Select
// ============================================================================

/// A single-select scrollable list. The options are caller-owned and passed in
/// each frame (immediate mode); the widget holds only the cursor. ↑/↓/Home/End
/// move the highlight and are consumed; Enter/Tab/Escape bubble to the form,
/// which reads the choice as `options[select.highlighted]`.
///
/// By default options are single-line: the list scrolls to keep the highlight
/// within `height` rows — `scroll` is persistent, so the window stays put and
/// slides only when the highlight crosses an edge (a stable viewport, not a
/// highlight glued to the fold). It renders its own window directly rather than
/// wrapping a `viewport`: it already knows which slice is visible, so
/// re-rendering every option into a scratch surface would be wasted work.
///
/// With `wrap = true`, options that overflow the field wrap to several physical
/// rows and `height` becomes a physical-row budget. The window is chosen by
/// growing whole options out from the cursor (`WrapSelectView` / `growWindow`),
/// cursor-anchored like the `prompts` list — persistent scroll can't apply here
/// because the per-option wrapped height isn't known until layout grants a
/// width, which `handle` never sees. `handle` is therefore unchanged; the wrap
/// path derives its window from `highlighted` alone each frame.
pub const Select = struct {
    highlighted: usize = 0,
    /// First visible option — persistent, maintained by `handle`.
    scroll: usize = 0,

    pub const ViewOpts = struct {
        focused: bool = false,
        options: []const []const u8,
        /// Visible rows. Single-line (`wrap = false`): a count of options. Wrapped
        /// (`wrap = true`): a budget of *physical* rows the window grows to fill.
        height: u16 = 6,
        theme: *const Theme = theme_mod.appTheme(),
        /// Opt in to multi-line options: each option wraps to the field width and
        /// the visible window is chosen by physical-row budget (grow-from-cursor)
        /// instead of option index. The single-line default is left untouched.
        wrap: bool = false,
    };

    /// Handle a key; returns whether it was consumed. `count` (the option count)
    /// and `visible` (the window height) are what the caller passes to `view`,
    /// so the highlight and scroll stay in step with what's rendered.
    pub fn handle(self: *Select, key: Key, count: usize, visible: u16) bool {
        if (count == 0) return false;
        switch (key) {
            .up => if (self.highlighted > 0) {
                self.highlighted -= 1;
            },
            .down => if (self.highlighted + 1 < count) {
                self.highlighted += 1;
            },
            .home => self.highlighted = 0,
            .end => self.highlighted = count - 1,
            else => return false,
        }
        self.scroll = scrollFor(self.scroll, self.highlighted, visible, count);
        return true;
    }

    pub fn view(self: *const Select, a: std.mem.Allocator, opts: ViewOpts) !Node {
        const th = opts.theme;
        const count = opts.options.len;
        if (count == 0) return .{ .kind = .{ .text = .{ .content = "", .wrap = .clip } } };

        const hi = @min(self.highlighted, count - 1);

        // Wrapped options are a different windowing model (physical-row budget,
        // grow-from-cursor), rendered by a custom leaf that knows its granted
        // width. The single-line path below is unchanged.
        if (opts.wrap) {
            const ctx = try a.create(WrapSelectView);
            ctx.* = .{
                .options = opts.options,
                .highlighted = hi,
                .budget = @max(opts.height, 1),
                .focused = opts.focused,
                .selected = th.prompts.selected.resolve(th.palette),
                .hint = th.prompts.hint.resolve(th.palette),
            };
            return .{ .kind = .{ .custom = .{
                .context = ctx,
                .measureFn = WrapSelectView.measureFn,
                .renderFn = WrapSelectView.renderFn,
            } } };
        }

        const visible = @min(@max(@as(usize, opts.height), 1), count);
        // Persistent scroll, re-derived so the highlight is always in view even
        // if the caller set `highlighted` directly, bypassing `handle`.
        const scroll = scrollFor(self.scroll, hi, @intCast(visible), count);

        // A fixed label column (widest option + the `"{marker} "` prefix), so the
        // column doesn't jitter as you scroll and the 1-cell overflow gutter to
        // its right stays put. Measured over ALL options, not just the visible
        // ones, so the width is stable. A too-wide option truncates (`…`) only
        // when the granted width can't hold it.
        var opt_w: usize = 0;
        for (opts.options) |o| opt_w = @max(opt_w, terminal.displayWidth(o));
        const label_w: u16 = @intCast(opt_w + 2);

        // Overflow: dim ↑/↓ in the gutter when options are hidden above/below.
        const more_above = scroll > 0;
        const more_below = scroll + visible < count;
        const hint = th.prompts.hint.resolve(th.palette);

        const rows = try a.alloc(Node, visible);
        for (rows, 0..) |*row_node, i| {
            const idx = scroll + i;
            const is_hi = idx == hi;
            const marker: []const u8 = if (is_hi and opts.focused) "›" else " ";
            const line = try std.fmt.allocPrint(a, "{s} {s}", .{ marker, opts.options[idx] });
            // The current option always stands out (the `selected` token), so it
            // reads as chosen whether or not the list is focused; the `›` marker
            // is what signals focus. Non-highlighted rows are plain.
            const style: Style = if (is_hi) th.prompts.selected.resolve(th.palette) else .{};
            const up = i == 0 and more_above;
            const down = i == visible - 1 and more_below;
            const arrow: []const u8 = if (up and down) "↕" else if (up) "↑" else if (down) "↓" else " ";
            const children = try a.dupe(Node, &.{
                .{ .width = .{ .len = label_w }, .kind = .{ .text = .{ .content = line, .style = style, .wrap = .truncate } } },
                .{ .width = .{ .len = 1 }, .kind = .{ .text = .{ .content = arrow, .style = hint, .wrap = .clip } } },
            });
            row_node.* = .{ .kind = .{ .box = .{ .dir = .row, .children = children } } };
        }
        return .{ .kind = .{ .box = .{ .dir = .column, .children = rows } } };
    }
};

/// Slide `scroll` the minimum needed to keep `hi` within a `visible`-row window
/// over `count` items — the single persistent-scroll rule, shared by every
/// single-line list widget (`Select`, `Table`). Both `handle` (to update state)
/// and `view` (to correct it) call it, so the window slides only when the
/// cursor crosses an edge and never drifts off the content.
fn scrollFor(scroll: usize, hi: usize, visible: u16, count: usize) usize {
    const v = @max(@as(usize, visible), 1);
    var s = @min(scroll, count -| v);
    if (hi < s) s = hi;
    if (hi >= s + v) s = hi - v + 1;
    return s;
}

// ---- Wrapped-options rendering (Select `wrap = true`) ----------------------

/// The custom leaf behind a wrapped `Select`. It renders in its granted region,
/// so it wraps every option at the real field width — the width `Select.view`
/// can't know when it builds the node. Layout runs `column` [marker(1) space(1)
/// label(width-3)] and reserves the rightmost column as the overflow gutter, the
/// same shape as the single-line row.
const WrapSelectView = struct {
    options: []const []const u8,
    highlighted: usize,
    /// Physical-row budget the visible window grows to fill.
    budget: u16,
    focused: bool,
    /// The highlighted option's style (whole block); neighbours are plain.
    selected: Style,
    /// The dim overflow-arrow style.
    hint: Style,

    /// Columns available to the wrapped label: total minus the 2-cell marker
    /// prefix and the 1-cell overflow gutter. At least 1 (`wrapForEach` clamps).
    fn labelWidth(w: u16) usize {
        return @max(@as(usize, w) -| 3, 1);
    }

    fn measureFn(context: *anyopaque, _: *const RenderCtx, limits: Limits) Size {
        const self: *const WrapSelectView = @ptrCast(@alignCast(context));
        if (limits.max_w == 0 or limits.max_h == 0) return .{ .w = 0, .h = 0 };
        const lw = labelWidth(limits.max_w);
        var total: usize = 0;
        for (self.options) |o| total += terminal.wrapCount(o, lw);
        const h = @min(@min(total, @as(usize, self.budget)), @as(usize, limits.max_h));
        return .{ .w = limits.max_w, .h = @intCast(@max(h, 1)) };
    }

    fn renderFn(context: *anyopaque, _: *const RenderCtx, region: Region) anyerror!void {
        const self: *const WrapSelectView = @ptrCast(@alignCast(context));
        const w = region.width();
        if (w == 0) return;
        const budget = @min(self.budget, region.height());
        if (budget == 0) return;
        const lw = labelWidth(w);

        const wc = WrapCounts{ .options = self.options, .lw = lw };
        const win = growWindow(self.options.len, self.highlighted, budget, &wc, WrapCounts.at);

        var y: u16 = 0;
        for (win.start..win.end) |idx| {
            if (y >= budget) break;
            const is_hi = idx == self.highlighted;
            var painter = LinePainter{
                .region = region,
                .y = &y,
                .budget = budget,
                .width = w,
                .style = if (is_hi) self.selected else .{},
                .marker = if (is_hi and self.focused) "›" else " ",
                .first = true,
            };
            try terminal.wrapForEach(self.options[idx], lw, &painter, LinePainter.add);
        }

        // Overflow arrows in the gutter (rightmost column), in physical-row
        // terms: ↑ on the first painted row, ↓ on the last. They coincide (↕)
        // only when the whole window is a single row.
        const gx = w - 1;
        const more_above = win.start > 0;
        const more_below = win.end < self.options.len;
        const last = y -| 1;
        if (more_above and more_below and last == 0) {
            _ = try region.writeText(gx, 0, "↕", self.hint);
        } else {
            if (more_above) _ = try region.writeText(gx, 0, "↑", self.hint);
            if (more_below) _ = try region.writeText(gx, last, "↓", self.hint);
        }
    }
};

/// Paints one option's wrapped lines top-down: a full-width background over the
/// label area (so the highlight reads as a block), the marker on the first line,
/// and the label hung at column 2 (continuation lines keep the indent — their
/// marker cells stay blank). Rows past `budget` are dropped (a single option
/// taller than the whole window clips).
const LinePainter = struct {
    region: Region,
    y: *u16,
    budget: u16,
    width: u16,
    style: Style,
    marker: []const u8,
    first: bool,

    fn add(self: *LinePainter, line: []const u8) anyerror!void {
        if (self.y.* >= self.budget) return;
        // Background spans the label area but not the gutter (which carries the
        // dim arrows, never the highlight) — matching the single-line row.
        self.region.sub(.{ .x = 0, .y = self.y.*, .w = self.width -| 1, .h = 1 }).fill(self.style);
        if (self.first) _ = try self.region.writeText(0, self.y.*, self.marker, self.style);
        _ = try self.region.writeText(2, self.y.*, line, self.style);
        self.first = false;
        self.y.* += 1;
    }
};

const Window = struct { start: usize, end: usize };

const WrapCounts = struct {
    options: []const []const u8,
    lw: usize,
    fn at(self: *const WrapCounts, i: usize) usize {
        return terminal.wrapCount(self.options[i], self.lw);
    }
};

/// Grow a visible window of whole options out from `cursor` (upward first, to
/// match the prompts' scroll feel) until `budget` physical rows are used. The
/// ui-side mirror of `prompts`' `list_render.viewport` — kept private because
/// `Select` is its only consumer today; promote it if a second one appears.
fn growWindow(
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

// ============================================================================
// Table
// ============================================================================

/// A read-only data grid: a header row over scrollable body rows, with a
/// selection and a scroll window ported straight from `Select`. Rows and columns
/// are caller-owned and passed to `view` each frame (immediate mode); the widget
/// holds only the two persistent fields `Select` does — `highlighted` (the
/// selected row) and `scroll` (the window top) — maintained by the shared
/// `scrollFor` rule.
///
/// ↑/↓/Home/End move the selection one row / to the ends; PgUp/PgDn page by the
/// visible height. Those keys are consumed; Enter/Tab/Escape bubble to the form,
/// which reads the choice as `rows[table.highlighted]`.
///
/// Column widths reuse the existing `Dim` vocabulary (`node.zig`): `.fit` sizes
/// to the widest cell in that column (header included), `.len(n)` is fixed, and
/// `.fill(w)` splits leftover width proportionally — the box engine does the
/// distribution, so there is no bespoke column math beyond resolving `.fit` to a
/// concrete width. Cells that overrun their column truncate with `…` through the
/// same width/ANSI-aware path `Select` uses (`wrap = .truncate`). The header wears
/// `th.prompts.hint`; the highlighted row is a full-width `th.prompts.selected`
/// band; and a 1-cell right gutter carries the dim ↑/↓/↕ overflow arrows, exactly
/// as `Select`'s single-line path (ADR-0018 incr4).
pub const Table = struct {
    highlighted: usize = 0,
    /// First visible body row — persistent, maintained by `handle`.
    scroll: usize = 0,

    /// A column: a header label and a width in the existing `Dim` vocabulary.
    pub const Column = struct {
        header: []const u8,
        width: Dim = .fit,
    };

    pub const ViewOpts = struct {
        focused: bool = false,
        columns: []const Column,
        /// `rows[r][c]` is the text of row `r`, column `c`. A row must have one
        /// cell per column; a short row renders blanks for the missing cells.
        rows: []const []const []const u8,
        /// Visible body rows (the header sits above and does not scroll).
        height: u16 = 10,
        theme: *const Theme = theme_mod.appTheme(),
    };

    /// Handle a key; returns whether it was consumed. `row_count` (the row count)
    /// and `visible` (the body height) are what the caller passes to `view`, so
    /// the selection and scroll stay in step with what's rendered. PgUp/PgDn move
    /// by `visible` rows; everything else (Enter/Tab/…) bubbles.
    pub fn handle(self: *Table, key: Key, row_count: usize, visible: u16) bool {
        if (row_count == 0) return false;
        const v = @max(@as(usize, visible), 1);
        switch (key) {
            .up => if (self.highlighted > 0) {
                self.highlighted -= 1;
            },
            .down => if (self.highlighted + 1 < row_count) {
                self.highlighted += 1;
            },
            .home => self.highlighted = 0,
            .end => self.highlighted = row_count - 1,
            .pageup => self.highlighted -|= v,
            .pagedown => self.highlighted = @min(self.highlighted + v, row_count - 1),
            else => return false,
        }
        self.scroll = scrollFor(self.scroll, self.highlighted, visible, row_count);
        return true;
    }

    pub fn view(self: *const Table, a: std.mem.Allocator, opts: ViewOpts) !Node {
        const th = opts.theme;
        const cols = opts.columns;
        const count = opts.rows.len;
        const hint = th.prompts.hint.resolve(th.palette);

        // Resolve each column's effective width. `.fit` becomes a concrete `.len`
        // of the widest cell in that column (header + every row), so columns align
        // across rows — a per-row `.fit` would size each cell independently. `.len`
        // and `.fill` pass through untouched for the box engine to distribute.
        const widths = try a.alloc(Dim, cols.len);
        for (cols, widths, 0..) |col, *w, ci| {
            w.* = switch (col.width) {
                .fit => blk: {
                    var max = terminal.displayWidth(col.header);
                    for (opts.rows) |r| {
                        if (ci < r.len) max = @max(max, terminal.displayWidth(r[ci]));
                    }
                    break :blk .{ .len = @intCast(max) };
                },
                else => col.width,
            };
        }

        const hi = if (count == 0) 0 else @min(self.highlighted, count - 1);
        const visible = @min(@max(@as(usize, opts.height), 1), count);
        // Persistent scroll, re-derived so the selection stays in view even if the
        // caller set `highlighted` directly, bypassing `handle`.
        const scroll = if (count == 0) 0 else scrollFor(self.scroll, hi, @intCast(visible), count);

        const more_above = scroll > 0;
        const more_below = scroll + visible < count;

        // Header row + one body row per visible line, then the body draws its own
        // gutter arrows. Header carries a blank gutter cell so its columns line up
        // with the body's.
        const lines = try a.alloc(Node, 1 + visible);
        lines[0] = try buildRow(a, cols, widths, try headerCells(a, cols), hint, hint, " ", .{});

        for (0..visible) |i| {
            const idx = scroll + i;
            const is_hi = idx == hi;
            const style: Style = if (is_hi) th.prompts.selected.resolve(th.palette) else .{};
            // Full-width band on the highlighted row (the box background paints the
            // gaps between cells too); non-highlighted rows are plain.
            const band: Style = if (is_hi) style else .{};
            const up = i == 0 and more_above;
            const down = i == visible - 1 and more_below;
            const arrow: []const u8 = if (up and down) "↕" else if (up) "↑" else if (down) "↓" else " ";
            lines[1 + i] = try buildRow(a, cols, widths, opts.rows[idx], style, hint, arrow, band);
        }
        return .{ .kind = .{ .box = .{ .dir = .column, .children = lines } } };
    }
};

/// The header cells (one per column) as a `[]const []const u8`, so the header
/// row is built through the same `buildRow` path as a body row.
fn headerCells(a: std.mem.Allocator, cols: []const Table.Column) ![]const []const u8 {
    const cells = try a.alloc([]const u8, cols.len);
    for (cols, cells) |col, *c| c.* = col.header;
    return cells;
}

/// One table row: an inner `row{}` of per-cell `text` nodes carrying the resolved
/// column `Dim`s (so the box engine distributes the columns), paired with a fixed
/// 1-cell gutter for the overflow arrow — the same shape as `Select`'s single-line
/// row. The inner row carries the highlight `band` background (so it spans the
/// gaps between cells for a full-width band) but *not* the gutter, which keeps a
/// plain background under the dim arrow exactly as `Select` does. `cell_style`
/// styles the cell text; `gutter_style` styles the arrow.
fn buildRow(
    a: std.mem.Allocator,
    cols: []const Table.Column,
    widths: []const Dim,
    cells: []const []const u8,
    cell_style: Style,
    gutter_style: Style,
    arrow: []const u8,
    band: Style,
) !Node {
    const cells_nodes = try a.alloc(Node, cols.len);
    for (widths, 0..) |w, ci| {
        const content: []const u8 = if (ci < cells.len) cells[ci] else "";
        cells_nodes[ci] = .{
            .width = w,
            .kind = .{ .text = .{ .content = content, .style = cell_style, .wrap = .truncate } },
        };
    }
    const inner: Node = .{
        .width = .{ .fill = 1 },
        .kind = .{ .box = .{ .dir = .row, .gap = 1, .children = cells_nodes, .style = band } },
    };
    const gutter: Node = .{
        .width = .{ .len = 1 },
        .kind = .{ .text = .{ .content = arrow, .style = gutter_style, .wrap = .clip } },
    };
    const outer = try a.dupe(Node, &.{ inner, gutter });
    return .{ .kind = .{ .box = .{ .dir = .row, .children = outer } } };
}

// ============================================================================
// Button
// ============================================================================

/// A stateless action control: `[ Label ]`, activated by Enter or Space. It
/// holds no state (a terminal has no key-up, so there is no "pressed" phase),
/// so `handle` returns whether the key *activated* it — the same routing role
/// as the editors' `consumed` (`true` = "this key is mine, not navigation"), but
/// for an action widget "mine" means "fired." The caller runs the action on a
/// `true` return in its focus arm; unconsumed keys (Tab/arrows) bubble on.
pub const Button = struct {
    pub const ViewOpts = struct {
        focused: bool = false,
        label: []const u8 = "",
        theme: *const Theme = theme_mod.appTheme(),
    };

    pub fn handle(self: *Button, key: Key) bool {
        _ = self;
        return switch (key) {
            .enter => true,
            .char => |c| c == ' ',
            else => false,
        };
    }

    pub fn view(self: *const Button, a: std.mem.Allocator, opts: ViewOpts) !Node {
        _ = self;
        const th = opts.theme;
        const label = try std.fmt.allocPrint(a, "[ {s} ]", .{opts.label});
        const style: Style = if (opts.focused) th.prompts.selected.resolve(th.palette) else .{};
        return .{ .kind = .{ .text = .{ .content = label, .style = style, .wrap = .clip } } };
    }
};

// ============================================================================
// Tabs
// ============================================================================

/// A tab-bar row: a horizontal strip of labels with the active one highlighted.
/// It is *only* the chrome — it does not own the content panes. The caller owns
/// the `active` index and switches what it renders below the bar on it (immediate
/// mode), the same stateless shape as `Button`: `Tabs` holds no state, so it is a
/// zero-field struct and `handle` advances the caller's index in place.
///
/// ←/→ move the active tab, wrapping over the count; number keys `1`-`9` jump
/// directly to that tab if it exists. Those keys are consumed. `Tab` is *never*
/// consumed — it stays reserved for the focus ring, so the ring can still move
/// focus off the bar. Everything else bubbles.
///
/// Rendering is a plain builder composition (no `custom` leaf, like `Checkbox`):
/// a `row{}` of `text` nodes, the active label in `th.prompts.selected` and the
/// inactive ones in `th.prompts.hint`, separated by a single-space gap.
pub const Tabs = struct {
    pub const ViewOpts = struct {
        focused: bool = false,
        labels: []const []const u8,
        active: usize,
        theme: *const Theme = theme_mod.appTheme(),
    };

    /// Handle a key; returns whether it was consumed. `active` is the caller's
    /// index (the caller owns it; the widget just advances it) and `count` is the
    /// tab count, so the widget can wrap/clamp in step with what `view` renders.
    /// ←/→ wrap over `count`; `1`-`9` jump if that tab exists; `Tab` is left for
    /// the focus ring; everything else bubbles.
    pub fn handle(self: *Tabs, key: Key, active: *usize, count: usize) bool {
        _ = self;
        if (count == 0) return false;
        switch (key) {
            .left => active.* = (active.* + count - 1) % count,
            .right => active.* = (active.* + 1) % count,
            .char => |c| {
                if (c < '1' or c > '9') return false;
                const idx = c - '1';
                if (idx >= count) return false;
                active.* = idx;
            },
            else => return false,
        }
        return true;
    }

    pub fn view(self: *const Tabs, a: std.mem.Allocator, opts: ViewOpts) !Node {
        _ = self;
        const th = opts.theme;
        const active_style = th.prompts.selected.resolve(th.palette);
        const inactive_style = th.prompts.hint.resolve(th.palette);
        const cells = try a.alloc(Node, opts.labels.len);
        for (opts.labels, cells, 0..) |label, *cell, i| {
            const is_active = i == opts.active;
            cell.* = .{ .kind = .{ .text = .{
                .content = label,
                .style = if (is_active) active_style else inactive_style,
                .wrap = .clip,
            } } };
        }
        return .{ .kind = .{ .box = .{ .dir = .row, .gap = 1, .children = cells } } };
    }
};

// ============================================================================
// UTF-8 helpers (codepoint boundaries; editing is codepoint-granular)
// ============================================================================

fn prevBoundary(s: []const u8, i: usize) usize {
    var j = i;
    while (j > 0) {
        j -= 1;
        if (s[j] & 0xc0 != 0x80) break; // not a UTF-8 continuation byte
    }
    return j;
}

fn nextBoundary(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    return @min(i + n, s.len);
}

fn utf8Count(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) i = nextBoundary(s, i);
    return n;
}

/// The byte offset in `text` at which the cumulative display width first
/// reaches `target_col` — the left edge of a horizontally scrolled field.
fn byteAtColumn(text: []const u8, target_col: u16) usize {
    var col: u16 = 0;
    var i: usize = 0;
    while (i < text.len and col < target_col) {
        const end = nextBoundary(text, i);
        col += @intCast(terminal.displayWidth(text[i..end]));
        i = end;
    }
    return i;
}
