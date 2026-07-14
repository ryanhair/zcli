//! TextInput widget (ADR-0018): a single-line text field.

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
const Point = surface_mod.Point;
const Key = terminal.Key;
const Theme = theme_mod.Theme;

const prevBoundary = helpers.prevBoundary;
const nextBoundary = helpers.nextBoundary;
const utf8Count = helpers.utf8Count;
const byteAtColumn = helpers.byteAtColumn;

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

    fn renderFn(context: *anyopaque, _: *const RenderCtx, region: surface_mod.Region) anyerror!void {
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
