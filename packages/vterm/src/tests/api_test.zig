const std = @import("std");
const testing = std.testing;
const vterm = @import("../vterm.zig");
const VTerm = vterm.VTerm;

test "containsText" {
    var term = try VTerm.init(testing.allocator, 10, 5);
    defer term.deinit();

    term.write("Hello World");

    try testing.expect(term.containsText("Hello"));
    try testing.expect(term.containsText("World"));
    try testing.expect(term.containsText("llo Wo"));
    try testing.expect(!term.containsText("Goodbye"));
}

test "cursorAt" {
    var term = try VTerm.init(testing.allocator, 10, 5);
    defer term.deinit();

    try testing.expect(term.cursorAt(0, 0));

    term.write("Hi\x1b[4;3H"); // Move to (2,3)
    try testing.expect(term.cursorAt(2, 3));
    try testing.expect(!term.cursorAt(0, 0));
}

test "getLine" {
    var term = try VTerm.init(testing.allocator, 10, 5); // Larger terminal to avoid scrolling
    defer term.deinit();

    term.write("Line1\nLine2");

    const line0 = try term.getLine(testing.allocator, 0);
    defer testing.allocator.free(line0);
    const line1 = try term.getLine(testing.allocator, 1);
    defer testing.allocator.free(line1);

    try testing.expectEqualStrings("Line1", line0);
    try testing.expectEqualStrings("Line2", line1);
}

test "getAllText" {
    var term = try VTerm.init(testing.allocator, 3, 2);
    defer term.deinit();

    term.write("Hi");

    const text = try term.getAllText(testing.allocator);
    defer testing.allocator.free(text);

    try testing.expectEqualStrings("Hi    ", text); // 6 chars total (3*2)
}

test "expectOutput helper" {
    // Test the helper function from PLAN.md
    const expected = "Hello" ++ " " ** (80 * 24 - 5); // Fill with spaces to 80*24
    try VTerm.expectOutput("Hello", expected);
}

test "zinc layout rendering example" {
    var term = try VTerm.init(testing.allocator, 40, 10);
    defer term.deinit();

    // Simulate zinc rendering a simple layout
    term.write("\x1b[2J\x1b[H"); // Clear and home
    term.write("Hello World");

    // Test the result - matches PLAN.md example
    try testing.expect(term.cursorAt(11, 0));
    try testing.expect(term.containsText("Hello World"));
}

test "CLI help output example" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // Simulate CLI help output - matches PLAN.md example
    const help_output = "Usage: myapp --help";
    term.write(help_output);

    // Test key parts exist
    try testing.expect(term.containsText("Usage: myapp"));
}
