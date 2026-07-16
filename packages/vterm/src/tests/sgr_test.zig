const std = @import("std");
const testing = std.testing;
const vterm = @import("../vterm.zig");
const VTerm = vterm.VTerm;

test "basic colors" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // Set red foreground
    term.write("\x1b[31mRed");
    const cell = term.getCell(0, 0);
    try testing.expectEqual(@as(u8, 1), cell.fg); // Red
    try testing.expectEqual(@as(u21, 'R'), cell.char);

    // Set blue background
    term.write("\x1b[44mBlue");
    const cell2 = term.getCell(3, 0);
    try testing.expectEqual(@as(u8, 4), cell2.bg); // Blue background
}

test "text attributes" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // Bold
    term.write("\x1b[1mBold");
    var cell = term.getCell(0, 0);
    try testing.expect(cell.bold);

    // Italic
    term.write("\x1b[3mItalic");
    cell = term.getCell(4, 0);
    try testing.expect(cell.italic);

    // Underline
    term.write("\x1b[4mUnder");
    cell = term.getCell(10, 0);
    try testing.expect(cell.underline);
}

test "SGR reset" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // Set multiple attributes
    term.write("\x1b[1;31;44mX"); // Bold, red fg, blue bg
    var cell = term.getCell(0, 0);
    try testing.expect(cell.bold);
    try testing.expectEqual(@as(u8, 1), cell.fg);
    try testing.expectEqual(@as(u8, 4), cell.bg);

    // Reset
    term.write("\x1b[0mY");
    cell = term.getCell(1, 0);
    try testing.expect(!cell.bold);
    try testing.expectEqual(@as(u8, 7), cell.fg); // Default white
    try testing.expectEqual(@as(u8, 0), cell.bg); // Default black
}

test "bright colors" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // Bright red foreground
    term.write("\x1b[91mX");
    var cell = term.getCell(0, 0);
    try testing.expectEqual(@as(u8, 9), cell.fg); // Bright red = 8 + 1

    // Bright blue background
    term.write("\x1b[104mY");
    cell = term.getCell(1, 0);
    try testing.expectEqual(@as(u8, 12), cell.bg); // Bright blue = 8 + 4
}

test "combined SGR parameters" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // Multiple parameters in one sequence
    term.write("\x1b[1;4;31mX"); // Bold, underline, red
    const cell = term.getCell(0, 0);
    try testing.expect(cell.bold);
    try testing.expect(cell.underline);
    try testing.expectEqual(@as(u8, 1), cell.fg);
}

test "SGR attribute disable" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // Enable attributes
    term.write("\x1b[1;3;4mX"); // Bold, italic, underline
    var cell = term.getCell(0, 0);
    try testing.expect(cell.bold);
    try testing.expect(cell.italic);
    try testing.expect(cell.underline);

    // Disable specific attributes
    term.write("\x1b[22mY"); // No bold
    cell = term.getCell(1, 0);
    try testing.expect(!cell.bold);
    try testing.expect(cell.italic);
    try testing.expect(cell.underline);

    term.write("\x1b[23mZ"); // No italic
    cell = term.getCell(2, 0);
    try testing.expect(!cell.bold);
    try testing.expect(!cell.italic);
    try testing.expect(cell.underline);

    term.write("\x1b[24mW"); // No underline
    cell = term.getCell(3, 0);
    try testing.expect(!cell.bold);
    try testing.expect(!cell.italic);
    try testing.expect(!cell.underline);
}

test "256-color foreground and background (semicolon form)" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // ESC[38;5;9m — 256-color fg index 9 (bright red). Must set the color and
    // set NO other attributes.
    term.write("\x1b[38;5;9mX");
    var cell = term.getCell(0, 0);
    try testing.expectEqual(@as(u8, 9), cell.fg);
    try testing.expect(!cell.bold);
    try testing.expect(!cell.italic);
    try testing.expect(!cell.underline);

    // ESC[48;5;3m — 256-color bg index 3. The `3` must NOT become italic.
    term.write("\x1b[48;5;3mY");
    cell = term.getCell(1, 0);
    try testing.expectEqual(@as(u8, 3), cell.bg);
    try testing.expect(!cell.italic);
}

test "256-color foreground (colon form)" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // ESC[38:5:9m — colon-separated 256-color fg. Same result as semicolon.
    term.write("\x1b[38:5:9mX");
    const cell = term.getCell(0, 0);
    try testing.expectEqual(@as(u8, 9), cell.fg);
    try testing.expect(!cell.bold);
    try testing.expect(!cell.italic);
    try testing.expect(!cell.underline);
}

test "truecolor SGR is consumed without corrupting attributes" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // ESC[38;2;1;2;3m — truecolor fg. u8 cell color can't hold RGB, so the
    // value is discarded. Critically, the sub-params 1/2/3 must NOT be applied
    // as independent SGR codes (bold / italic).
    term.write("\x1b[38;2;1;2;3mX");
    var cell = term.getCell(0, 0);
    try testing.expect(!cell.bold);
    try testing.expect(!cell.italic);
    try testing.expect(!cell.underline);

    // ESC[38;2;34;0;0m — the `34` must NOT set fg to blue (SGR 34).
    term.write("\x1b[38;2;34;0;0mY");
    cell = term.getCell(1, 0);
    try testing.expectEqual(@as(u8, 7), cell.fg); // unchanged default

    // Colon-form truecolor likewise consumed cleanly.
    term.write("\x1b[38:2:255:0:0mZ");
    cell = term.getCell(2, 0);
    try testing.expect(!cell.bold);
    try testing.expect(!cell.italic);
}

test "extended color interleaved with real attributes" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // ESC[1;38;5;2m — bold, then 256-color fg index 2. Bold set exactly once,
    // fg set to 2, and the trailing `2` sub-param not misread.
    term.write("\x1b[1;38;5;2mX");
    const cell = term.getCell(0, 0);
    try testing.expect(cell.bold);
    try testing.expectEqual(@as(u8, 2), cell.fg);
    try testing.expect(!cell.italic);
}

test "extended color followed by more SGR params" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // ESC[38;5;9;1m — 256-color fg then bold. The `1` after the color unit is
    // a real bold code and must apply.
    term.write("\x1b[38;5;9;1mX");
    const cell = term.getCell(0, 0);
    try testing.expectEqual(@as(u8, 9), cell.fg);
    try testing.expect(cell.bold);
}

test "default colors" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // Set custom colors
    term.write("\x1b[31;44mX");
    var cell = term.getCell(0, 0);
    try testing.expectEqual(@as(u8, 1), cell.fg);
    try testing.expectEqual(@as(u8, 4), cell.bg);

    // Reset to default foreground
    term.write("\x1b[39mY");
    cell = term.getCell(1, 0);
    try testing.expectEqual(@as(u8, 7), cell.fg);
    try testing.expectEqual(@as(u8, 4), cell.bg); // Background unchanged

    // Reset to default background
    term.write("\x1b[49mZ");
    cell = term.getCell(2, 0);
    try testing.expectEqual(@as(u8, 7), cell.fg);
    try testing.expectEqual(@as(u8, 0), cell.bg);
}
