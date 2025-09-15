const std = @import("std");
const testing = std.testing;
const vterm = @import("../vterm.zig");
const VTerm = vterm.VTerm;
const Color = vterm.Color;

test "hasAttribute detects bold text" {
    var term = try VTerm.init(testing.allocator, 20, 5);
    defer term.deinit();

    // Write normal text, then bold text
    term.write("Normal ");
    term.write("\x1b[1mBold\x1b[0m");

    // Test that we can detect bold attribute
    try testing.expect(!term.hasAttribute(0, 0, .bold)); // 'N' is not bold
    try testing.expect(!term.hasAttribute(6, 0, .bold)); // Space is not bold
    try testing.expect(term.hasAttribute(7, 0, .bold)); // 'B' is bold
    try testing.expect(term.hasAttribute(8, 0, .bold)); // 'o' is bold
    try testing.expect(term.hasAttribute(9, 0, .bold)); // 'l' is bold
    try testing.expect(term.hasAttribute(10, 0, .bold)); // 'd' is bold
}

test "hasAttribute detects italic text" {
    var term = try VTerm.init(testing.allocator, 20, 5);
    defer term.deinit();

    term.write("\x1b[3mItalic\x1b[0m Normal");

    try testing.expect(term.hasAttribute(0, 0, .italic)); // 'I' is italic
    try testing.expect(term.hasAttribute(5, 0, .italic)); // 'c' is italic
    try testing.expect(!term.hasAttribute(6, 0, .italic)); // Space after reset
    try testing.expect(!term.hasAttribute(7, 0, .italic)); // 'N' is not italic
}

test "hasAttribute detects underline" {
    var term = try VTerm.init(testing.allocator, 20, 5);
    defer term.deinit();

    term.write("\x1b[4mUnderlined\x1b[0m");

    try testing.expect(term.hasAttribute(0, 0, .underline));
    try testing.expect(term.hasAttribute(9, 0, .underline)); // Last char
    try testing.expect(!term.hasAttribute(10, 0, .underline)); // After reset
}

test "getTextColor returns foreground color" {
    var term = try VTerm.init(testing.allocator, 30, 5);
    defer term.deinit();

    // Write text with different colors
    term.write("\x1b[31mRed\x1b[0m "); // Red
    term.write("\x1b[32mGreen\x1b[0m "); // Green
    term.write("\x1b[34mBlue\x1b[0m"); // Blue

    // Test color detection
    const red_color = term.getTextColor(0, 0); // 'R'
    const green_color = term.getTextColor(4, 0); // 'G'
    const blue_color = term.getTextColor(10, 0); // 'B'

    try testing.expectEqual(Color.red, red_color);
    try testing.expectEqual(Color.green, green_color);
    try testing.expectEqual(Color.blue, blue_color);
}

test "getTextColor handles default color" {
    var term = try VTerm.init(testing.allocator, 20, 5);
    defer term.deinit();

    term.write("Default");

    const color = term.getTextColor(0, 0);
    try testing.expectEqual(Color.default, color);
}

test "getBackgroundColor returns background color" {
    var term = try VTerm.init(testing.allocator, 30, 5);
    defer term.deinit();

    // Write text with background colors
    term.write("\x1b[41mRedBg\x1b[0m "); // Red background
    term.write("\x1b[42mGreenBg\x1b[0m "); // Green background

    const red_bg = term.getBackgroundColor(0, 0); // First char with red bg
    const green_bg = term.getBackgroundColor(6, 0); // First char with green bg
    const default_bg = term.getBackgroundColor(13, 0); // After reset

    try testing.expectEqual(Color.red, red_bg);
    try testing.expectEqual(Color.green, green_bg);
    try testing.expectEqual(Color.default, default_bg);
}

test "hasAttribute with multiple attributes" {
    var term = try VTerm.init(testing.allocator, 30, 5);
    defer term.deinit();

    // Combine bold and underline
    term.write("\x1b[1;4mBoldUnderline\x1b[0m");

    try testing.expect(term.hasAttribute(0, 0, .bold));
    try testing.expect(term.hasAttribute(0, 0, .underline));
    try testing.expect(!term.hasAttribute(0, 0, .italic));
}
