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

// ---- handle: Button --------------------------------------------------------

test "Button activates on Enter and Space, ignores other keys" {
    var b = Button{};
    try testing.expect(b.handle(.enter));
    try testing.expect(b.handle(.{ .char = ' ' }));
    // A non-activating key bubbles (so Tab still navigates off the button).
    try testing.expect(!b.handle(.tab));
    try testing.expect(!b.handle(.{ .char = 'x' }));
    try testing.expect(!b.handle(.left));
}

// ---- handle: Tabs ----------------------------------------------------------

test "Tabs arrows move the active tab, wrapping at both ends" {
    var tabs = Tabs{};
    var active: usize = 0;
    const n = 3;
    try testing.expect(tabs.handle(.right, &active, n));
    try testing.expectEqual(@as(usize, 1), active);
    _ = tabs.handle(.right, &active, n);
    try testing.expectEqual(@as(usize, 2), active);
    _ = tabs.handle(.right, &active, n); // wrap forward: 2 -> 0
    try testing.expectEqual(@as(usize, 0), active);
    _ = tabs.handle(.left, &active, n); // wrap backward: 0 -> 2
    try testing.expectEqual(@as(usize, 2), active);
    _ = tabs.handle(.left, &active, n);
    try testing.expectEqual(@as(usize, 1), active);
}

test "Tabs number keys jump directly, ignoring out-of-range digits" {
    var tabs = Tabs{};
    var active: usize = 0;
    const n = 3;
    try testing.expect(tabs.handle(.{ .char = '3' }, &active, n)); // -> index 2
    try testing.expectEqual(@as(usize, 2), active);
    try testing.expect(tabs.handle(.{ .char = '1' }, &active, n)); // -> index 0
    try testing.expectEqual(@as(usize, 0), active);
    // '4' has no tab (only 3), so it bubbles and leaves the active index alone.
    try testing.expect(!tabs.handle(.{ .char = '4' }, &active, n));
    try testing.expectEqual(@as(usize, 0), active);
    // '0' is not a tab shortcut (tabs are 1-indexed on the keyboard).
    try testing.expect(!tabs.handle(.{ .char = '0' }, &active, n));
    try testing.expectEqual(@as(usize, 0), active);
}

test "Tabs never consumes Tab and bubbles other keys" {
    var tabs = Tabs{};
    var active: usize = 1;
    const n = 3;
    // Tab stays reserved for the focus ring — the bar never eats it.
    try testing.expect(!tabs.handle(.tab, &active, n));
    try testing.expect(!tabs.handle(.back_tab, &active, n));
    try testing.expect(!tabs.handle(.enter, &active, n));
    try testing.expect(!tabs.handle(.{ .char = 'x' }, &active, n));
    try testing.expectEqual(@as(usize, 1), active); // none of them moved it
}

test "Tabs handles the count==0 and count==1 edge cases" {
    var tabs = Tabs{};
    var active: usize = 0;
    // No tabs: every key bubbles and nothing moves.
    try testing.expect(!tabs.handle(.right, &active, 0));
    try testing.expect(!tabs.handle(.left, &active, 0));
    try testing.expect(!tabs.handle(.{ .char = '1' }, &active, 0));
    try testing.expectEqual(@as(usize, 0), active);
    // One tab: arrows are consumed but wrap back to the only tab; '1' selects it.
    try testing.expect(tabs.handle(.right, &active, 1));
    try testing.expectEqual(@as(usize, 0), active);
    try testing.expect(tabs.handle(.left, &active, 1));
    try testing.expectEqual(@as(usize, 0), active);
    try testing.expect(tabs.handle(.{ .char = '1' }, &active, 1));
    try testing.expectEqual(@as(usize, 0), active);
    try testing.expect(!tabs.handle(.{ .char = '2' }, &active, 1));
}

// ---- focus helpers ---------------------------------------------------------

test "focusNext and focusPrev wrap around" {
    const F = enum { a, b, c };
    try testing.expectEqual(F.b, widgets.focusNext(F, .a));
    try testing.expectEqual(F.a, widgets.focusNext(F, .c)); // wrap
    try testing.expectEqual(F.c, widgets.focusPrev(F, .a)); // wrap
    try testing.expectEqual(F.a, widgets.focusPrev(F, .b));
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
    var tabs = Tabs{};
    var s = try ui.Surface.init(testing.allocator, 20, 1);
    defer s.deinit();
    try renderNode(a, try tabs.view(a, .{ .labels = &labels, .active = 1 }), &s);

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
