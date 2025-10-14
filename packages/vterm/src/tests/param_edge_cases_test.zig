const std = @import("std");
const testing = std.testing;
const vterm = @import("../vterm.zig");
const VTerm = vterm.VTerm;

test "large parameter values are capped" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // Test extremely large cursor position
    term.write("\x1b[999999999;888888888H"); // Massive row/col values

    // Should be capped and cursor should remain in bounds
    try testing.expect(term.cursor.x < term.width);
    try testing.expect(term.cursor.y < term.height);
    // The exact position isn't critical - just that it doesn't crash or overflow
}

test "parameter overflow protection" {
    var term = try VTerm.init(testing.allocator, 10, 5);
    defer term.deinit();

    // Test parameter values that would overflow u16 if not protected
    term.write("\x1b[70000;80000H"); // These exceed u16 max (65535)

    // Terminal should still function normally
    try testing.expect(term.cursor.x <= term.width - 1);
    try testing.expect(term.cursor.y <= term.height - 1);
}

test "reasonable large parameters work" {
    var term = try VTerm.init(testing.allocator, 100, 50);
    defer term.deinit();

    // Test parameters that are large but reasonable
    term.write("\x1b[9999;9999H"); // Should be capped but handled

    // Should move cursor to bottom-right corner (clamped to terminal size)
    try testing.expect(term.cursor.x == term.width - 1);
    try testing.expect(term.cursor.y == term.height - 1);
}

test "excessive parameter count handled" {
    var term = try VTerm.init(testing.allocator, 10, 5);
    defer term.deinit();

    // Test more than 16 parameters (our buffer limit)
    term.write("\x1b[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17;18;19;20H");

    // Should not crash and terminal should remain functional
    try testing.expect(term.cursor.x < term.width);
    try testing.expect(term.cursor.y < term.height);
}

test "SGR with excessive parameters" {
    var term = try VTerm.init(testing.allocator, 10, 5);
    defer term.deinit();

    // Test SGR (color) command with many parameters
    term.write("\x1b[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17;18;19;20;31;42mText");

    // Should not crash and text should be displayed
    try testing.expect(term.containsText("Text"));
    // Colors should be applied (exactly which colors doesn't matter for this test)
}

test "incomplete CSI sequence behavior" {
    var term = try VTerm.init(testing.allocator, 20, 5);
    defer term.deinit();

    // Test correct terminal behavior with incomplete sequences
    term.write("Normal");
    try testing.expect(term.containsText("Normal"));

    // Incomplete CSI sequence followed by text
    term.write("\x1b[999999999Text");

    // The 'T' completes the CSI sequence, 'e', 'x', 't' are normal text
    // This is correct terminal behavior
    try testing.expect(term.containsText("Normal"));
    try testing.expect(term.containsText("ext")); // Only "ext", not full "Text"

    // Test with unsupported CSI command to ensure it's consumed
    term.write("\x1b[123456;456X"); // 'X' is a valid CSI final byte but unsupported command
    term.write("More");

    // 'X' should be consumed as part of the CSI sequence (per ANSI spec)
    // Only "More" should be written as text
    try testing.expect(term.containsText("More"));
    try testing.expect(!term.containsText("XMore")); // 'X' was consumed, not written
}
