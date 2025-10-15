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
