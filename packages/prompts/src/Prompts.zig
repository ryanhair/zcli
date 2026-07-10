//! Prompts — interactive terminal prompts for CLI applications.
//!
//! This file is the type: `@import("prompts")` returns a struct bundling the
//! environment every prompt needs — writer, reader, allocator, and theme —
//! and each of the eight prompts is a method on it. Standalone library: no
//! zcli dependency required; falls back to line-based input when stdin is
//! not a TTY.
//!
//! ```zig
//! const Prompts = @import("prompts");
//!
//! const p: Prompts = .{ .writer = writer, .reader = reader, .allocator = allocator };
//!
//! const name = try p.text(.{ .message = "Name:" });
//! const ok = try p.confirm(.{ .message = "Continue?" });
//! const idx = try p.select(.{ .message = "Pick:", .choices = &.{"a", "b"} });
//! ```
//!
//! In a zcli command, `context.prompts()` returns an instance pre-wired to the
//! command's streams, allocator, and theme.

writer: *std.Io.Writer,
reader: *std.Io.Reader,
/// Owns every string a prompt returns (`text`, `password`, `editor`) and
/// the index slice from `multiSelect`.
allocator: std.mem.Allocator,
/// Theme + terminal capabilities for styling; zcli commands carry this in
/// `context.theme` (`context.prompts()` wires it up).
theme: ThemeContext = default_style,

pub const text = text_prompt.text;
pub const confirm = confirm_prompt.confirm;
pub const select = select_prompt.select;
pub const multiSelect = multi_select_prompt.multiSelect;
pub const password = password_prompt.password;
pub const search = search_prompt.search;
pub const number = number_prompt.number;
pub const editor = editor_prompt.editor;

const std = @import("std");
const theme_pkg = @import("theme");
pub const terminal = @import("terminal");

const Prompts = @This();

/// Theming re-exports, so standalone users can build a custom style context
/// without depending on the `theme` package directly (it's transitive here).
pub const Theme = theme_pkg.Theme;
pub const ThemeContext = theme_pkg.ThemeContext;
pub const Capabilities = theme_pkg.Capabilities;
pub const StyleRef = theme_pkg.StyleRef;

/// Style context used when an instance doesn't set one: the app theme (root
/// `zcli_theme`, or the default — ADR-0020) at ANSI-16. zcli applications
/// set `.theme = context.theme` instead, which carries the app's theme and the
/// detected terminal capabilities (including NO_COLOR).
pub const default_style: ThemeContext = .fallback;

/// Render `ref`'s opening escape sequence into `buf`, returning the (possibly
/// empty) slice. Pair every non-empty result with `closeSeq`.
pub fn openSeq(buf: []u8, ctx: ThemeContext, ref: StyleRef) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const style = ctx.resolveRef(ref);
    const wrote = style.writeSequence(&w, ctx.capability()) catch false;
    return if (wrote) w.buffered() else "";
}

/// The reset matching a sequence produced by `openSeq` ("" when nothing was opened).
pub fn closeSeq(open: []const u8) []const u8 {
    return if (open.len > 0) "\x1b[0m" else "";
}

/// Shared rendering machinery for the prompts (viewport + frame node builders).
pub const list_render = @import("list_render.zig");

pub const text_prompt = @import("text.zig");
pub const confirm_prompt = @import("confirm.zig");
pub const select_prompt = @import("select.zig");
pub const multi_select_prompt = @import("multi_select.zig");
pub const password_prompt = @import("password.zig");
pub const search_prompt = @import("search.zig");
pub const number_prompt = @import("number.zig");
pub const editor_prompt = @import("editor.zig");

/// Returned by a prompt when the user presses one of the caller's
/// `interrupt_keys`. The prompt stays domain-agnostic — the caller decides what
/// the interruption means (go back, cancel, open help, …).
pub const PromptError = error{Interrupted};

/// Whether `key` is one of the caller's interrupt keys.
pub fn isInterrupt(key: terminal.Key, keys: []const terminal.Key) bool {
    for (keys) |k| {
        if (std.meta.eql(key, k)) return true;
    }
    return false;
}

/// Append a typed codepoint to `buf` as UTF-8, returning the appended bytes
/// (a slice into `buf.items`) so the caller can echo them.
pub fn appendCodepoint(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), c: u21) ![]const u8 {
    var utf8: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(c, &utf8) catch unreachable; // readKey only yields valid scalars
    try buf.appendSlice(allocator, utf8[0..n]);
    return buf.items[buf.items.len - n ..];
}

/// Shrink `buf` by its trailing grapheme cluster — one *visible* character,
/// however many codepoints compose it. No-op on an empty buffer. The line
/// editors call this on backspace and repaint the frame from the new buffer.
pub fn popTrailingGrapheme(buf: *std.ArrayList(u8)) void {
    buf.items.len -= terminal.trailingGraphemeLen(buf.items);
}

/// Region-relative cursor position at the end of `content` as the engine
/// word-wraps it at `width` — where a line editor's insertion point lands.
/// The wrapper drops trailing break-spaces, but the cursor still advances
/// past them (a prompt line ends "message: " with the cursor after the gap).
pub fn endPosition(content: []const u8, width: usize) struct { x: u16, y: u16 } {
    const Ctx = struct {
        lines: usize = 0,
        last_w: usize = 0,
        fn add(self: *@This(), line: []const u8) anyerror!void {
            self.lines += 1;
            self.last_w = terminal.displayWidth(line);
        }
    };
    var c = Ctx{};
    terminal.wrapForEach(content, width, &c, Ctx.add) catch {};
    const w = @max(width, 1);
    const trailing = content.len - std.mem.trimEnd(u8, content, " ").len;
    var x = c.last_w + trailing;
    var y = c.lines -| 1;
    while (x >= w) {
        x -= w;
        y += 1;
    }
    return .{ .x = @intCast(x), .y = @intCast(y) };
}

/// Flush a writer if it supports flushing. Works with both pointer and value writer types.
pub fn flushWriter(writer: anytype) void {
    const W = @TypeOf(writer);
    const T = if (@typeInfo(W) == .pointer) @typeInfo(W).pointer.child else W;
    if (@hasDecl(T, "flush")) {
        writer.flush() catch {};
    }
}

// Re-export config types
pub const TextConfig = text_prompt.TextConfig;
pub const Preview = text_prompt.Preview;
pub const ConfirmConfig = confirm_prompt.ConfirmConfig;
pub const SelectConfig = select_prompt.SelectConfig;
pub const MultiSelectConfig = multi_select_prompt.MultiSelectConfig;
pub const PasswordConfig = password_prompt.PasswordConfig;
pub const SearchConfig = search_prompt.SearchConfig;
pub const NumberConfig = number_prompt.NumberConfig;
pub const EditorConfig = editor_prompt.EditorConfig;

test {
    std.testing.refAllDecls(@This());
}

test "appendCodepoint encodes multibyte UTF-8 and returns the echo slice" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try std.testing.expectEqualStrings("a", try appendCodepoint(allocator, &buf, 'a'));
    try std.testing.expectEqualStrings("é", try appendCodepoint(allocator, &buf, 'é'));
    try std.testing.expectEqualStrings("你", try appendCodepoint(allocator, &buf, '你'));
    try std.testing.expectEqualStrings("😊", try appendCodepoint(allocator, &buf, '😊'));
    try std.testing.expectEqualStrings("aé你😊", buf.items);
}

test "popTrailingGrapheme removes whole clusters, not bytes" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    // 'e' + combining acute is one cluster: a single pop removes both codepoints.
    try buf.appendSlice(allocator, "a你e\u{0301}");
    popTrailingGrapheme(&buf);
    try std.testing.expectEqualStrings("a你", buf.items);
    popTrailingGrapheme(&buf);
    try std.testing.expectEqualStrings("a", buf.items);
    popTrailingGrapheme(&buf);
    try std.testing.expectEqualStrings("", buf.items);
    popTrailingGrapheme(&buf); // no-op on empty
    try std.testing.expectEqualStrings("", buf.items);
}
