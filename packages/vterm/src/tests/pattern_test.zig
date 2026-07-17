const std = @import("std");
const testing = std.testing;
const vterm = @import("../vterm.zig");
const VTerm = vterm.VTerm;

test "containsPattern finds simple patterns" {
    var term = try VTerm.init(testing.allocator, 40, 5);
    defer term.deinit();

    term.write("Error: File not found at line 42\n");
    term.write("Warning: Deprecated function used\n");
    term.write("Info: Process completed successfully");

    // Test regex-like patterns
    try testing.expect(term.containsPattern("Error:.*line [0-9]+"));
    try testing.expect(term.containsPattern("Warning:.*Deprecated"));
    try testing.expect(term.containsPattern("Info:.*successfully"));
    try testing.expect(!term.containsPattern("Critical:.*failed"));
}

test "containsPattern handles wildcards" {
    var term = try VTerm.init(testing.allocator, 40, 5);
    defer term.deinit();

    term.write("test_file_001.txt\n");
    term.write("test_file_002.txt\n");
    term.write("test_file_103.txt\n");

    // Test with wildcards
    try testing.expect(term.containsPattern("test_file_*.txt"));
    try testing.expect(term.containsPattern("test_file_00?.txt"));
    try testing.expect(!term.containsPattern("test_file_00?.dat"));
}

test "findPattern returns position of match" {
    var term = try VTerm.init(testing.allocator, 40, 5);
    defer term.deinit();

    term.write("Line 1: Normal text\n");
    term.write("Line 2: Error code 404\n");
    term.write("Line 3: More text");

    // Find pattern and get positions
    const positions = try term.findPattern(testing.allocator, "Error.*[0-9]+");
    defer testing.allocator.free(positions);

    try testing.expect(positions.len > 0);
    try testing.expectEqual(@as(u16, 8), positions[0].x); // Start of "Error"
    try testing.expectEqual(@as(u16, 1), positions[0].y); // Line 2
}

test "findPattern reports cell position after wide (CJK) characters" {
    var term = try VTerm.init(testing.allocator, 20, 3);
    defer term.deinit();

    // 你 and 好 each occupy 2 cells, so X lands at column 4, not byte offset 6.
    term.write("你好X");

    const positions = try term.findPattern(testing.allocator, "X");
    defer testing.allocator.free(positions);

    try testing.expectEqual(@as(usize, 1), positions.len);
    try testing.expectEqual(@as(u16, 4), positions[0].x);
    try testing.expectEqual(@as(u16, 0), positions[0].y);
}

test "findPattern reports cell position after multibyte (narrow) characters" {
    var term = try VTerm.init(testing.allocator, 20, 3);
    defer term.deinit();

    // é is one cell wide but two UTF-8 bytes; the byte offset of X would be 4,
    // while its cell column is 3.
    term.write("café X");

    const positions = try term.findPattern(testing.allocator, "X");
    defer testing.allocator.free(positions);

    try testing.expectEqual(@as(usize, 1), positions.len);
    try testing.expectEqual(@as(u16, 5), positions[0].x); // c a f é <space> X
    try testing.expectEqual(@as(u16, 0), positions[0].y);
}

test "findPattern maps wide content across rows to correct cell" {
    var term = try VTerm.init(testing.allocator, 10, 3);
    defer term.deinit();

    term.write("你好\n");
    term.write("abZcd");

    const positions = try term.findPattern(testing.allocator, "Z");
    defer testing.allocator.free(positions);

    try testing.expectEqual(@as(usize, 1), positions.len);
    try testing.expectEqual(@as(u16, 2), positions[0].x);
    try testing.expectEqual(@as(u16, 1), positions[0].y);
}

test "containsTextIgnoreCase finds text case-insensitively" {
    var term = try VTerm.init(testing.allocator, 40, 5);
    defer term.deinit();

    term.write("Hello World\n");
    term.write("HELLO WORLD\n");
    term.write("hello world\n");

    try testing.expect(term.containsTextIgnoreCase("hello world"));
    try testing.expect(term.containsTextIgnoreCase("HELLO WORLD"));
    try testing.expect(term.containsTextIgnoreCase("HeLLo WoRLd"));
    try testing.expect(!term.containsTextIgnoreCase("goodbye world"));
}

test "containsPattern with line anchors" {
    var term = try VTerm.init(testing.allocator, 40, 5);
    defer term.deinit();

    term.write("Start of line\n");
    term.write("  Indented line\n");
    term.write("End");

    // Test line start/end patterns
    try testing.expect(term.containsPattern("^Start")); // Line start
    try testing.expect(term.containsPattern("line$")); // Line end
    try testing.expect(!term.containsPattern("^Indented")); // Not at start due to spaces
    try testing.expect(term.containsPattern("^  Indented")); // With spaces
}
