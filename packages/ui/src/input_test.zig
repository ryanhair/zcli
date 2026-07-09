//! Tests for the focusable input widgets (ADR-0018): `handle` as pure state
//! transitions (no terminal), and `view` painted onto a surface directly.

const std = @import("std");
const ui = @import("ui.zig");
const widgets = @import("widgets.zig");

const testing = std.testing;
const TextInput = widgets.TextInput;
const Checkbox = widgets.Checkbox;
const Select = widgets.Select;
const Button = widgets.Button;

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

test "unfocused Select drops the cursor marker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var sel = Select{};
    _ = sel.handle(.down, menu_options.len, 3);

    var s = try ui.Surface.init(testing.allocator, 10, 3);
    defer s.deinit();
    try renderNode(a, try sel.view(a, .{ .focused = false, .options = &menu_options, .height = 3 }), &s);
    try testing.expectEqualStrings("  bravo   ", try rowString(a, &s, 1));
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
