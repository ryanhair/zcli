const std = @import("std");
const testing = std.testing;
const vterm = @import("../vterm.zig");
const VTerm = vterm.VTerm;
const Key = vterm.Key;

test "round trip text input" {
    var term = try VTerm.init(testing.allocator, 10, 5);
    defer term.deinit();

    // Generate and process text input sequence
    const seq = term.inputKey(.{ .char = 'X' });
    term.write(seq);

    // Verify it was written correctly
    try testing.expectEqual(@as(u21, 'X'), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u16, 1), term.getCursor().x);
}

test "round trip cursor movement" {
    var term = try VTerm.init(testing.allocator, 10, 5);
    defer term.deinit();

    // Generate and process cursor movement sequence
    const seq = term.inputKey(.arrow_right);
    term.write(seq);

    // Verify cursor moved
    try testing.expectEqual(@as(u16, 1), term.getCursor().x);
    try testing.expectEqual(@as(u16, 0), term.getCursor().y);
}

test "round trip arrow key navigation" {
    var term = try VTerm.init(testing.allocator, 10, 5);
    defer term.deinit();

    // Start at (0,0), move right then down
    term.write(term.inputKey(.arrow_right));
    term.write(term.inputKey(.arrow_down));

    try testing.expectEqual(@as(u16, 1), term.getCursor().x);
    try testing.expectEqual(@as(u16, 1), term.getCursor().y);

    // Move left then up - should be back at origin
    term.write(term.inputKey(.arrow_left));
    term.write(term.inputKey(.arrow_up));

    try testing.expectEqual(@as(u16, 0), term.getCursor().x);
    try testing.expectEqual(@as(u16, 0), term.getCursor().y);
}

test "round trip control characters" {
    var term = try VTerm.init(testing.allocator, 10, 5);
    defer term.deinit();

    // Most control characters (like Ctrl+C) are ignored in terminals - they don't print
    const ctrl_c_seq = term.inputKey(.{ .ctrl_char = 3 });
    term.write(ctrl_c_seq);

    // Control characters don't produce visible output in normal terminals
    try testing.expect(term.getCell(0, 0).isEmpty());
    try testing.expectEqual(@as(u16, 0), term.getCursor().x); // Cursor doesn't move
}

test "round trip enter key" {
    var term = try VTerm.init(testing.allocator, 10, 5);
    defer term.deinit();

    term.write("Hello");
    try testing.expectEqual(@as(u16, 5), term.getCursor().x);

    // Enter generates \r which should move cursor to start of current line
    term.write(term.inputKey(.enter));
    try testing.expectEqual(@as(u16, 0), term.getCursor().x);
    try testing.expectEqual(@as(u16, 0), term.getCursor().y); // Still on same line
}

test "round trip multiple characters" {
    var term = try VTerm.init(testing.allocator, 10, 5);
    defer term.deinit();

    // Type "Hi" using input generation
    term.write(term.inputKey(.{ .char = 'H' }));
    term.write(term.inputKey(.{ .char = 'i' }));

    try testing.expectEqual(@as(u21, 'H'), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'i'), term.getCell(1, 0).char);
    try testing.expectEqual(@as(u16, 2), term.getCursor().x);
}
