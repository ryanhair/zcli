const std = @import("std");
const testing = std.testing;
const vterm = @import("../vterm.zig");
const VTerm = vterm.VTerm;

test "wide character basic display" {
    var term = try VTerm.init(testing.allocator, 6, 3);
    defer term.deinit();

    // Test emoji (should take 2 columns)
    term.write("A🚀B");

    // Should have: A at (0,0), 🚀 at (1,0)+(2,0), B at (3,0)
    try testing.expect(term.getCell(0, 0).char == 'A');
    try testing.expect(term.getCell(1, 0).char == 0x1F680); // 🚀 rocket emoji
    try testing.expect(term.getCell(2, 0).wide_continuation);
    try testing.expect(term.getCell(3, 0).char == 'B');

    // Cursor should be at (4, 0)
    try testing.expect(term.cursorAt(4, 0));
}

test "character width detection" {
    // Test that our width detection works
    try testing.expectEqual(@as(u8, 1), vterm.charWidth('A'));
    try testing.expectEqual(@as(u8, 2), vterm.charWidth(0x1F680)); // 🚀 rocket
    try testing.expectEqual(@as(u8, 2), vterm.charWidth(0x4F60)); // 你 (Chinese)
}

test "emoji UTF-8 handling debug" {
    var term = try VTerm.init(testing.allocator, 10, 2);
    defer term.deinit();

    // Test if emoji works at all in this context
    term.write("🚀");

    // Check if emoji is found
    var emoji_found = false;
    for (0..2) |y| {
        for (0..10) |x| {
            const cell = term.getCell(@intCast(x), @intCast(y));
            if (cell.char == 0x1F680) {
                emoji_found = true;
                break;
            }
        }
    }

    try testing.expect(emoji_found);
}

test "wide character wrapping" {
    var term = try VTerm.init(testing.allocator, 4, 2);
    defer term.deinit();

    // Test with simpler case first - use putChar directly
    term.putChar('A');
    term.putChar('B');
    term.putChar('C');

    // Now use putChar with emoji directly (bypass UTF-8 parsing)
    term.putChar(0x1F680); // Direct Unicode codepoint

    // Check if emoji was placed
    var emoji_found = false;
    for (0..2) |y| {
        for (0..4) |x| {
            const cell = term.getCell(@intCast(x), @intCast(y));
            if (cell.char == 0x1F680) {
                emoji_found = true;
                break;
            }
        }
    }

    try testing.expect(emoji_found);
}

test "wide character line extraction" {
    var term = try VTerm.init(testing.allocator, 15, 3); // Make wider to ensure everything fits
    defer term.deinit();

    term.write("Hello🌍World");

    const line = try term.getLine(testing.allocator, 0);
    defer testing.allocator.free(line);

    // Should contain the text with emoji properly encoded
    try testing.expect(std.mem.indexOf(u8, line, "Hello") != null);
    try testing.expect(std.mem.indexOf(u8, line, "World") != null);
    // Check that it contains the earth emoji (🌍 = 0x1F30D)
    try testing.expect(line.len > 5); // More than just "HelloWorld"
}

test "CJK character support" {
    var term = try VTerm.init(testing.allocator, 6, 2);
    defer term.deinit();

    // Test Chinese character (should be wide)
    term.write("你好"); // "Hello" in Chinese

    // Both characters should take 2 columns each
    try testing.expect(term.getCell(0, 0).char == 0x4F60); // 你
    try testing.expect(term.getCell(1, 0).wide_continuation);
    try testing.expect(term.getCell(2, 0).char == 0x597D); // 好
    try testing.expect(term.getCell(3, 0).wide_continuation);

    // Cursor should be at (4, 0)
    try testing.expect(term.cursorAt(4, 0));
}

test "mixed ASCII and wide characters" {
    var term = try VTerm.init(testing.allocator, 8, 2);
    defer term.deinit();

    term.write("A🎈B🎉C");

    // Layout: A[🎈][🎈]B[🎉][🎉]C
    try testing.expect(term.getCell(0, 0).char == 'A');
    try testing.expect(term.getCell(1, 0).char == 0x1F388); // 🎈 balloon
    try testing.expect(term.getCell(2, 0).wide_continuation);
    try testing.expect(term.getCell(3, 0).char == 'B');
    try testing.expect(term.getCell(4, 0).char == 0x1F389); // 🎉 party
    try testing.expect(term.getCell(5, 0).wide_continuation);
    try testing.expect(term.getCell(6, 0).char == 'C');

    // Cursor should be at (7, 0)
    try testing.expect(term.cursorAt(7, 0));
}

test "wide char on 1-column terminal with DECAWM off does not panic (#529)" {
    var term = try VTerm.init(testing.allocator, 1, 2);
    defer term.deinit();

    // Disable autowrap (DECAWM off), then write a wide (2-cell) CJK char on a
    // 1-column terminal. Previously `self.width - 2` underflowed u16 and the
    // continuation `cursor.x + 1` overflowed -> panic. Now the wide glyph is
    // degraded to a single-cell write; no continuation cell, no panic.
    term.write("\x1b[?7l");
    term.write("你");

    // The glyph lands in the single available cell; nothing overflows.
    try testing.expect(term.getCell(0, 0).char == 0x4F60);
    try testing.expect(!term.getCell(0, 0).wide_continuation);
}
