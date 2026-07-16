const std = @import("std");
const testing = std.testing;
const vterm = @import("../vterm.zig");
const VTerm = vterm.VTerm;

test "cursor movement" {
    var term = try VTerm.init(testing.allocator, 10, 5);
    defer term.deinit();

    term.moveCursor(5, 3);
    try testing.expectEqual(@as(u16, 5), term.cursor.x);
    try testing.expectEqual(@as(u16, 3), term.cursor.y);
}

test "cursor bounds clamping" {
    var term = try VTerm.init(testing.allocator, 10, 5);
    defer term.deinit();

    term.moveCursor(20, 10); // Out of bounds
    try testing.expectEqual(@as(u16, 9), term.cursor.x); // Clamped to width-1
    try testing.expectEqual(@as(u16, 4), term.cursor.y); // Clamped to height-1
}

test "cursor advancement" {
    var term = try VTerm.init(testing.allocator, 3, 2);
    defer term.deinit();

    term.putChar('A'); // (0,0) -> (1,0)
    term.putChar('B'); // (1,0) -> (2,0)
    term.putChar('C'); // (2,0) -> (0,1) - wrap to next line

    try testing.expectEqual(@as(u16, 0), term.cursor.x);
    try testing.expectEqual(@as(u16, 1), term.cursor.y);
}

// Regression tests for #504: absolute cursor addressing (CUP/CUU/CUD) must map
// viewport-relative rows to absolute logical lines once output has scrolled
// past one screen, otherwise writes land on scrolled-off lines the viewport
// never shows.

test "CUP home-and-repaint lands on viewport after scrolling (#504)" {
    var term = try VTerm.init(testing.allocator, 4, 2);
    defer term.deinit();

    // Four lines into a two-row viewport: the buffer scrolls, viewport row 0
    // is absolute line 2 ('c'), row 1 is line 3 ('d').
    term.write("a\nb\nc\nd");
    try testing.expectEqual(@as(u21, 'c'), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'd'), term.getCell(0, 1).char);

    // Home (ESC[1;1H) then write: 'Z' must land on viewport cell (0,0).
    term.write("\x1b[1;1H");
    term.write("Z");
    try testing.expectEqual(@as(u21, 'Z'), term.getCell(0, 0).char);
    // Row 1 is untouched.
    try testing.expectEqual(@as(u21, 'd'), term.getCell(0, 1).char);
}

test "CUU at scrolled bottom moves up one viewport row (#504)" {
    var term = try VTerm.init(testing.allocator, 4, 2);
    defer term.deinit();

    term.write("a\nb\nc\nd");
    // Cursor is on the bottom viewport row (line 3) at column 1 (after 'd').
    // ESC[A moves up one row but leaves the column unchanged.
    term.write("\x1b[A");
    try testing.expectEqual(@as(u16, 0), term.cursor.y);
    // The write lands on the top viewport row, at the current column.
    term.write("Z");
    try testing.expectEqual(@as(u21, 'Z'), term.getCell(1, 0).char);
    // The original 'c' in column 0 of that row is untouched.
    try testing.expectEqual(@as(u21, 'c'), term.getCell(0, 0).char);
}

test "CUP addressing unchanged before scrolling (#504)" {
    var term = try VTerm.init(testing.allocator, 4, 3);
    defer term.deinit();

    // Only two lines written into a three-row viewport: nothing scrolled.
    term.write("a\nb");
    term.write("\x1b[1;1H"); // home
    term.write("Z");
    try testing.expectEqual(@as(u21, 'Z'), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'b'), term.getCell(0, 1).char);
}
