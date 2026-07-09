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
//! full-screen widgets and the line-oriented prompts share one look.

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
const Key = terminal.Key;

pub const Theme = theme_mod.Theme;
const default_theme = theme_mod.default_theme;

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
        theme: *const Theme = &default_theme,
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
        if (self.focused) {
            _ = try region.writeText(self.cursor_col - scroll, 0, self.caret, self.caret_style);
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
        theme: *const Theme = &default_theme,
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
/// which reads the choice as `options[select.highlighted]`. Options are
/// single-line. The list scrolls to keep the highlight within `height` rows —
/// `scroll` is persistent, so the window stays put and slides only when the
/// highlight crosses an edge (a stable viewport, not a highlight glued to the
/// fold). It renders its own window directly rather than wrapping a `viewport`:
/// it already knows which slice is visible, so re-rendering every option into a
/// scratch surface would be wasted work.
pub const Select = struct {
    highlighted: usize = 0,
    /// First visible option — persistent, maintained by `handle`.
    scroll: usize = 0,

    pub const ViewOpts = struct {
        focused: bool = false,
        options: []const []const u8,
        /// Visible rows; the list scrolls within this window.
        height: u16 = 6,
        theme: *const Theme = &default_theme,
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
/// over `count` items — the persistent-scroll rule shared by `handle` (to
/// update state) and `view` (to correct it).
fn scrollFor(scroll: usize, hi: usize, visible: u16, count: usize) usize {
    const v = @max(@as(usize, visible), 1);
    var s = @min(scroll, count -| v);
    if (hi < s) s = hi;
    if (hi >= s + v) s = hi - v + 1;
    return s;
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
        theme: *const Theme = &default_theme,
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
