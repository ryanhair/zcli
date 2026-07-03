//! Cross-platform rendering end-to-end tests for the list prompts.
//!
//! These drive the real render + erase code paths and replay their byte output
//! through the in-repo `vterm` terminal emulator, then assert on the resulting
//! screen grid. Because `vterm` is pure logic, these run identically on Linux,
//! macOS, and Windows (they're part of `zig build test-zinput`, which Windows CI
//! runs) — unlike the PTY harness, which is POSIX-only.
//!
//! The central invariant is the fix for the original bug: navigating a list
//! whose options wrap must leave **no debris**. We assert that by comparing two
//! screens that must be identical — a fresh render of the target frame, versus
//! rendering the first frame, erasing it, then rendering the target frame. Any
//! leftover character from the wider/taller previous frame makes them differ.

const std = @import("std");
const zinput = @import("zinput");
const vterm = @import("vterm");

const Winsize = zinput.terminal.Winsize;
const testing = std.testing;

/// Replay `bytes` through a fresh `cols`x`rows` emulator and return the visible
/// grid as text (caller frees).
fn screenOf(alloc: std.mem.Allocator, cols: u16, rows: u16, bytes: []const u8) ![]u8 {
    var term = try vterm.VTerm.init(alloc, cols, rows);
    defer term.deinit();
    term.write(bytes);
    return term.getAllText(alloc);
}

// ---------------------------------------------------------------------------
// multi_select
// ---------------------------------------------------------------------------

fn multiFrame(buf: []u8, config: zinput.MultiSelectConfig, selected: []const bool, cursor: usize, ws: Winsize) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    _ = try zinput.multi_select_prompt.renderList(&w, config, selected, cursor, ws);
    return w.buffered();
}

fn multiNavScreen(alloc: std.mem.Allocator, config: zinput.MultiSelectConfig, selected: []const bool, from: usize, to: usize, ws: Winsize) ![]u8 {
    var buf: [16384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const r0 = try zinput.multi_select_prompt.renderList(&w, config, selected, from, ws);
    try zinput.list_render.eraseRegion(&w, r0);
    _ = try zinput.multi_select_prompt.renderList(&w, config, selected, to, ws);
    return screenOf(alloc, ws.col, ws.row, w.buffered());
}

test "emulator: multi_select navigation leaves no debris when options wrap" {
    const alloc = testing.allocator;
    const ws = Winsize{ .row = 24, .col = 30 };
    const config = zinput.MultiSelectConfig{ .message = "Pick", .choices = &.{
        "short",
        "a genuinely long option label that certainly wraps across several rows",
        "third choice here",
    } };
    const selected = [_]bool{ false, false, false };

    // Fresh render of the target frame (cursor on the long, wrapping option).
    var cbuf: [16384]u8 = undefined;
    const clean = try screenOf(alloc, ws.col, ws.row, try multiFrame(&cbuf, config, &selected, 1, ws));
    defer alloc.free(clean);

    // Same frame reached by rendering frame 0, erasing it, then rendering frame 1.
    const nav = try multiNavScreen(alloc, config, &selected, 0, 1, ws);
    defer alloc.free(nav);

    try testing.expectEqualStrings(clean, nav);
}

test "emulator: multi_select wraps wide CJK options without debris" {
    const alloc = testing.allocator;
    const ws = Winsize{ .row = 24, .col = 22 };
    const config = zinput.MultiSelectConfig{ .message = "Pick", .choices = &.{
        "ascii option",
        "你好世界这是一个需要换行显示的很长选项",
        "另一个选项",
    } };
    const selected = [_]bool{ false, true, false };

    var cbuf: [16384]u8 = undefined;
    const clean = try screenOf(alloc, ws.col, ws.row, try multiFrame(&cbuf, config, &selected, 2, ws));
    defer alloc.free(clean);

    const nav = try multiNavScreen(alloc, config, &selected, 1, 2, ws);
    defer alloc.free(nav);

    try testing.expectEqualStrings(clean, nav);
}

// ---------------------------------------------------------------------------
// select
// ---------------------------------------------------------------------------

test "emulator: select navigation leaves no debris when options wrap" {
    const alloc = testing.allocator;
    const ws = Winsize{ .row = 24, .col = 24 };
    const config = zinput.SelectConfig{ .message = "Choose", .choices = &.{
        "one",
        "a long choice that will wrap onto multiple lines at this width",
        "two",
    } };

    var cbuf: [16384]u8 = undefined;
    var cw: std.Io.Writer = .fixed(&cbuf);
    _ = try zinput.select_prompt.renderList(&cw, config, 1, ws);
    const clean = try screenOf(alloc, ws.col, ws.row, cw.buffered());
    defer alloc.free(clean);

    var nbuf: [16384]u8 = undefined;
    var nw: std.Io.Writer = .fixed(&nbuf);
    const r0 = try zinput.select_prompt.renderList(&nw, config, 0, ws);
    try zinput.list_render.eraseRegion(&nw, r0);
    _ = try zinput.select_prompt.renderList(&nw, config, 1, ws);
    const nav = try screenOf(alloc, ws.col, ws.row, nw.buffered());
    defer alloc.free(nav);

    try testing.expectEqualStrings(clean, nav);
}

test "emulator: select hang-indents wrapped continuation lines on screen" {
    const alloc = testing.allocator;
    // Short message keeps the header on one row so option rows are predictable.
    const ws = Winsize{ .row = 24, .col = 20 };
    const config = zinput.SelectConfig{ .message = "Pick", .choices = &.{
        "alpha bravo charlie delta echo",
    } };

    var term = try vterm.VTerm.init(alloc, ws.col, ws.row);
    defer term.deinit();
    var buf: [16384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    _ = try zinput.select_prompt.renderList(&w, config, 0, ws);
    term.write(w.buffered());

    // Row 0: "? Pick" header. Row 1: first option line (prefix "  > "/"  ❯ ").
    // Row 2: a wrapped continuation, hang-indented to the 4-column prefix width.
    const row1 = try term.getLine(alloc, 1);
    defer alloc.free(row1);
    const row2 = try term.getLine(alloc, 2);
    defer alloc.free(row2);

    try testing.expect(std.mem.indexOf(u8, row1, "alpha") != null);
    // Continuation aligns under the label (4 leading spaces), not the bullet.
    try testing.expect(std.mem.startsWith(u8, row2, "    "));
    try testing.expect(std.mem.trim(u8, row2, " ").len > 0);
}

// ---------------------------------------------------------------------------
// text input: echo + backspace-erase (grapheme/width aware)
// ---------------------------------------------------------------------------

test "emulator: backspace-erase clears a wide char's both cells" {
    const alloc = testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    var out: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);

    // Type "ab" then 你 (2 cells), then backspace 你 away and type "c" — the
    // screen must read exactly "abc" with no half-glyph debris in the cells the
    // wide char occupied. A byte- or single-column erase fails this.
    try w.writeAll(try zinput.appendCodepoint(alloc, &buf, 'a'));
    try w.writeAll(try zinput.appendCodepoint(alloc, &buf, 'b'));
    try w.writeAll(try zinput.appendCodepoint(alloc, &buf, '你'));
    try zinput.eraseTrailingGrapheme(&w, &buf);
    try w.writeAll(try zinput.appendCodepoint(alloc, &buf, 'c'));

    try testing.expectEqualStrings("abc", buf.items);

    var term = try vterm.VTerm.init(alloc, 20, 4);
    defer term.deinit();
    term.write(w.buffered());
    const line = try term.getLine(alloc, 0);
    defer alloc.free(line);
    try testing.expectEqualStrings("abc", std.mem.trimEnd(u8, line, " "));
    // Cursor sits right after the 'c' — erase walked back exactly two cells.
    try testing.expectEqual(@as(u32, 3), term.cursor.x);
    try testing.expectEqual(@as(u32, 0), term.cursor.y);
}

// ---------------------------------------------------------------------------
// search
// ---------------------------------------------------------------------------

test "emulator: search navigation leaves no debris when results wrap" {
    const alloc = testing.allocator;
    const ws = Winsize{ .row = 24, .col = 28 };
    const config = zinput.SearchConfig{ .message = "Find", .choices = &.{
        "apple",
        "a very long result entry that will wrap across more than one row",
        "cherry",
    } };
    const filtered = [_]usize{ 0, 1, 2 };
    const query = "";

    var cbuf: [16384]u8 = undefined;
    var cw: std.Io.Writer = .fixed(&cbuf);
    _ = try zinput.search_prompt.renderSearch(&cw, config, query, &filtered, 1, ws);
    const clean = try screenOf(alloc, ws.col, ws.row, cw.buffered());
    defer alloc.free(clean);

    var nbuf: [16384]u8 = undefined;
    var nw: std.Io.Writer = .fixed(&nbuf);
    const r0 = try zinput.search_prompt.renderSearch(&nw, config, query, &filtered, 0, ws);
    try zinput.list_render.eraseRegion(&nw, r0);
    _ = try zinput.search_prompt.renderSearch(&nw, config, query, &filtered, 1, ws);
    const nav = try screenOf(alloc, ws.col, ws.row, nw.buffered());
    defer alloc.free(nav);

    try testing.expectEqualStrings(clean, nav);
}
