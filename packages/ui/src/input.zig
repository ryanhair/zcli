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
