const std = @import("std");
const testing = std.testing;
const vterm = @import("../vterm.zig");
const VTerm = vterm.VTerm;
const Key = vterm.Key;

test "generate character sequences" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    try testing.expectEqualStrings("A", term.inputKey(.{ .char = 'A' }));
    try testing.expectEqualStrings("1", term.inputKey(.{ .char = '1' }));
    try testing.expectEqualStrings(" ", term.inputKey(.{ .char = ' ' }));
}

test "generate arrow keys" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    try testing.expectEqualStrings("\x1b[A", term.inputKey(.arrow_up));
    try testing.expectEqualStrings("\x1b[B", term.inputKey(.arrow_down));
    try testing.expectEqualStrings("\x1b[C", term.inputKey(.arrow_right));
    try testing.expectEqualStrings("\x1b[D", term.inputKey(.arrow_left));
}

test "generate special keys" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    try testing.expectEqualStrings("\r", term.inputKey(.enter));
    try testing.expectEqualStrings("\x1b", term.inputKey(.escape));
}

test "generate function keys" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    try testing.expectEqualStrings("\x1b[11~", term.inputKey(.{ .function = 1 })); // F1
    try testing.expectEqualStrings("\x1b[12~", term.inputKey(.{ .function = 2 })); // F2
    try testing.expectEqualStrings("\x1b[24~", term.inputKey(.{ .function = 12 })); // F12
    try testing.expectEqualStrings("", term.inputKey(.{ .function = 15 })); // Invalid
}

test "generate control characters" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    try testing.expectEqualStrings("\x01", term.inputKey(.{ .ctrl_char = 1 })); // Ctrl+A
    try testing.expectEqualStrings("\x03", term.inputKey(.{ .ctrl_char = 3 })); // Ctrl+C
    try testing.expectEqualStrings("\x1A", term.inputKey(.{ .ctrl_char = 26 })); // Ctrl+Z
}
