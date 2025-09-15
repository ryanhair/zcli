const std = @import("std");
const testing = std.testing;
const vterm = @import("../vterm.zig");
const VTerm = vterm.VTerm;

test "init and deinit" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    try testing.expectEqual(@as(u16, 80), term.width);
    try testing.expectEqual(@as(u16, 24), term.height);
    try testing.expectEqual(@as(u16, 0), term.cursor.x);
    try testing.expectEqual(@as(u16, 0), term.cursor.y);
}

test "put and get char" {
    var term = try VTerm.init(testing.allocator, 10, 5);
    defer term.deinit();

    term.putChar('A');
    const cell = term.getCell(0, 0);
    try testing.expectEqual(@as(u21, 'A'), cell.char);
    try testing.expectEqual(@as(u16, 1), term.cursor.x); // Advanced
}

test "empty cells" {
    var term = try VTerm.init(testing.allocator, 10, 5);
    defer term.deinit();

    const cell = term.getCell(5, 3);
    try testing.expect(cell.isEmpty());
    try testing.expectEqual(@as(u21, 0), cell.char);
}

test "clear screen" {
    var term = try VTerm.init(testing.allocator, 5, 3);
    defer term.deinit();

    // Fill with some data
    term.putChar('X');
    term.moveCursor(2, 1);
    term.putChar('Y');

    // Clear
    term.clear();

    // Check all empty and cursor reset
    try testing.expect(term.getCell(0, 0).isEmpty());
    try testing.expect(term.getCell(2, 1).isEmpty());
    try testing.expectEqual(@as(u16, 0), term.cursor.x);
    try testing.expectEqual(@as(u16, 0), term.cursor.y);
}

test "bounds checking" {
    var term = try VTerm.init(testing.allocator, 3, 2);
    defer term.deinit();

    // Should not crash with out-of-bounds access
    const cell = term.getCell(10, 10);
    try testing.expect(cell.isEmpty());

    // Should not crash with out-of-bounds set
    term.moveCursor(10, 10);
    term.putChar('X'); // Should be clamped and work

    // Verify it was clamped
    try testing.expectEqual(@as(u16, 2), term.cursor.x); // width-1
    try testing.expectEqual(@as(u16, 1), term.cursor.y); // height-1
}
