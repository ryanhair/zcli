//! prompts — Interactive terminal prompts for CLI applications.
//!
//! Standalone library: works with any writer/reader, no zcli dependency required.
//! Falls back to line-based input when stdin is not a TTY.
//!
//! ```zig
//! const prompts = @import("prompts");
//!
//! const name = try prompts.text(writer, reader, allocator, .{ .message = "Name:" });
//! const ok = try prompts.confirm(writer, reader, .{ .message = "Continue?" });
//! const idx = try prompts.select(writer, reader, .{ .message = "Pick:", .choices = &.{"a", "b"} });
//! ```

const std = @import("std");
pub const terminal = @import("terminal");
pub const theme = @import("theme");

/// Style context used when the caller doesn't pass one: the default theme at
/// ANSI-16, matching the package's historical fixed colors. zcli applications
/// pass `context.theme` instead, which carries the app's theme and the
/// detected terminal capabilities (including NO_COLOR).
pub const default_style: theme.ThemeContext = .{
    .caps = .{ .capability = .ansi_16, .is_tty = true, .color_enabled = true },
};

/// Render `ref`'s opening escape sequence into `buf`, returning the (possibly
/// empty) slice. Pair every non-empty result with `closeSeq`.
pub fn openSeq(buf: []u8, ctx: theme.ThemeContext, ref: theme.StyleRef) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const style = ctx.resolveRef(ref);
    const wrote = style.writeSequence(&w, ctx.capability()) catch false;
    return if (wrote) w.buffered() else "";
}

/// The reset matching a sequence produced by `openSeq` ("" when nothing was opened).
pub fn closeSeq(open: []const u8) []const u8 {
    return if (open.len > 0) "\x1b[0m" else "";
}

/// Shared rendering machinery for the list-style prompts (wrapping, viewport,
/// resize-safe erase).
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

// Re-export main functions
pub const text = text_prompt.text;
pub const confirm = confirm_prompt.confirm;
pub const select = select_prompt.select;
pub const multiSelect = multi_select_prompt.multiSelect;
pub const password = password_prompt.password;
pub const search = search_prompt.search;
pub const number = number_prompt.number;
pub const editor = editor_prompt.editor;

/// Append a typed codepoint to `buf` as UTF-8, returning the appended bytes
/// (a slice into `buf.items`) so the caller can echo them.
pub fn appendCodepoint(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), c: u21) ![]const u8 {
    var utf8: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(c, &utf8) catch unreachable; // readKey only yields valid scalars
    try buf.appendSlice(allocator, utf8[0..n]);
    return buf.items[buf.items.len - n ..];
}

/// Shrink `buf` by its trailing grapheme cluster — one *visible* character,
/// however many codepoints compose it. No-op on an empty buffer. For prompts
/// that repaint their whole line; `eraseTrailingGrapheme` also erases in place.
pub fn popTrailingGrapheme(buf: *std.ArrayList(u8)) void {
    buf.items.len -= terminal.trailingGraphemeLen(buf.items);
}

/// Remove the trailing grapheme cluster from `buf` and erase it from the
/// terminal line: backspace, space, backspace — once per display column, so a
/// double-width CJK char or emoji clears both of its cells.
pub fn eraseTrailingGrapheme(writer: anytype, buf: *std.ArrayList(u8)) !void {
    if (buf.items.len == 0) return;
    const tail = buf.items[buf.items.len - terminal.trailingGraphemeLen(buf.items) ..];
    const cols = terminal.displayWidth(tail);
    buf.items.len -= tail.len;
    for (0..cols) |_| try writer.writeAll("\x08");
    for (0..cols) |_| try writer.writeAll(" ");
    for (0..cols) |_| try writer.writeAll("\x08");
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

test "eraseTrailingGrapheme erases one column per display cell" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    var out: [64]u8 = undefined;

    // ASCII: one cell.
    try buf.appendSlice(allocator, "ab");
    var w1: std.Io.Writer = .fixed(&out);
    try eraseTrailingGrapheme(&w1, &buf);
    try std.testing.expectEqualStrings("a", buf.items);
    try std.testing.expectEqualStrings("\x08 \x08", w1.buffered());

    // Wide CJK: two cells, so two backspace/space pairs.
    buf.clearRetainingCapacity();
    try buf.appendSlice(allocator, "你");
    var w2: std.Io.Writer = .fixed(&out);
    try eraseTrailingGrapheme(&w2, &buf);
    try std.testing.expectEqualStrings("", buf.items);
    try std.testing.expectEqualStrings("\x08\x08  \x08\x08", w2.buffered());
}
