const std = @import("std");
const testing = std.testing;

const VTerm = @import("vterm.zig").VTerm;

// Basic Operations Tests
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

test "setCell direct manipulation" {
    var term = try VTerm.init(testing.allocator, 5, 3);
    defer term.deinit();

    // Test direct cell setting
    const Cell = @import("vterm.zig").Cell;
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
    const Cell = @import("vterm.zig").Cell;
    const cell = Cell.init('X');
    term.setCell(10, 10, cell);

    // Should not have affected anything
    const check_cell = term.getCell(0, 0);
    try testing.expect(check_cell.isEmpty());
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

// Cursor Movement Tests
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

test "unicode characters" {
    var term = try VTerm.init(testing.allocator, 10, 5);
    defer term.deinit();

    // Test various unicode characters
    term.putChar('😀'); // Emoji
    term.putChar('ñ'); // Latin extended
    term.putChar('中'); // CJK

    try testing.expectEqual(@as(u21, '😀'), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'ñ'), term.getCell(1, 0).char);
    try testing.expectEqual(@as(u21, '中'), term.getCell(2, 0).char);
    try testing.expectEqual(@as(u16, 3), term.cursor.x);
}

test "Cell helper functions" {
    const Cell = @import("vterm.zig").Cell;

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

// Resize Tests
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

    // Cursor should be clamped
    try testing.expectEqual(@as(u16, 1), term.cursor.x); // Was 2, now clamped to 1
    try testing.expectEqual(@as(u16, 1), term.cursor.y); // Was 2, now clamped to 1
}
