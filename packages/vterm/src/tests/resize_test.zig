const std = @import("std");
const testing = std.testing;
const vterm = @import("../vterm.zig");
const VTerm = vterm.VTerm;

test "resize larger" {
    var term = try VTerm.init(testing.allocator, 2, 2);
    defer term.deinit();

    // Fill original buffer
    term.putChar('A');
    term.putChar('B');
    term.moveCursor(0, 1);
    term.putChar('C');
    term.putChar('D');

    // Resize to 3x3
    try term.resize(3, 3);

    // Original content should be preserved
    try testing.expectEqual(@as(u21, 'A'), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'B'), term.getCell(1, 0).char);
    try testing.expectEqual(@as(u21, 'C'), term.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, 'D'), term.getCell(1, 1).char);

    // New cells should be empty
    try testing.expect(term.getCell(2, 0).isEmpty());
    try testing.expect(term.getCell(2, 1).isEmpty());
    try testing.expect(term.getCell(0, 2).isEmpty());
}

test "resize smaller" {
    var term = try VTerm.init(testing.allocator, 3, 3);
    defer term.deinit();

    term.moveCursor(2, 2);
    term.putChar('X');

    // Resize to 2x2
    try term.resize(2, 2);

    // Content outside new bounds should be lost
    try testing.expectEqual(@as(u16, 2), term.width);
    try testing.expectEqual(@as(u16, 2), term.height);

    // Cursor should be clamped to valid bounds
    try testing.expect(term.cursor.x <= 1); // Should be clamped
    try testing.expect(term.cursor.y <= 1); // Should be clamped
}

test "resize preserves scrollback capacity and content after scrolling" {
    // Regression: resize used to reallocate only new_width × new_height
    // (viewport-sized) while scrollback_lines stayed at its old value, so any
    // buffer-line lookup past the viewport indexed off the end of the
    // allocation as soon as content had scrolled.
    var term = try VTerm.init(testing.allocator, 10, 2);
    defer term.deinit();

    // Five logical lines — more than the 2-row viewport holds.
    term.write("A\nB\nC\nD\nE");

    try term.resize(8, 3);

    // The buffer must still hold the whole scrollback, not just the viewport.
    try testing.expectEqual(@as(usize, @as(usize, term.scrollback_lines) * 8), term.cells.len);

    // The viewport (bottom of history) still shows the latest lines: C, D, E.
    try testing.expectEqual(@as(u21, 'C'), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'D'), term.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, 'E'), term.getCell(0, 2).char);

    // Scrolled-off history survives the resize too.
    term.scrollViewportUp(2);
    try testing.expectEqual(@as(u21, 'A'), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'B'), term.getCell(0, 1).char);
    term.scrollToBottom();

    // Writing more lines after the resize stays in bounds (used to index
    // past the shrunken buffer and panic).
    term.write("\nF");
    try testing.expectEqual(@as(u21, 'F'), term.getCell(0, 2).char);
}

test "erase display commands are viewport-relative after scrolling" {
    // Regression: ESC[0J / ESC[1J used the viewport cursor y as a raw buffer
    // index and erased to the end of the whole scrollback allocation, so with
    // scrolled content they wiped the wrong lines.
    var term = try VTerm.init(testing.allocator, 5, 2);
    defer term.deinit();

    // Four logical lines; viewport shows C (row 0) and D (row 1).
    term.write("AA\nBB\nCC\nDD");

    // Cursor sits on the last line. Erase from start of SCREEN to cursor:
    // clears C's row and D up to the cursor — but must not touch the
    // scrolled-off A and B.
    term.moveCursor(0, 1);
    term.write("\x1b[1J");

    try testing.expect(term.getCell(0, 0).isEmpty()); // C cleared
    try testing.expect(term.getCell(0, 1).isEmpty()); // D..cursor cleared
    try testing.expectEqual(@as(u21, 'D'), term.getCell(1, 1).char); // rest of D's row preserved

    term.scrollViewportUp(2);
    try testing.expectEqual(@as(u21, 'A'), term.getCell(0, 0).char); // history intact
    try testing.expectEqual(@as(u21, 'B'), term.getCell(0, 1).char);
}

test "erase from cursor clears only to end of screen, not scrollback" {
    var term = try VTerm.init(testing.allocator, 5, 2);
    defer term.deinit();

    term.write("AA\nBB\nCC\nDD");

    // Erase from the middle of the top viewport row to the end of the screen.
    term.moveCursor(1, 0);
    term.write("\x1b[0J");

    try testing.expectEqual(@as(u21, 'C'), term.getCell(0, 0).char); // before cursor preserved
    try testing.expect(term.getCell(1, 0).isEmpty()); // cursor onward cleared
    try testing.expect(term.getCell(0, 1).isEmpty()); // next row cleared

    term.scrollViewportUp(2);
    try testing.expectEqual(@as(u21, 'A'), term.getCell(0, 0).char); // history intact
    try testing.expectEqual(@as(u21, 'B'), term.getCell(0, 1).char);
}
