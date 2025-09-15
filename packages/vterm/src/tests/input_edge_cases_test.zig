const std = @import("std");
const testing = std.testing;
const vterm = @import("../vterm.zig");
const VTerm = vterm.VTerm;
const Key = vterm.Key;

test "function keys complete range" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // Test all function keys F1-F12
    try testing.expectEqualStrings("\x1b[11~", term.inputKey(.{ .function = 1 })); // F1
    try testing.expectEqualStrings("\x1b[12~", term.inputKey(.{ .function = 2 })); // F2
    try testing.expectEqualStrings("\x1b[13~", term.inputKey(.{ .function = 3 })); // F3
    try testing.expectEqualStrings("\x1b[14~", term.inputKey(.{ .function = 4 })); // F4
    try testing.expectEqualStrings("\x1b[15~", term.inputKey(.{ .function = 5 })); // F5
    try testing.expectEqualStrings("\x1b[17~", term.inputKey(.{ .function = 6 })); // F6
    try testing.expectEqualStrings("\x1b[18~", term.inputKey(.{ .function = 7 })); // F7
    try testing.expectEqualStrings("\x1b[19~", term.inputKey(.{ .function = 8 })); // F8
    try testing.expectEqualStrings("\x1b[20~", term.inputKey(.{ .function = 9 })); // F9
    try testing.expectEqualStrings("\x1b[21~", term.inputKey(.{ .function = 10 })); // F10
    try testing.expectEqualStrings("\x1b[23~", term.inputKey(.{ .function = 11 })); // F11
    try testing.expectEqualStrings("\x1b[24~", term.inputKey(.{ .function = 12 })); // F12
}

test "function key boundary validation" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // Invalid function keys should return empty string
    try testing.expectEqualStrings("", term.inputKey(.{ .function = 0 })); // F0 invalid
    try testing.expectEqualStrings("", term.inputKey(.{ .function = 13 })); // F13 invalid
    try testing.expectEqualStrings("", term.inputKey(.{ .function = 255 })); // Large invalid
}

test "control characters complete range" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // Test representative control characters across the range
    try testing.expectEqualStrings("\x01", term.inputKey(.{ .ctrl_char = 1 })); // Ctrl+A
    try testing.expectEqualStrings("\x02", term.inputKey(.{ .ctrl_char = 2 })); // Ctrl+B
    try testing.expectEqualStrings("\x03", term.inputKey(.{ .ctrl_char = 3 })); // Ctrl+C
    try testing.expectEqualStrings("\x0A", term.inputKey(.{ .ctrl_char = 10 })); // Ctrl+J
    try testing.expectEqualStrings("\x0D", term.inputKey(.{ .ctrl_char = 13 })); // Ctrl+M
    try testing.expectEqualStrings("\x14", term.inputKey(.{ .ctrl_char = 20 })); // Ctrl+T
    try testing.expectEqualStrings("\x19", term.inputKey(.{ .ctrl_char = 25 })); // Ctrl+Y
    try testing.expectEqualStrings("\x1A", term.inputKey(.{ .ctrl_char = 26 })); // Ctrl+Z
}

test "control character boundary validation" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // Invalid control characters should return empty string
    try testing.expectEqualStrings("", term.inputKey(.{ .ctrl_char = 0 })); // Invalid
    try testing.expectEqualStrings("", term.inputKey(.{ .ctrl_char = 27 })); // Invalid
    try testing.expectEqualStrings("", term.inputKey(.{ .ctrl_char = 255 })); // Invalid
}

test "ASCII character range coverage" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // Test ASCII boundary characters and symbols
    try testing.expectEqualStrings(" ", term.inputKey(.{ .char = ' ' })); // ASCII 32 (space)
    try testing.expectEqualStrings("!", term.inputKey(.{ .char = '!' })); // ASCII 33
    try testing.expectEqualStrings("@", term.inputKey(.{ .char = '@' })); // ASCII 64
    try testing.expectEqualStrings("Z", term.inputKey(.{ .char = 'Z' })); // ASCII 90
    try testing.expectEqualStrings("z", term.inputKey(.{ .char = 'z' })); // ASCII 122
    try testing.expectEqualStrings("~", term.inputKey(.{ .char = '~' })); // ASCII 126
}

test "comprehensive round trip function keys" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // Function keys don't generate visible characters, but should not crash parser
    // Test that function key sequences are parsed without error
    const f1_seq = term.inputKey(.{ .function = 1 });
    const f5_seq = term.inputKey(.{ .function = 5 });
    const f12_seq = term.inputKey(.{ .function = 12 });

    // These sequences should parse without error (no visible effect expected)
    term.write(f1_seq);
    term.write(f5_seq);
    term.write(f12_seq);

    // Cursor should remain at origin since function keys don't move cursor
    try testing.expectEqual(@as(u16, 0), term.getCursor().x);
    try testing.expectEqual(@as(u16, 0), term.getCursor().y);
}

test "comprehensive round trip control characters" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // Test control characters with actual terminal behaviors

    // Ctrl+A (1) - typically ignored, no visible effect
    const ctrl_a_seq = term.inputKey(.{ .ctrl_char = 1 });
    term.write(ctrl_a_seq);
    try testing.expect(term.getCell(0, 0).isEmpty());
    try testing.expectEqual(@as(u16, 0), term.getCursor().x);

    // Ctrl+M (13) is \r - carriage return, moves cursor to start of line
    term.write("Hello");
    try testing.expectEqual(@as(u16, 5), term.getCursor().x);
    const ctrl_m_seq = term.inputKey(.{ .ctrl_char = 13 });
    term.write(ctrl_m_seq);
    try testing.expectEqual(@as(u16, 0), term.getCursor().x); // Back to start
    try testing.expectEqual(@as(u16, 0), term.getCursor().y); // Same line

    // Ctrl+Z (26) - typically ignored, no visible effect
    const ctrl_z_seq = term.inputKey(.{ .ctrl_char = 26 });
    term.write(ctrl_z_seq);
    try testing.expectEqual(@as(u16, 0), term.getCursor().x); // No change
}

test "control characters with specific behaviors" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // Ctrl+I (9) is \t - tab, moves to next tab stop
    const ctrl_i_seq = term.inputKey(.{ .ctrl_char = 9 });
    term.write(ctrl_i_seq);
    try testing.expectEqual(@as(u16, 8), term.getCursor().x); // Next tab stop

    // Ctrl+J (10) is \n - newline, moves to next line
    const ctrl_j_seq = term.inputKey(.{ .ctrl_char = 10 });
    term.write(ctrl_j_seq);
    try testing.expectEqual(@as(u16, 0), term.getCursor().x); // Start of line
    try testing.expectEqual(@as(u16, 1), term.getCursor().y); // Next line

    // Ctrl+H (8) is backspace, moves cursor back
    term.write("AB");
    try testing.expectEqual(@as(u16, 2), term.getCursor().x);
    const ctrl_h_seq = term.inputKey(.{ .ctrl_char = 8 });
    term.write(ctrl_h_seq);
    try testing.expectEqual(@as(u16, 1), term.getCursor().x); // Moved back
}
