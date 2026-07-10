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
