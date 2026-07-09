//! Tests for the focusable input widgets (ADR-0018): `handle` as pure state
//! transitions (no terminal), and `view` painted onto a surface directly.

const std = @import("std");
const ui = @import("ui.zig");
const widgets = @import("widgets.zig");

const testing = std.testing;
const TextInput = widgets.TextInput;
const Checkbox = widgets.Checkbox;

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
