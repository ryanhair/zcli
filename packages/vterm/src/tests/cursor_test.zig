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
