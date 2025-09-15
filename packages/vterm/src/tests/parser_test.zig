const std = @import("std");
const testing = std.testing;
const vterm = @import("../vterm.zig");
const VTerm = vterm.VTerm;

test "cursor positioning" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // Absolute positioning
    term.write("\x1b[5;10H");
    try testing.expectEqual(@as(u16, 9), term.cursor.x); // Col 10 -> x=9
    try testing.expectEqual(@as(u16, 4), term.cursor.y); // Row 5 -> y=4

    // Alternative form
    term.write("\x1b[1;1f");
    try testing.expectEqual(@as(u16, 0), term.cursor.x);
    try testing.expectEqual(@as(u16, 0), term.cursor.y);
}

test "relative cursor movement" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    term.moveCursor(5, 5);

    // Up 2
    term.write("\x1b[2A");
    try testing.expectEqual(@as(u16, 3), term.cursor.y);

    // Down 1
    term.write("\x1b[B");
    try testing.expectEqual(@as(u16, 4), term.cursor.y);

    // Right 3
    term.write("\x1b[3C");
    try testing.expectEqual(@as(u16, 8), term.cursor.x);

    // Left 2
    term.write("\x1b[2D");
    try testing.expectEqual(@as(u16, 6), term.cursor.x);
}

test "malformed sequences ignored" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // Invalid escape sequence should not crash
    term.write("\x1b[999X");
    term.write("Hello");

    // Should still work normally
    try testing.expectEqual(@as(u21, 'H'), term.getCell(0, 0).char);
}

test "basic text input" {
    var term = try VTerm.init(testing.allocator, 10, 5);
    defer term.deinit();

    term.write("Hello");

    try testing.expectEqual(@as(u21, 'H'), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'e'), term.getCell(1, 0).char);
    try testing.expectEqual(@as(u21, 'l'), term.getCell(2, 0).char);
    try testing.expectEqual(@as(u21, 'l'), term.getCell(3, 0).char);
    try testing.expectEqual(@as(u21, 'o'), term.getCell(4, 0).char);
    try testing.expectEqual(@as(u16, 5), term.cursor.x);
}

test "newline and carriage return" {
    var term = try VTerm.init(testing.allocator, 10, 5);
    defer term.deinit();

    term.write("Hi\nBye");

    try testing.expectEqual(@as(u21, 'H'), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'i'), term.getCell(1, 0).char);
    try testing.expectEqual(@as(u21, 'B'), term.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, 'y'), term.getCell(1, 1).char);
    try testing.expectEqual(@as(u21, 'e'), term.getCell(2, 1).char);

    // Carriage return
    term.write("\rX");
    try testing.expectEqual(@as(u21, 'X'), term.getCell(0, 1).char);
}

test "tab handling" {
    var term = try VTerm.init(testing.allocator, 20, 5);
    defer term.deinit();

    term.write("A\tB");

    try testing.expectEqual(@as(u21, 'A'), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'B'), term.getCell(8, 0).char); // Next tab stop
    try testing.expectEqual(@as(u16, 9), term.cursor.x);
}

test "backspace" {
    var term = try VTerm.init(testing.allocator, 10, 5);
    defer term.deinit();

    term.write("ABC\x08D");

    try testing.expectEqual(@as(u21, 'A'), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'B'), term.getCell(1, 0).char);
    try testing.expectEqual(@as(u21, 'D'), term.getCell(2, 0).char); // Overwrites C
    try testing.expectEqual(@as(u16, 3), term.cursor.x);
}

test "clear screen" {
    var term = try VTerm.init(testing.allocator, 5, 3);
    defer term.deinit();

    term.write("XXXXX");
    term.write("XXXXX");
    term.write("XXXXX");

    // Clear entire screen
    term.write("\x1b[2J");

    // All cells should be empty
    for (0..5) |x| {
        for (0..3) |y| {
            try testing.expect(term.getCell(@intCast(x), @intCast(y)).isEmpty());
        }
    }
}

test "clear line" {
    var term = try VTerm.init(testing.allocator, 5, 3);
    defer term.deinit();

    term.write("ABCDE");
    term.moveCursor(2, 0);

    // Clear from cursor to end of line (EL 0)
    term.write("\x1b[K");

    try testing.expectEqual(@as(u21, 'A'), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'B'), term.getCell(1, 0).char);
    try testing.expect(term.getCell(2, 0).isEmpty());
    try testing.expect(term.getCell(3, 0).isEmpty());
    try testing.expect(term.getCell(4, 0).isEmpty());
}

test "erase display sequences" {
    var term = try VTerm.init(testing.allocator, 5, 3);
    defer term.deinit();

    // Fill screen
    term.write("ABCDEFGHIJKLMNO");
    term.moveCursor(2, 1); // Position cursor in middle

    // Test ED 0: Clear from cursor to end of display
    var term2 = try VTerm.init(testing.allocator, 5, 3);
    defer term2.deinit();
    term2.write("ABCDEFGHIJKLMNO");
    term2.moveCursor(2, 1);
    term2.write("\x1b[0J");

    try testing.expectEqual(@as(u21, 'A'), term2.getCell(0, 0).char); // Preserved
    try testing.expectEqual(@as(u21, 'G'), term2.getCell(1, 1).char); // Preserved
    try testing.expect(term2.getCell(2, 1).isEmpty()); // Cleared from cursor
    try testing.expect(term2.getCell(0, 2).isEmpty()); // Cleared

    // Test ED 1: Clear from start to cursor
    var term3 = try VTerm.init(testing.allocator, 5, 3);
    defer term3.deinit();
    term3.write("ABCDEFGHIJKLMNO");
    term3.moveCursor(2, 1);
    term3.write("\x1b[1J");

    try testing.expect(term3.getCell(0, 0).isEmpty()); // Cleared
    try testing.expect(term3.getCell(2, 1).isEmpty()); // Cleared to cursor
    try testing.expectEqual(@as(u21, 'I'), term3.getCell(3, 1).char); // Preserved
}

test "erase line variations" {
    var term = try VTerm.init(testing.allocator, 5, 3);
    defer term.deinit();

    // Test EL 1: Clear from start to cursor
    term.write("ABCDE");
    term.moveCursor(2, 0);
    term.write("\x1b[1K");

    try testing.expect(term.getCell(0, 0).isEmpty());
    try testing.expect(term.getCell(1, 0).isEmpty());
    try testing.expect(term.getCell(2, 0).isEmpty()); // Including cursor position
    try testing.expectEqual(@as(u21, 'D'), term.getCell(3, 0).char);
    try testing.expectEqual(@as(u21, 'E'), term.getCell(4, 0).char);

    // Test EL 2: Clear entire line
    term.write("\x1b[2;1H"); // Move to line 2
    term.write("VWXYZ");
    term.moveCursor(2, 1); // Position in middle
    term.write("\x1b[2K");

    try testing.expect(term.getCell(0, 1).isEmpty());
    try testing.expect(term.getCell(1, 1).isEmpty());
    try testing.expect(term.getCell(2, 1).isEmpty());
    try testing.expect(term.getCell(3, 1).isEmpty());
    try testing.expect(term.getCell(4, 1).isEmpty());
}

test "cursor visibility" {
    var term = try VTerm.init(testing.allocator, 10, 5);
    defer term.deinit();

    try testing.expect(term.cursor_visible);

    // Hide cursor
    term.write("\x1b[?25l");
    try testing.expect(!term.cursor_visible);

    // Show cursor
    term.write("\x1b[?25h");
    try testing.expect(term.cursor_visible);
}

test "alternate screen" {
    var term = try VTerm.init(testing.allocator, 10, 5);
    defer term.deinit();

    try testing.expect(!term.alt_screen);

    // Switch to alternate screen
    term.write("\x1b[?1049h");
    try testing.expect(term.alt_screen);

    // Switch back to main screen
    term.write("\x1b[?1049l");
    try testing.expect(!term.alt_screen);
}

test "parameter defaults and edge cases" {
    var term = try VTerm.init(testing.allocator, 10, 10);
    defer term.deinit();

    term.moveCursor(5, 5);

    // No parameter means 1
    term.write("\x1b[A"); // Move up 1 (default)
    try testing.expectEqual(@as(u16, 4), term.cursor.y);

    // Zero parameter means 1
    term.write("\x1b[0B"); // Move down 1 (0 -> default 1)
    try testing.expectEqual(@as(u16, 5), term.cursor.y);

    // Multiple parameters
    term.write("\x1b[3;7H"); // Move to row 3, col 7
    try testing.expectEqual(@as(u16, 6), term.cursor.x); // col 7 -> x=6
    try testing.expectEqual(@as(u16, 2), term.cursor.y); // row 3 -> y=2

    // Missing second parameter uses default
    term.write("\x1b[2H"); // Move to row 2, col 1 (default)
    try testing.expectEqual(@as(u16, 0), term.cursor.x); // col 1 -> x=0
    try testing.expectEqual(@as(u16, 1), term.cursor.y); // row 2 -> y=1
}

test "parser state recovery" {
    var term = try VTerm.init(testing.allocator, 10, 5);
    defer term.deinit();

    // Invalid escape sequence should abort and process rest as normal text
    term.write("\x1b["); // Start CSI
    term.write("\x1F"); // Invalid character (control character < 0x20, not valid CSI)
    term.write("Hello"); // Should work normally

    try testing.expectEqual(@as(u21, 'H'), term.getCell(0, 0).char);

    // Invalid final character
    term.write("\x1b[5X"); // Unknown command 'X'
    term.write("World"); // Should continue normally

    try testing.expectEqual(@as(u21, 'W'), term.getCell(5, 0).char);
}

test "large parameter values" {
    var term = try VTerm.init(testing.allocator, 10, 10);
    defer term.deinit();

    // Large cursor movement should be clamped to screen bounds
    term.write("\x1b[999;999H");
    try testing.expectEqual(@as(u16, 9), term.cursor.x); // Clamped to width-1
    try testing.expectEqual(@as(u16, 9), term.cursor.y); // Clamped to height-1

    // Large relative movement should also be clamped
    term.moveCursor(5, 5);
    term.write("\x1b[999C"); // Move right by 999
    try testing.expectEqual(@as(u16, 9), term.cursor.x); // Clamped to width-1
}
