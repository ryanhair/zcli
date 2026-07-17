//! Tests for the focusable input widgets (ADR-0018): `handle` as pure state
//! transitions (no terminal), and `view` painted onto a surface directly.

const std = @import("std");
const theme_mod = @import("theme");
const ui = @import("ui.zig");
const widgets = @import("widgets.zig");

const testing = std.testing;
const TextInput = widgets.TextInput;
const Checkbox = widgets.Checkbox;
const Select = widgets.Select;
const Table = widgets.Table;
const Button = widgets.Button;
const Tabs = widgets.Tabs;

// ---- handle: TextInput editing --------------------------------------------

test "TextInput inserts at the cursor and reports consumed" {
    var buf: [16]u8 = undefined;
    var ti = TextInput{ .buffer = &buf };
    try testing.expect(ti.handle(.{ .char = 'h' }));
    try testing.expect(ti.handle(.{ .char = 'i' }));
    try testing.expectEqualStrings("hi", ti.value());
    try testing.expectEqual(@as(usize, 2), ti.cursor);
}

test "TextInput backspace and delete remove a codepoint" {
    var buf: [16]u8 = undefined;
    var ti = TextInput{ .buffer = &buf };
    for ("abc") |c| _ = ti.handle(.{ .char = c });
    _ = ti.handle(.backspace); // "ab", cursor 2
    try testing.expectEqualStrings("ab", ti.value());
    _ = ti.handle(.home);
    _ = ti.handle(.delete); // remove 'a' → "b"
    try testing.expectEqualStrings("b", ti.value());
    try testing.expectEqual(@as(usize, 0), ti.cursor);
}

test "TextInput cursor moves and inserts mid-string" {
    var buf: [16]u8 = undefined;
    var ti = TextInput{ .buffer = &buf };
    for ("ac") |c| _ = ti.handle(.{ .char = c });
    _ = ti.handle(.left); // between a and c
    _ = ti.handle(.{ .char = 'b' });
    try testing.expectEqualStrings("abc", ti.value());
    _ = ti.handle(.end);
    try testing.expectEqual(@as(usize, 3), ti.cursor);
}

test "TextInput edits multibyte codepoints whole" {
    var buf: [16]u8 = undefined;
    var ti = TextInput{ .buffer = &buf };
    _ = ti.handle(.{ .char = 'é' }); // 2 bytes
    _ = ti.handle(.{ .char = '中' }); // 3 bytes
    try testing.expectEqual(@as(usize, 5), ti.len);
    _ = ti.handle(.backspace); // removes 中 (all 3 bytes)
    try testing.expectEqualStrings("é", ti.value());
    _ = ti.handle(.left); // before é
    _ = ti.handle(.right); // after é (one codepoint, 2 bytes)
    try testing.expectEqual(@as(usize, 2), ti.cursor);
}

test "TextInput drops a keystroke when the buffer is full" {
    var buf: [2]u8 = undefined;
    var ti = TextInput{ .buffer = &buf };
    _ = ti.handle(.{ .char = 'a' });
    _ = ti.handle(.{ .char = 'b' });
    try testing.expect(ti.handle(.{ .char = 'c' })); // consumed, but dropped
    try testing.expectEqualStrings("ab", ti.value());
}

test "TextInput does not consume navigation keys" {
    var buf: [16]u8 = undefined;
    var ti = TextInput{ .buffer = &buf };
    try testing.expect(!ti.handle(.tab));
    try testing.expect(!ti.handle(.back_tab));
    try testing.expect(!ti.handle(.enter));
    try testing.expect(!ti.handle(.escape));
}

// ---- handle: TextArea ------------------------------------------------------

const TextArea = widgets.TextArea;
// A wide field so most typing stays on one visual row unless a `\n` or an
// explicit wrap width forces a break.
const ta_w = 40;
const ta_h = 6;

test "TextArea inserts, deletes, and Enter adds a newline" {
    var buf: [64]u8 = undefined;
    var ta = TextArea{ .buffer = &buf };
    for ("ab") |c| _ = ta.handle(.{ .char = c }, ta_w, ta_h);
    try testing.expect(ta.handle(.enter, ta_w, ta_h)); // Enter inserts \n (consumed)
    for ("cd") |c| _ = ta.handle(.{ .char = c }, ta_w, ta_h);
    try testing.expectEqualStrings("ab\ncd", ta.value());
    try testing.expectEqual(@as(usize, 5), ta.cursor);
    _ = ta.handle(.backspace, ta_w, ta_h); // "ab\nc"
    try testing.expectEqualStrings("ab\nc", ta.value());
    _ = ta.handle(.home, ta_w, ta_h); // start of visual row 2
    _ = ta.handle(.delete, ta_w, ta_h); // delete 'c'
    try testing.expectEqualStrings("ab\n", ta.value());
}

test "TextArea edits multibyte codepoints whole" {
    var buf: [64]u8 = undefined;
    var ta = TextArea{ .buffer = &buf };
    _ = ta.handle(.{ .char = 'é' }, ta_w, ta_h); // 2 bytes
    _ = ta.handle(.{ .char = '中' }, ta_w, ta_h); // 3 bytes
    try testing.expectEqual(@as(usize, 5), ta.len);
    _ = ta.handle(.backspace, ta_w, ta_h); // removes 中 whole
    try testing.expectEqualStrings("é", ta.value());
}

test "TextArea left/right cross the newline boundary" {
    var buf: [64]u8 = undefined;
    var ta = TextArea{ .buffer = &buf };
    for ("a") |c| _ = ta.handle(.{ .char = c }, ta_w, ta_h);
    _ = ta.handle(.enter, ta_w, ta_h);
    for ("b") |c| _ = ta.handle(.{ .char = c }, ta_w, ta_h); // "a\nb", cursor 3
    _ = ta.handle(.left, ta_w, ta_h); // before 'b' (offset 2)
    try testing.expectEqual(@as(usize, 2), ta.cursor);
    _ = ta.handle(.left, ta_w, ta_h); // onto the \n (offset 1)
    try testing.expectEqual(@as(usize, 1), ta.cursor);
    _ = ta.handle(.right, ta_w, ta_h); // back across the \n (offset 2)
    try testing.expectEqual(@as(usize, 2), ta.cursor);
}

test "TextArea up/down move a visual row, clamping the column" {
    var buf: [64]u8 = undefined;
    var ta = TextArea{ .buffer = &buf };
    // "hello\nhi\nworld" — three lines of differing length.
    for ("hello") |c| _ = ta.handle(.{ .char = c }, ta_w, ta_h);
    _ = ta.handle(.enter, ta_w, ta_h);
    for ("hi") |c| _ = ta.handle(.{ .char = c }, ta_w, ta_h);
    _ = ta.handle(.enter, ta_w, ta_h);
    for ("world") |c| _ = ta.handle(.{ .char = c }, ta_w, ta_h);
    // Cursor at end of "world" (col 5). Up → "hi" clamps to col 2 (its length).
    _ = ta.handle(.up, ta_w, ta_h);
    try testing.expectEqual(@as(usize, 8), ta.cursor); // after "hi"
    // Up again → "hello" at col 2 (the column is re-derived from the offset each
    // press, no sticky goal column — so it stays at 2, not the original 5).
    _ = ta.handle(.up, ta_w, ta_h);
    try testing.expectEqual(@as(usize, 2), ta.cursor); // "he|llo"
    // Down twice returns toward "world" at col 2.
    _ = ta.handle(.down, ta_w, ta_h);
    _ = ta.handle(.down, ta_w, ta_h);
    try testing.expectEqual(@as(usize, 11), ta.cursor); // "wo|rld" (offset 9+2)
}

test "TextArea up/down move visual rows within one wrapped paragraph" {
    var buf: [64]u8 = undefined;
    var ta = TextArea{ .buffer = &buf };
    // One paragraph that wraps at width 6: "aaa bbb ccc" → "aaa" / "bbb" / "ccc".
    for ("aaa bbb ccc") |c| _ = ta.handle(.{ .char = c }, 6, ta_h); // cursor at end (row 2)
    _ = ta.handle(.up, 6, ta_h); // to visual row 1 ("bbb"), col clamps to 3
    // "aaa bbb ccc": row1 "bbb" starts at byte 4; col 3 → offset 7 (after "bbb").
    try testing.expectEqual(@as(usize, 7), ta.cursor);
    _ = ta.handle(.home, 6, ta_h); // start of visual row "bbb"
    try testing.expectEqual(@as(usize, 4), ta.cursor);
    _ = ta.handle(.end, 6, ta_h); // end of visual row "bbb"
    try testing.expectEqual(@as(usize, 7), ta.cursor);
}

test "TextArea PgUp/PgDn move by the height in visual rows" {
    var buf: [128]u8 = undefined;
    var ta = TextArea{ .buffer = &buf };
    // 10 short lines "0".."9" — each is its own visual row.
    for (0..10) |i| {
        _ = ta.handle(.{ .char = @intCast('0' + i) }, ta_w, ta_h);
        if (i < 9) _ = ta.handle(.enter, ta_w, ta_h);
    }
    // Cursor on the last row (9), col 1 (after the digit — the preserved target).
    const h = 6;
    _ = ta.handle(.pageup, ta_w, h);
    try testing.expectEqual(@as(RowColExpect, .{ .row = 3, .col = 1 }), rowColOf(&ta, ta_w));
    _ = ta.handle(.pageup, ta_w, h); // row 3 - 6 → clamp to 0
    try testing.expectEqual(@as(RowColExpect, .{ .row = 0, .col = 1 }), rowColOf(&ta, ta_w));
    _ = ta.handle(.pagedown, ta_w, h); // 0 + 6 → row 6
    try testing.expectEqual(@as(RowColExpect, .{ .row = 6, .col = 1 }), rowColOf(&ta, ta_w));
    _ = ta.handle(.pagedown, ta_w, h); // 6 + 6 → clamp to 9 (last row)
    try testing.expectEqual(@as(RowColExpect, .{ .row = 9, .col = 1 }), rowColOf(&ta, ta_w));
}

test "TextArea keeps the caret in the scroll window" {
    var buf: [128]u8 = undefined;
    var ta = TextArea{ .buffer = &buf };
    // 10 single-row lines, a 4-row window.
    for (0..10) |i| {
        _ = ta.handle(.{ .char = @intCast('0' + i) }, ta_w, ta_h);
        if (i < 9) _ = ta.handle(.enter, ta_w, ta_h);
    }
    const h = 4;
    _ = ta.handle(.end, ta_w, h); // cursor on row 9
    _ = ta.handle(.home, ta_w, h); // Home stays on row 9
    // Cursor is on visual row 9; the 4-row window slid to [6,10).
    try testing.expectEqual(@as(u16, 6), ta.scroll_row);
    for (0..7) |_| _ = ta.handle(.up, ta_w, h); // to row 2
    try testing.expectEqual(@as(u16, 2), ta.scroll_row); // window slid up to [2,6)
}

test "TextArea drops a keystroke when the buffer is full" {
    var buf: [2]u8 = undefined;
    var ta = TextArea{ .buffer = &buf };
    _ = ta.handle(.{ .char = 'a' }, ta_w, ta_h);
    _ = ta.handle(.{ .char = 'b' }, ta_w, ta_h);
    try testing.expect(ta.handle(.{ .char = 'c' }, ta_w, ta_h)); // consumed, dropped
    try testing.expectEqualStrings("ab", ta.value());
    try testing.expect(ta.handle(.enter, ta_w, ta_h)); // \n also dropped (full)
    try testing.expectEqualStrings("ab", ta.value());
}

test "TextArea on an empty buffer: motion is a no-op, editing keys consume" {
    var buf: [16]u8 = undefined;
    var ta = TextArea{ .buffer = &buf };
    try testing.expect(ta.handle(.up, ta_w, ta_h));
    try testing.expect(ta.handle(.down, ta_w, ta_h));
    try testing.expect(ta.handle(.left, ta_w, ta_h));
    try testing.expect(ta.handle(.home, ta_w, ta_h));
    try testing.expectEqual(@as(usize, 0), ta.cursor);
    try testing.expectEqual(@as(usize, 0), ta.len);
}

test "TextArea does not consume navigation keys" {
    var buf: [16]u8 = undefined;
    var ta = TextArea{ .buffer = &buf };
    try testing.expect(!ta.handle(.tab, ta_w, ta_h));
    try testing.expect(!ta.handle(.back_tab, ta_w, ta_h));
    try testing.expect(!ta.handle(.escape, ta_w, ta_h));
    // ...but Enter IS consumed (it inserts a newline — the multi-line distinction).
    try testing.expect(ta.handle(.enter, ta_w, ta_h));
}

// A test helper mirroring the widget's own `(visual_row, col)` derivation, so
// paging/motion tests can assert the caret's logical position without reaching
// into the private geometry functions.
const RowColExpect = struct { row: usize, col: u16 };
fn rowColOf(ta: *const TextArea, width: u16) RowColExpect {
    // Re-derive by walking: count visual rows before the cursor, and the column
    // is the display width from the current row's start. We approximate via the
    // widget's public value + a simple newline-count for these single-row-line
    // fixtures (each line is one visual row), which is exact here.
    var row: usize = 0;
    var col: u16 = 0;
    const text = ta.value();
    var i: usize = 0;
    while (i < ta.cursor) : (i += 1) {
        if (text[i] == '\n') {
            row += 1;
            col = 0;
        } else col += 1;
    }
    _ = width;
    return .{ .row = row, .col = col };
}

// ---- handle: Checkbox ------------------------------------------------------

test "Checkbox toggles on space, leaves Enter for the form" {
    var cb = Checkbox{};
    try testing.expect(cb.handle(.{ .char = ' ' }));
    try testing.expect(cb.checked);
    try testing.expect(cb.handle(.{ .char = ' ' }));
    try testing.expect(!cb.checked);
    // Enter is not consumed — the form uses it to submit.
    try testing.expect(!cb.handle(.enter));
    try testing.expect(!cb.checked);
}

// ---- handle: Select --------------------------------------------------------

test "Select moves the highlight and clamps at the ends" {
    var sel = Select{};
    const n = 5;
    try testing.expect(sel.handle(.down, n, 3));
    try testing.expectEqual(@as(usize, 1), sel.highlighted);
    _ = sel.handle(.up, n, 3);
    _ = sel.handle(.up, n, 3); // clamp at the top
    try testing.expectEqual(@as(usize, 0), sel.highlighted);
    _ = sel.handle(.end, n, 3);
    try testing.expectEqual(@as(usize, 4), sel.highlighted);
    _ = sel.handle(.down, n, 3); // clamp at the bottom
    try testing.expectEqual(@as(usize, 4), sel.highlighted);
    _ = sel.handle(.home, n, 3);
    try testing.expectEqual(@as(usize, 0), sel.highlighted);
}

test "Select consumes navigation, bubbles Enter/Tab, ignores an empty list" {
    var sel = Select{};
    try testing.expect(sel.handle(.down, 3, 3));
    try testing.expect(!sel.handle(.enter, 3, 3));
    try testing.expect(!sel.handle(.tab, 3, 3));
    try testing.expect(!sel.handle(.down, 0, 3)); // nothing to move
}

test "Select scrolls to keep the highlight in the window" {
    var sel = Select{};
    const n = 6;
    const vis = 3;
    for (0..4) |_| _ = sel.handle(.down, n, vis); // highlight 4
    try testing.expectEqual(@as(usize, 4), sel.highlighted);
    try testing.expectEqual(@as(usize, 2), sel.scroll); // window [2,5) shows it
    for (0..3) |_| _ = sel.handle(.up, n, vis); // back to 1
    try testing.expectEqual(@as(usize, 1), sel.highlighted);
    try testing.expectEqual(@as(usize, 1), sel.scroll); // window slid up to [1,4)
}

// ---- handle: Table ---------------------------------------------------------

test "Table moves the selection and clamps at the ends" {
    var t = Table{};
    const n = 5;
    try testing.expect(t.handle(.down, n, 3));
    try testing.expectEqual(@as(usize, 1), t.highlighted);
    _ = t.handle(.up, n, 3);
    _ = t.handle(.up, n, 3); // clamp at the top
    try testing.expectEqual(@as(usize, 0), t.highlighted);
    _ = t.handle(.end, n, 3);
    try testing.expectEqual(@as(usize, 4), t.highlighted);
    _ = t.handle(.down, n, 3); // clamp at the bottom
    try testing.expectEqual(@as(usize, 4), t.highlighted);
    _ = t.handle(.home, n, 3);
    try testing.expectEqual(@as(usize, 0), t.highlighted);
}

test "Table consumes navigation, bubbles Enter/Tab, ignores an empty grid" {
    var t = Table{};
    try testing.expect(t.handle(.down, 3, 3));
    try testing.expect(!t.handle(.enter, 3, 3));
    try testing.expect(!t.handle(.tab, 3, 3));
    try testing.expect(!t.handle(.down, 0, 3)); // nothing to move
}

test "Table pages by the visible height and clamps at the boundaries" {
    var t = Table{};
    const n = 20;
    const vis = 5;
    try testing.expect(t.handle(.pagedown, n, vis)); // 0 -> 5
    try testing.expectEqual(@as(usize, 5), t.highlighted);
    _ = t.handle(.pagedown, n, vis); // 5 -> 10
    try testing.expectEqual(@as(usize, 10), t.highlighted);
    _ = t.handle(.pagedown, n, vis); // 10 -> 15
    _ = t.handle(.pagedown, n, vis); // 15 -> 19 (clamped, not 20)
    try testing.expectEqual(@as(usize, 19), t.highlighted);
    _ = t.handle(.pagedown, n, vis); // already at the last row, stays
    try testing.expectEqual(@as(usize, 19), t.highlighted);
    _ = t.handle(.pageup, n, vis); // 19 -> 14
    try testing.expectEqual(@as(usize, 14), t.highlighted);
    _ = t.handle(.pageup, n, vis); // 14 -> 9
    _ = t.handle(.pageup, n, vis); // 9 -> 4
    _ = t.handle(.pageup, n, vis); // 4 -> 0 (saturating, not underflow)
    try testing.expectEqual(@as(usize, 0), t.highlighted);
    _ = t.handle(.pageup, n, vis); // already at the top, stays
    try testing.expectEqual(@as(usize, 0), t.highlighted);
}

test "Table scrolls to keep the selection in the window" {
    var t = Table{};
    const n = 6;
    const vis = 3;
    for (0..4) |_| _ = t.handle(.down, n, vis); // selection 4
    try testing.expectEqual(@as(usize, 4), t.highlighted);
    try testing.expectEqual(@as(usize, 2), t.scroll); // window [2,5) shows it
    for (0..3) |_| _ = t.handle(.up, n, vis); // back to 1
    try testing.expectEqual(@as(usize, 1), t.highlighted);
    try testing.expectEqual(@as(usize, 1), t.scroll); // window slid up to [1,4)
    _ = t.handle(.pagedown, n, vis); // 1 -> 4, window slides to keep it in view
    try testing.expectEqual(@as(usize, 4), t.highlighted);
    try testing.expectEqual(@as(usize, 2), t.scroll);
}

test "Table rowAt maps a click through the header offset and scroll window" {
    // A table rendered at surface rect y=4, height 9 (1 header + 8 body rows).
    const rect = ui.Rect{ .x = 1, .y = 4, .w = 20, .h = 9 };

    var t = Table{}; // scroll 0
    // The header row (rect.y) is not a body row.
    try testing.expectEqual(@as(?usize, null), t.rowAt(rect, 4));
    // The first body row (rect.y + header) maps to row 0 — NOT row 1. This is the
    // off-by-one the fullscreen demo hit: a naive `y - rect.y` would return 1.
    try testing.expectEqual(@as(?usize, 0), t.rowAt(rect, 5));
    try testing.expectEqual(@as(?usize, 1), t.rowAt(rect, 6));
    // Last visible body row (rect.y + h - 1); one past the rect is a miss.
    try testing.expectEqual(@as(?usize, 7), t.rowAt(rect, 12));
    try testing.expectEqual(@as(?usize, null), t.rowAt(rect, 13));
    // Above the table is a miss (no underflow).
    try testing.expectEqual(@as(?usize, null), t.rowAt(rect, 0));

    // Scrolled: the same click rows map through the window top.
    t.scroll = 20;
    try testing.expectEqual(@as(?usize, 20), t.rowAt(rect, 5)); // first body → scroll+0
    try testing.expectEqual(@as(?usize, 27), t.rowAt(rect, 12)); // last body → scroll+7
    try testing.expectEqual(@as(?usize, null), t.rowAt(rect, 4)); // still the header
}

test "Table rowAt hit-tests against the scroll view derived (not the stale one)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 30 rows, one column. Enough to scroll a small window well down the list.
    const grid = try a.alloc([]const []const u8, 30);
    for (grid, 0..) |*row, i| {
        const cell = try std.fmt.allocPrint(a, "{d}", .{i});
        row.* = try a.dupe([]const u8, &.{cell});
    }
    const cols = [_]Table.Column{.{ .header = "N" }};

    // The documented case `view`'s re-derive exists for: a caller sets `highlighted`
    // directly (here row 25), leaving the persistent `scroll` at its stale 0. Before
    // the fix, `rowAt` mapped the first body click through scroll=0 → row 0, while the
    // frame actually painted rows 18-25 (scrollFor(0, 25, 8, 30) == 18).
    var t = Table{};
    t.highlighted = 25;

    var s = try ui.Surface.init(testing.allocator, 4, 10);
    defer s.deinit();
    // Rendering derives the window and writes it back to `self.scroll`.
    try renderNode(a, try t.view(a, .{ .focused = true, .columns = &cols, .rows = grid, .height = 8 }), &s);
    try testing.expectEqual(@as(usize, 18), t.scroll);

    // The table rect matches what was painted: 1 header + 8 body rows at y=4.
    const rect = ui.Rect{ .x = 0, .y = 4, .w = 4, .h = 1 + 8 };
    // The first body click now maps to the window top (18), not the stale 0.
    try testing.expectEqual(@as(?usize, 18), t.rowAt(rect, 5));
    // ...and the highlighted row (25) sits at the bottom of the painted window.
    try testing.expectEqual(@as(?usize, 25), t.rowAt(rect, 12));
}

// ---- handle: Button --------------------------------------------------------

test "Button activates on Enter and Space, ignores other keys" {
    var b = Button{};
    // `handle` returns *consumed* (the uniform contract); a Button consumes
    // exactly the keys that fire it, and exposes firing as `activated` state.
    try testing.expect(b.handle(.enter));
    try testing.expect(b.activated);
    try testing.expect(b.handle(.{ .char = ' ' }));
    try testing.expect(b.activated);
    // A non-activating key bubbles (so Tab still navigates off the button) and
    // clears `activated` — it is momentary, refreshed by each `handle`.
    try testing.expect(!b.handle(.tab));
    try testing.expect(!b.activated);
    try testing.expect(!b.handle(.{ .char = 'x' }));
    try testing.expect(!b.activated);
    try testing.expect(!b.handle(.left));
    try testing.expect(!b.activated);
}

// ---- handle: Tabs ----------------------------------------------------------

test "Tabs arrows move the active tab, wrapping at both ends" {
    var tabs = Tabs{};
    const n = 3;
    try testing.expect(tabs.handle(.right, n));
    try testing.expectEqual(@as(usize, 1), tabs.active);
    _ = tabs.handle(.right, n);
    try testing.expectEqual(@as(usize, 2), tabs.active);
    _ = tabs.handle(.right, n); // wrap forward: 2 -> 0
    try testing.expectEqual(@as(usize, 0), tabs.active);
    _ = tabs.handle(.left, n); // wrap backward: 0 -> 2
    try testing.expectEqual(@as(usize, 2), tabs.active);
    _ = tabs.handle(.left, n);
    try testing.expectEqual(@as(usize, 1), tabs.active);
}

test "Tabs number keys jump directly, ignoring out-of-range digits" {
    var tabs = Tabs{};
    const n = 3;
    try testing.expect(tabs.handle(.{ .char = '3' }, n)); // -> index 2
    try testing.expectEqual(@as(usize, 2), tabs.active);
    try testing.expect(tabs.handle(.{ .char = '1' }, n)); // -> index 0
    try testing.expectEqual(@as(usize, 0), tabs.active);
    // '4' has no tab (only 3), so it bubbles and leaves the active index alone.
    try testing.expect(!tabs.handle(.{ .char = '4' }, n));
    try testing.expectEqual(@as(usize, 0), tabs.active);
    // '0' is not a tab shortcut (tabs are 1-indexed on the keyboard).
    try testing.expect(!tabs.handle(.{ .char = '0' }, n));
    try testing.expectEqual(@as(usize, 0), tabs.active);
}

test "Tabs never consumes Tab and bubbles other keys" {
    var tabs = Tabs{ .active = 1 };
    const n = 3;
    // Tab stays reserved for the focus ring — the bar never eats it.
    try testing.expect(!tabs.handle(.tab, n));
    try testing.expect(!tabs.handle(.back_tab, n));
    try testing.expect(!tabs.handle(.enter, n));
    try testing.expect(!tabs.handle(.{ .char = 'x' }, n));
    try testing.expectEqual(@as(usize, 1), tabs.active); // none of them moved it
}

test "Tabs handles the count==0 and count==1 edge cases" {
    var tabs = Tabs{};
    // No tabs: every key bubbles and nothing moves.
    try testing.expect(!tabs.handle(.right, 0));
    try testing.expect(!tabs.handle(.left, 0));
    try testing.expect(!tabs.handle(.{ .char = '1' }, 0));
    try testing.expectEqual(@as(usize, 0), tabs.active);
    // One tab: arrows are consumed but wrap back to the only tab; '1' selects it.
    try testing.expect(tabs.handle(.right, 1));
    try testing.expectEqual(@as(usize, 0), tabs.active);
    try testing.expect(tabs.handle(.left, 1));
    try testing.expectEqual(@as(usize, 0), tabs.active);
    try testing.expect(tabs.handle(.{ .char = '1' }, 1));
    try testing.expectEqual(@as(usize, 0), tabs.active);
    try testing.expect(!tabs.handle(.{ .char = '2' }, 1));
}

// ---- focus helpers ---------------------------------------------------------

test "focusNext and focusPrev wrap around" {
    const F = enum { a, b, c };
    try testing.expectEqual(F.b, widgets.focusNext(F, .a));
    try testing.expectEqual(F.a, widgets.focusNext(F, .c)); // wrap
    try testing.expectEqual(F.c, widgets.focusPrev(F, .a)); // wrap
    try testing.expectEqual(F.a, widgets.focusPrev(F, .b));
}

// ---- FocusRing (ADR-0021 incr 4) ------------------------------------------

// A form-shaped state mixing widget fields (types with `handle`) and plain
// data — the ring derivation must pick only the widgets. Buffers for the text
// field are inline so no allocation is needed.
const RingState = struct {
    user_buf: [16]u8 = undefined,
    user: TextInput = .{ .buffer = &.{} },
    label: []const u8 = "x", // plain data — not a widget
    role: Select = .{}, // multi-arg handle(key, count, visible)
    remember: Checkbox = .{},
    submit: Button = .{},
    focus: usize = 0, // held as an index (can't be Ring.Focus — circular)

    fn wire(self: *RingState) void {
        self.user.buffer = &self.user_buf;
    }
};

const Ring = widgets.FocusRing(RingState);

test "FocusRing derivation skips non-widget fields" {
    // Only the four `handle`-bearing fields join the ring, in declaration order;
    // `user_buf`, `label`, and `focus` are skipped.
    try testing.expectEqual(@as(usize, 4), Ring.ring.len);
    try testing.expectEqualStrings("user", Ring.ring[0]);
    try testing.expectEqualStrings("role", Ring.ring[1]);
    try testing.expectEqualStrings("remember", Ring.ring[2]);
    try testing.expectEqualStrings("submit", Ring.ring[3]);
    // The reified enum's tags match the field names and their indices.
    try testing.expectEqual(@as(usize, 0), @intFromEnum(Ring.Focus.user));
    try testing.expectEqual(@as(usize, 3), @intFromEnum(Ring.Focus.submit));
}

test "FocusRing next/prev wrap over the ring" {
    try testing.expectEqual(Ring.Focus.role, Ring.next(.user));
    try testing.expectEqual(Ring.Focus.user, Ring.next(.submit)); // wrap
    try testing.expectEqual(Ring.Focus.submit, Ring.prev(.user)); // wrap
    try testing.expectEqual(Ring.Focus.remember, Ring.prev(.submit));
}

// `extras` must describe *every* multi-arg widget field (here `role`), because
// `dispatch`'s `inline for` compiles all arms regardless of the runtime focus.
const ring_extras = .{ .role = .{ @as(usize, 3), @as(u16, 4) } };

test "FocusRing.dispatch routes to the focused widget and mutates it" {
    var st = RingState{};
    st.wire();

    // A char goes to the focused TextInput.
    try testing.expect(Ring.dispatch(&st, .user, .{ .char = 'a' }, ring_extras));
    try testing.expectEqualStrings("a", st.user.value());

    // With `role` focused, ↓ moves the Select's highlight — proving the extras
    // (count/visible) reached the multi-arg widget.
    try testing.expectEqual(@as(usize, 0), st.role.highlighted);
    try testing.expect(Ring.dispatch(&st, .role, .down, ring_extras));
    try testing.expectEqual(@as(usize, 1), st.role.highlighted);
    // The TextInput is untouched — dispatch routed only to `role`.
    try testing.expectEqualStrings("a", st.user.value());
}

test "FocusRing.dispatch returns the handle's bool" {
    var st = RingState{};
    st.wire();

    // Checkbox consumes Space (toggles) but bubbles an unrelated key.
    try testing.expect(Ring.dispatch(&st, .remember, .{ .char = ' ' }, ring_extras));
    try testing.expect(st.remember.checked);
    try testing.expect(!Ring.dispatch(&st, .remember, .tab, ring_extras));

    // Button arm: Enter is consumed and sets `activated` (the caller reads that
    // to submit), Tab bubbles (false → navigation). dispatch returns *consumed*.
    try testing.expect(Ring.dispatch(&st, .submit, .enter, ring_extras));
    try testing.expect(st.submit.activated);
    try testing.expect(!Ring.dispatch(&st, .submit, .tab, ring_extras));
    try testing.expect(!st.submit.activated);
}

// ---- view: rendering onto a surface ---------------------------------------

fn rowString(a: std.mem.Allocator, s: *ui.Surface, y: u16) ![]u8 {
    var list = std.ArrayList(u8).empty;
    var x: u16 = 0;
    while (x < s.width) : (x += 1) {
        const c = s.cell(x, y);
        if (c.isContinuation()) continue;
        if (c.text_len == 0) try list.append(a, ' ') else try list.appendSlice(a, s.cellText(c));
    }
    return list.items;
}

fn renderNode(a: std.mem.Allocator, n: ui.Node, s: *ui.Surface) !void {
    const rctx = ui.RenderCtx{ .allocator = a };
    try ui.render(&rctx, &n, s.root());
}

test "focused TextInput shows the caret as a reverse cell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [16]u8 = undefined;
    var ti = TextInput{ .buffer = &buf };
    for ("hi") |c| _ = ti.handle(.{ .char = c }); // cursor at end (col 2)

    var s = try ui.Surface.init(testing.allocator, 6, 1);
    defer s.deinit();
    try renderNode(a, try ti.view(a, .{ .focused = true }), &s);

    try testing.expectEqualStrings("hi    ", try rowString(a, &s, 0));
    try testing.expect(s.cell(2, 0).style.reverse); // caret rests past the text
    try testing.expect(!s.cell(0, 0).style.reverse);
}

test "unfocused TextInput paints no caret" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [16]u8 = undefined;
    var ti = TextInput{ .buffer = &buf };
    for ("hi") |c| _ = ti.handle(.{ .char = c });

    var s = try ui.Surface.init(testing.allocator, 6, 1);
    defer s.deinit();
    try renderNode(a, try ti.view(a, .{ .focused = false }), &s);
    try testing.expect(!s.cell(2, 0).style.reverse);
}

test "masked TextInput renders the mask glyph, not the text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [16]u8 = undefined;
    var ti = TextInput{ .buffer = &buf, .mask = '*' };
    for ("pw") |c| _ = ti.handle(.{ .char = c });

    var s = try ui.Surface.init(testing.allocator, 6, 1);
    defer s.deinit();
    try renderNode(a, try ti.view(a, .{ .focused = true }), &s);
    try testing.expectEqualStrings("**    ", try rowString(a, &s, 0));
}

test "empty TextInput shows its placeholder" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [16]u8 = undefined;
    var ti = TextInput{ .buffer = &buf };

    var s = try ui.Surface.init(testing.allocator, 8, 1);
    defer s.deinit();
    try renderNode(a, try ti.view(a, .{ .placeholder = "name" }), &s);
    try testing.expectEqualStrings("name    ", try rowString(a, &s, 0));
}

test "TextArea paints wrapped multi-line content and reports the caret cell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [64]u8 = undefined;
    var ta = TextArea{ .buffer = &buf };
    // "aaa bbb ccc" wraps at width 6 → "aaa" / "bbb" / "ccc". Cursor after "bbb".
    for ("aaa bbb ccc") |c| _ = ta.handle(.{ .char = c }, 6, 4);
    _ = ta.handle(.up, 6, 4); // to "bbb", end → offset 7

    var s = try ui.Surface.init(testing.allocator, 6, 4);
    defer s.deinit();
    var caret: ?ui.Point = null;
    try renderNode(a, try ta.view(a, .{ .focused = true, .width = .{ .len = 6 }, .height = 4, .cursor_out = &caret }), &s);

    try testing.expectEqualStrings("aaa   ", try rowString(a, &s, 0));
    try testing.expectEqualStrings("bbb   ", try rowString(a, &s, 1));
    try testing.expectEqualStrings("ccc   ", try rowString(a, &s, 2));
    // Caret sits at the end of the "bbb" visual row (col 3, row 1).
    try testing.expectEqual(@as(?ui.Point, .{ .x = 3, .y = 1 }), caret);
}

test "TextArea scrolls to keep the caret's row visible" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [64]u8 = undefined;
    var ta = TextArea{ .buffer = &buf };
    // Six single-glyph lines "0".."5", a 3-row window; cursor on the last row.
    for (0..6) |i| {
        _ = ta.handle(.{ .char = @intCast('0' + i) }, 8, 3);
        if (i < 5) _ = ta.handle(.enter, 8, 3);
    }

    var s = try ui.Surface.init(testing.allocator, 8, 3);
    defer s.deinit();
    var caret: ?ui.Point = null;
    try renderNode(a, try ta.view(a, .{ .focused = true, .width = .{ .len = 8 }, .height = 3, .cursor_out = &caret }), &s);

    // Window slid to the bottom three rows [3,6): "3","4","5".
    try testing.expectEqualStrings("3       ", try rowString(a, &s, 0));
    try testing.expectEqualStrings("4       ", try rowString(a, &s, 1));
    try testing.expectEqualStrings("5       ", try rowString(a, &s, 2));
    try testing.expectEqual(@as(?ui.Point, .{ .x = 1, .y = 2 }), caret); // last row, past "5"
}

test "empty TextArea shows its placeholder in hint style" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [16]u8 = undefined;
    var ta = TextArea{ .buffer = &buf };

    var s = try ui.Surface.init(testing.allocator, 10, 3);
    defer s.deinit();
    try renderNode(a, try ta.view(a, .{ .placeholder = "notes...", .width = .{ .len = 10 }, .height = 3 }), &s);
    try testing.expectEqualStrings("notes...  ", try rowString(a, &s, 0));
    // Placeholder wears the hint style, not the default.
    try testing.expect(!ui.styleEql(s.cell(0, 0).style, .{}));
}

test "unfocused TextArea (cursor_out null) paints no reverse caret" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [16]u8 = undefined;
    var ta = TextArea{ .buffer = &buf };
    for ("hi") |c| _ = ta.handle(.{ .char = c }, 10, 3);

    var s = try ui.Surface.init(testing.allocator, 10, 3);
    defer s.deinit();
    try renderNode(a, try ta.view(a, .{ .focused = false, .width = .{ .len = 10 }, .height = 3 }), &s);
    try testing.expect(!s.cell(2, 0).style.reverse);
}

test "focused TextArea with no cursor_out paints a reverse block caret" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [16]u8 = undefined;
    var ta = TextArea{ .buffer = &buf };
    for ("hi") |c| _ = ta.handle(.{ .char = c }, 10, 3);

    var s = try ui.Surface.init(testing.allocator, 10, 3);
    defer s.deinit();
    // No cursor_out → fall back to the reverse block caret at the caret cell.
    try renderNode(a, try ta.view(a, .{ .focused = true, .width = .{ .len = 10 }, .height = 3 }), &s);
    try testing.expect(s.cell(2, 0).style.reverse); // past "hi"
}

test "Checkbox renders its box and label, checked and focused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cb = Checkbox{ .checked = true };
    var s = try ui.Surface.init(testing.allocator, 12, 1);
    defer s.deinit();
    try renderNode(a, try cb.view(a, .{ .focused = true, .label = "on" }), &s);
    try testing.expectEqualStrings("[x] on      ", try rowString(a, &s, 0));
}

const menu_options = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo" };

test "focused Select marks and styles the highlighted row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var sel = Select{};
    _ = sel.handle(.down, menu_options.len, 3); // highlight 1 (bravo)

    var s = try ui.Surface.init(testing.allocator, 10, 3);
    defer s.deinit();
    try renderNode(a, try sel.view(a, .{ .focused = true, .options = &menu_options, .height = 3 }), &s);

    // Window [0,3): the highlight wears the cursor marker; the others don't.
    // The list runs past the window, so the bottom row carries a ↓.
    try testing.expectEqualStrings("  alpha   ", try rowString(a, &s, 0));
    try testing.expectEqualStrings("› bravo   ", try rowString(a, &s, 1));
    try testing.expectEqualStrings("  charlie↓", try rowString(a, &s, 2));
    // The highlighted row is styled (selected token); the others are plain.
    try testing.expect(!ui.styleEql(s.cell(0, 1).style, .{}));
    try testing.expect(ui.styleEql(s.cell(0, 0).style, .{}));
}

test "unfocused Select drops the marker but keeps the highlight prominent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var sel = Select{};
    _ = sel.handle(.down, menu_options.len, 3); // highlight bravo

    var s = try ui.Surface.init(testing.allocator, 10, 3);
    defer s.deinit();
    try renderNode(a, try sel.view(a, .{ .focused = false, .options = &menu_options, .height = 3 }), &s);
    try testing.expectEqualStrings("  bravo   ", try rowString(a, &s, 1));
    // Unfocused, the current option still reads as chosen — it wears the
    // `selected` token, not a dimmer one, so it never looks less prominent than
    // its neighbours.
    const t = theme_mod.default_theme;
    const selected = t.prompts.selected.resolve(t.palette);
    try testing.expect(ui.styleEql(s.cell(0, 1).style, selected));
    try testing.expect(ui.styleEql(s.cell(0, 0).style, .{})); // a neighbour is plain
}

test "Select view slides the window to the highlight" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var sel = Select{};
    for (0..4) |_| _ = sel.handle(.down, menu_options.len, 3); // highlight 4 (echo)

    var s = try ui.Surface.init(testing.allocator, 10, 3);
    defer s.deinit();
    try renderNode(a, try sel.view(a, .{ .focused = true, .options = &menu_options, .height = 3 }), &s);

    // Window slid to [2,5): charlie, delta, echo (highlighted). More options sit
    // above the window now, so the top row carries a ↑ (and none below).
    try testing.expectEqualStrings("  charlie↑", try rowString(a, &s, 0));
    try testing.expectEqualStrings("  delta   ", try rowString(a, &s, 1));
    try testing.expectEqualStrings("› echo    ", try rowString(a, &s, 2));
}

test "Select shows both overflow arrows mid-list, and none when it fits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Highlight 3 with a 3-row window over 5 → scroll 1, window [1,4): bravo,
    // charlie, delta (delta highlighted). Hidden options both above and below,
    // so the top row carries ↑ and the bottom row ↓. Surface is label_w+1 wide.
    var sel = Select{};
    for (0..3) |_| _ = sel.handle(.down, menu_options.len, 3);
    var s = try ui.Surface.init(testing.allocator, 10, 3);
    defer s.deinit();
    try renderNode(a, try sel.view(a, .{ .focused = true, .options = &menu_options, .height = 3 }), &s);
    try testing.expectEqualStrings("  bravo  ↑", try rowString(a, &s, 0));
    try testing.expectEqualStrings("  charlie ", try rowString(a, &s, 1));
    try testing.expectEqualStrings("› delta  ↓", try rowString(a, &s, 2));

    // A list that fits its window carries no arrows (surface = label_w+1 = 6).
    var sel2 = Select{};
    var s2 = try ui.Surface.init(testing.allocator, 6, 3);
    defer s2.deinit();
    const two = [_][]const u8{ "one", "two" };
    try renderNode(a, try sel2.view(a, .{ .focused = true, .options = &two, .height = 3 }), &s2);
    try testing.expectEqualStrings("› one ", try rowString(a, &s2, 0));
    try testing.expectEqualStrings("  two ", try rowString(a, &s2, 1));
}

test "Select scrollbar replaces the overflow arrows with a thumb gutter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Same window as the arrows test (scroll 1, [1,4)) but with the scrollbar on:
    // the gutter carries a │ on every row (no ↑/↓ arrows), and the thumb cells wear
    // the `surface.border` style while the track cells wear `prompts.hint`.
    var sel = Select{};
    for (0..3) |_| _ = sel.handle(.down, menu_options.len, 3);
    var s = try ui.Surface.init(testing.allocator, 10, 3);
    defer s.deinit();
    const th = theme_mod.appTheme();
    try renderNode(a, try sel.view(a, .{ .focused = true, .options = &menu_options, .height = 3, .scrollbar = true }), &s);

    // Every gutter row is a │ — the arrows are gone.
    for (0..3) |y| try testing.expectEqualStrings("│", s.cellText(s.cell(9, @intCast(y))));
    // 5 options, 3 visible → thumb len round(3*3/5)=2, scroll 1 of max 2 → start
    // round(1*1/2)=1: track row 0, thumb rows 1-2. Styles distinguish them.
    const track = th.prompts.hint.resolve(th.palette);
    const thumb = th.surface.border.resolve(th.palette);
    try testing.expect(ui.styleEql(s.cell(9, 0).style, track));
    try testing.expect(ui.styleEql(s.cell(9, 1).style, thumb));
    try testing.expect(ui.styleEql(s.cell(9, 2).style, thumb));
}

test "Table scrollbar draws a thumb gutter over the body, not the header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const columns = [_]Table.Column{
        .{ .header = "N", .width = .{ .len = 1 } },
    };
    const grid = [_][]const []const u8{
        &.{"a"}, &.{"b"}, &.{"c"}, &.{"d"}, &.{"e"},
    };
    var t = Table{};
    var s = try ui.Surface.init(testing.allocator, 4, 4); // header + 3 body rows
    defer s.deinit();
    const th = theme_mod.appTheme();
    try renderNode(a, try t.view(a, .{ .focused = true, .columns = &columns, .rows = &grid, .height = 3, .scrollbar = true }), &s);

    // Row 0 is the header: its gutter cell is blank, not a scrollbar glyph.
    try testing.expect(s.cell(3, 0).text_len == 0);
    // Rows 1..3 are the scrolling body: each gutter cell is a │.
    for (1..4) |y| try testing.expectEqualStrings("│", s.cellText(s.cell(3, @intCast(y))));
    // 5 rows, 3 visible, at top (scroll 0) → thumb len 2 at start 0, track below.
    const thumb = th.surface.border.resolve(th.palette);
    const track = th.prompts.hint.resolve(th.palette);
    try testing.expect(ui.styleEql(s.cell(3, 1).style, thumb));
    try testing.expect(ui.styleEql(s.cell(3, 3).style, track));
}

test "Select truncates an option too wide for the granted width" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var sel = Select{};
    const one = [_][]const u8{"development"};
    var s = try ui.Surface.init(testing.allocator, 8, 1);
    defer s.deinit();
    try renderNode(a, try sel.view(a, .{ .options = &one, .height = 1 }), &s);
    const row = try rowString(a, &s, 0);
    try testing.expect(std.mem.indexOf(u8, row, "…") != null);
}

// A long option wraps to two physical rows at label width 7 (surface 10 wide:
// 2 marker cols + 7 label + 1 gutter): "hello" then "world".
const wrap_options = [_][]const u8{ "hello world", "beta", "gamma", "delta" };

test "wrapped Select hangs a multi-row option under its label" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var sel = Select{};
    const one = [_][]const u8{"hello world"};
    var s = try ui.Surface.init(testing.allocator, 10, 4);
    defer s.deinit();
    try renderNode(a, try sel.view(a, .{ .focused = true, .options = &one, .height = 4, .wrap = true }), &s);

    // The label wraps; the continuation line keeps the hang indent (its marker
    // cell stays blank), and the whole block wears the selected style.
    try testing.expectEqualStrings("› hello   ", try rowString(a, &s, 0));
    try testing.expectEqualStrings("  world   ", try rowString(a, &s, 1));
    const t = theme_mod.default_theme;
    const selected = t.prompts.selected.resolve(t.palette);
    try testing.expect(ui.styleEql(s.cell(2, 0).style, selected));
    try testing.expect(ui.styleEql(s.cell(2, 1).style, selected)); // continuation too
}

test "wrapped Select budgets physical rows and shows a down arrow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Budget 3: the 2-row highlighted option plus one more fills it; the rest are
    // hidden below, so the last row carries a ↓.
    var sel = Select{};
    var s = try ui.Surface.init(testing.allocator, 10, 4);
    defer s.deinit();
    try renderNode(a, try sel.view(a, .{ .focused = true, .options = &wrap_options, .height = 3, .wrap = true }), &s);

    try testing.expectEqualStrings("› hello   ", try rowString(a, &s, 0));
    try testing.expectEqualStrings("  world   ", try rowString(a, &s, 1));
    try testing.expectEqualStrings("  beta   ↓", try rowString(a, &s, 2));
    try testing.expectEqualStrings("          ", try rowString(a, &s, 3)); // past the budget
    // The highlighted block is styled; a neighbour below it is plain.
    const t = theme_mod.default_theme;
    const selected = t.prompts.selected.resolve(t.palette);
    try testing.expect(ui.styleEql(s.cell(2, 1).style, selected));
    try testing.expect(ui.styleEql(s.cell(2, 2).style, .{}));
}

test "wrapped Select grows the window upward with an up arrow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Highlight the last option: the window grows up from it (single-row options
    // above), the highlight sits on the bottom row, and hidden options above put
    // a ↑ on the top row.
    var sel = Select{ .highlighted = 3 };
    var s = try ui.Surface.init(testing.allocator, 10, 3);
    defer s.deinit();
    try renderNode(a, try sel.view(a, .{ .focused = true, .options = &wrap_options, .height = 3, .wrap = true }), &s);

    try testing.expectEqualStrings("  beta   ↑", try rowString(a, &s, 0));
    try testing.expectEqualStrings("  gamma   ", try rowString(a, &s, 1));
    try testing.expectEqualStrings("› delta   ", try rowString(a, &s, 2));
}

test "wrapped Select shows both arrows on a single-row window" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const abc = [_][]const u8{ "a", "b", "c" };
    var sel = Select{ .highlighted = 1 };
    var s = try ui.Surface.init(testing.allocator, 10, 1);
    defer s.deinit();
    try renderNode(a, try sel.view(a, .{ .focused = true, .options = &abc, .height = 1, .wrap = true }), &s);

    // One physical row with options hidden both above and below → a merged ↕.
    try testing.expectEqualStrings("› b      ↕", try rowString(a, &s, 0));
}

// ---- view: Table -----------------------------------------------------------

const tbl_columns = [_]Table.Column{
    .{ .header = "ID", .width = .fit },
    .{ .header = "NAME", .width = .fit },
};
const tbl_rows = [_][]const []const u8{
    &.{ "1", "alpha" },
    &.{ "2", "bravo" },
    &.{ "33", "charlie" },
    &.{ "4", "delta" },
    &.{ "5", "echo" },
};

test "Table renders a header band over aligned .fit columns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t = Table{};
    // Surface 11 wide: ID(.fit=2) + gap + NAME(.fit=7) = 10 body cells + 1 gutter.
    var s = try ui.Surface.init(testing.allocator, 11, 6);
    defer s.deinit();
    try renderNode(a, try t.view(a, .{ .focused = true, .columns = &tbl_columns, .rows = &tbl_rows, .height = 3 }), &s);

    // Header row in hint style, columns aligned; the gutter trails blank on it.
    try testing.expectEqualStrings("ID NAME    ", try rowString(a, &s, 0));
    const th = theme_mod.default_theme;
    const hint = th.prompts.hint.resolve(th.palette);
    try testing.expect(ui.styleEql(s.cell(0, 0).style, hint));
    // Body rows follow, column-aligned under the header. Scroll is 0, so the
    // first body row has a blank gutter (nothing hidden above it).
    try testing.expectEqualStrings("1  alpha   ", try rowString(a, &s, 1));
    // The list overflows the 3-row window, so the last visible body row carries ↓.
    try testing.expectEqualStrings("33 charlie↓", try rowString(a, &s, 3));
}

test "Table highlights the selected row as a full-width band" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t = Table{};
    _ = t.handle(.down, tbl_rows.len, 3); // select row 1 (bravo)

    var s = try ui.Surface.init(testing.allocator, 11, 6);
    defer s.deinit();
    try renderNode(a, try t.view(a, .{ .focused = true, .columns = &tbl_columns, .rows = &tbl_rows, .height = 3 }), &s);

    // Row 2 of the surface is body row 1 (bravo), highlighted.
    const th = theme_mod.default_theme;
    const selected = th.prompts.selected.resolve(th.palette);
    // The band spans the cells AND the gap between them (a full-width band), not
    // just the styled text — the cell at the inter-column gap wears it too.
    try testing.expect(ui.styleEql(s.cell(0, 2).style, selected)); // ID cell
    try testing.expect(ui.styleEql(s.cell(2, 2).style, selected)); // gap between columns
    try testing.expect(ui.styleEql(s.cell(3, 2).style, selected)); // NAME cell
    // A neighbouring (unselected) body row is plain.
    try testing.expect(ui.styleEql(s.cell(0, 1).style, .{}));
}

test "Table shows overflow arrows and slides its window" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t = Table{};
    for (0..4) |_| _ = t.handle(.down, tbl_rows.len, 3); // select 4 (echo), scroll 2

    var s = try ui.Surface.init(testing.allocator, 11, 4);
    defer s.deinit();
    try renderNode(a, try t.view(a, .{ .focused = true, .columns = &tbl_columns, .rows = &tbl_rows, .height = 3 }), &s);

    // Header, then window [2,5): charlie, delta, echo. Rows hidden above → the
    // top body row carries ↑ (and nothing below, echo is the last row).
    try testing.expectEqualStrings("ID NAME    ", try rowString(a, &s, 0));
    try testing.expectEqualStrings("33 charlie↑", try rowString(a, &s, 1));
    try testing.expectEqualStrings("4  delta   ", try rowString(a, &s, 2));
    try testing.expectEqualStrings("5  echo    ", try rowString(a, &s, 3));
}

test "Table truncates a cell too wide for its column" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t = Table{};
    const cols = [_]Table.Column{.{ .header = "NAME", .width = .{ .len = 4 } }};
    const rows = [_][]const []const u8{&.{"development"}};
    var s = try ui.Surface.init(testing.allocator, 6, 2);
    defer s.deinit();
    try renderNode(a, try t.view(a, .{ .columns = &cols, .rows = &rows, .height = 1 }), &s);
    const row = try rowString(a, &s, 1);
    try testing.expect(std.mem.indexOf(u8, row, "…") != null);
}

test "Table renders an empty grid as just its header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t = Table{};
    const empty: []const []const []const u8 = &.{};
    var s = try ui.Surface.init(testing.allocator, 11, 3);
    defer s.deinit();
    // No rows: the header still draws, no body, and no crash (division by zero,
    // out-of-range highlight, etc.).
    try renderNode(a, try t.view(a, .{ .columns = &tbl_columns, .rows = empty, .height = 3 }), &s);
    try testing.expectEqualStrings("ID NAME    ", try rowString(a, &s, 0));
    try testing.expectEqualStrings("           ", try rowString(a, &s, 1)); // blank body
}

test "Button renders its label and styles the focused state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var b = Button{};
    var s = try ui.Surface.init(testing.allocator, 12, 1);
    defer s.deinit();
    try renderNode(a, try b.view(a, .{ .focused = true, .label = "OK" }), &s);
    try testing.expectEqualStrings("[ OK ]      ", try rowString(a, &s, 0));
    try testing.expect(!ui.styleEql(s.cell(0, 0).style, .{})); // focused → styled

    s.clear();
    try renderNode(a, try b.view(a, .{ .focused = false, .label = "OK" }), &s);
    try testing.expect(ui.styleEql(s.cell(0, 0).style, .{})); // unfocused → plain
}

test "Tabs renders labels with the active one styled apart from the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const labels = [_][]const u8{ "One", "Two", "Three" };
    var tabs = Tabs{ .active = 1 };
    var s = try ui.Surface.init(testing.allocator, 20, 1);
    defer s.deinit();
    try renderNode(a, try tabs.view(a, .{ .labels = &labels }), &s);

    // Labels sit in a row with a single-space gap between them.
    try testing.expectEqualStrings("One Two Three       ", try rowString(a, &s, 0));

    const th = theme_mod.default_theme;
    const selected = th.prompts.selected.resolve(th.palette);
    const hint = th.prompts.hint.resolve(th.palette);
    // Active tab ("Two", starting at column 4) wears `selected`; the inactive
    // tabs ("One" at 0, "Three" at 8) wear `hint`.
    try testing.expect(ui.styleEql(s.cell(4, 0).style, selected)); // Two
    try testing.expect(ui.styleEql(s.cell(0, 0).style, hint)); // One
    try testing.expect(ui.styleEql(s.cell(8, 0).style, hint)); // Three
    // The active and inactive styles are distinguishable (the whole point).
    try testing.expect(!ui.styleEql(selected, hint));
}

// ---- TextInput hardware-cursor reporting (ADR-0019) -----------------------

test "focused TextInput reports its caret and suppresses the block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [16]u8 = undefined;
    var ti = TextInput{ .buffer = &buf };
    for ("hi") |c| _ = ti.handle(.{ .char = c }); // caret at col 2

    var caret: ?ui.Point = null;
    var s = try ui.Surface.init(testing.allocator, 6, 1);
    defer s.deinit();
    try renderNode(a, try ti.view(a, .{ .focused = true, .cursor_out = &caret }), &s);

    try testing.expectEqual(ui.Point{ .x = 2, .y = 0 }, caret.?);
    // The real cursor goes there — no reverse-video block is painted.
    try testing.expect(!s.cell(2, 0).style.reverse);
}

test "TextInput caret reports the scrolled column" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [16]u8 = undefined;
    var ti = TextInput{ .buffer = &buf };
    for ("abcdef") |c| _ = ti.handle(.{ .char = c }); // caret at col 6

    var caret: ?ui.Point = null;
    var s = try ui.Surface.init(testing.allocator, 4, 1); // field only 4 wide → scrolls
    defer s.deinit();
    try renderNode(a, try ti.view(a, .{ .focused = true, .cursor_out = &caret }), &s);

    // cursor_col 6, width 4 → scroll 3 → caret visible at column 3.
    try testing.expectEqual(@as(u16, 3), caret.?.x);
}

test "TextInput caret stays aligned when scroll splits a wide grapheme" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [32]u8 = undefined;
    var ti = TextInput{ .buffer = &buf };
    // "a世界": 'a' at col 0, '世' at cols 1-2, '界' at cols 3-4 → cursor_col 5.
    for ([_]u21{ 'a', '世', '界' }) |c| _ = ti.handle(.{ .char = c });

    var caret: ?ui.Point = null;
    var s = try ui.Surface.init(testing.allocator, 4, 1); // width 4 → scroll 2
    defer s.deinit();
    try renderNode(a, try ti.view(a, .{ .focused = true, .cursor_out = &caret }), &s);

    // scroll 2 falls inside '世' (cols 1-2); it is stepped over whole, so the
    // painted left edge is '界' at actual column 3. The caret (cursor_col 5)
    // must anchor on that edge → column 2, in line with the drawn '界'.
    try testing.expectEqual(@as(u16, 2), caret.?.x);
    try testing.expectEqualStrings("界  ", try rowString(a, &s, 0));
}

test "unfocused TextInput reports no caret" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [16]u8 = undefined;
    var ti = TextInput{ .buffer = &buf };
    for ("hi") |c| _ = ti.handle(.{ .char = c });

    var caret: ?ui.Point = null;
    var s = try ui.Surface.init(testing.allocator, 6, 1);
    defer s.deinit();
    try renderNode(a, try ti.view(a, .{ .focused = false, .cursor_out = &caret }), &s);
    try testing.expect(caret == null);
}
