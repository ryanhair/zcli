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

test "setCell direct manipulation" {
    var term = try VTerm.init(testing.allocator, 5, 3);
    defer term.deinit();

    // Test direct cell setting
    const Cell = vterm.Cell;
    const cell = Cell.init('Z');
    term.setCell(2, 1, cell);

    const retrieved = term.getCell(2, 1);
    try testing.expectEqual(@as(u21, 'Z'), retrieved.char);

    // Cursor should not have moved
    try testing.expectEqual(@as(u16, 0), term.cursor.x);
    try testing.expectEqual(@as(u16, 0), term.cursor.y);
}

test "setCell out of bounds" {
    var term = try VTerm.init(testing.allocator, 3, 2);
    defer term.deinit();

    // Should not crash when setting out of bounds
    const Cell = vterm.Cell;
    const cell = Cell.init('X');
    term.setCell(10, 10, cell);

    // Should not have affected anything
    const check_cell = term.getCell(0, 0);
    try testing.expect(check_cell.isEmpty());
}

test "edge case - single cell terminal" {
    var term = try VTerm.init(testing.allocator, 1, 1);
    defer term.deinit();

    term.putChar('X');
    try testing.expectEqual(@as(u21, 'X'), term.getCell(0, 0).char);
    // Cursor should stay at (0, 0) since there's nowhere else to go
    try testing.expectEqual(@as(u16, 0), term.cursor.x);
    try testing.expectEqual(@as(u16, 0), term.cursor.y);
}

test "edge case - zero width or height" {
    // Should still work without crashing, even though impractical
    var term = try VTerm.init(testing.allocator, 0, 5);
    defer term.deinit();
    try testing.expectEqual(@as(u16, 0), term.width);
    try testing.expectEqual(@as(u16, 5), term.height);

    var term2 = try VTerm.init(testing.allocator, 5, 0);
    defer term2.deinit();
    try testing.expectEqual(@as(u16, 5), term2.width);
    try testing.expectEqual(@as(u16, 0), term2.height);
}

test "unicode characters - basic support" {
    var term = try VTerm.init(testing.allocator, 10, 5);
    defer term.deinit();

    // Test basic unicode character support
    term.putChar('ñ'); // Latin extended (narrow)
    term.putChar('A'); // ASCII

    try testing.expectEqual(@as(u21, 'ñ'), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'A'), term.getCell(1, 0).char);
    try testing.expectEqual(@as(u16, 2), term.cursor.x);
}

test "Cell helper functions" {
    const Cell = vterm.Cell;

    // Test Cell.empty()
    const empty_cell = Cell.empty();
    try testing.expect(empty_cell.isEmpty());
    try testing.expectEqual(@as(u21, 0), empty_cell.char);

    // Test Cell.init()
    const char_cell = Cell.init('A');
    try testing.expect(!char_cell.isEmpty());
    try testing.expectEqual(@as(u21, 'A'), char_cell.char);

    // Test with unicode
    const unicode_cell = Cell.init('🎉');
    try testing.expect(!unicode_cell.isEmpty());
    try testing.expectEqual(@as(u21, '🎉'), unicode_cell.char);
}
