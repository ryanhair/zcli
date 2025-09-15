const std = @import("std");
const testing = std.testing;
const vterm = @import("../vterm.zig");
const VTerm = vterm.VTerm;

test "expectRegionEquals verifies rectangular region" {
    var term = try VTerm.init(testing.allocator, 20, 10);
    defer term.deinit();

    // Create a box-like output
    term.write("┌─────┐\n");
    term.write("│Hello│\n");
    term.write("│World│\n");
    term.write("└─────┘\n");

    // Test that a specific region matches expected content
    const expected_box =
        \\┌─────┐
        \\│Hello│
        \\│World│
        \\└─────┘
    ;

    try term.expectRegionEquals(0, 0, 7, 4, expected_box);
}

test "expectRegionEquals handles partial regions" {
    var term = try VTerm.init(testing.allocator, 30, 10);
    defer term.deinit();

    term.write("Header Text\n");
    term.write("┌──────────┐\n");
    term.write("│ Content  │\n");
    term.write("└──────────┘\n");
    term.write("Footer Text");

    // Test just the box portion
    const expected =
        \\┌──────────┐
        \\│ Content  │
        \\└──────────┘
    ;

    try term.expectRegionEquals(0, 1, 12, 3, expected);
}

test "containsTextInRegion searches within bounds" {
    var term = try VTerm.init(testing.allocator, 40, 10);
    defer term.deinit();

    // Create distinct regions
    term.write("Region 1: Alpha Beta\n");
    term.write("Region 2: Gamma Delta\n");
    term.write("Region 3: Epsilon Zeta");

    // Search in specific regions
    try testing.expect(term.containsTextInRegion("Alpha", 0, 0, 20, 1));
    try testing.expect(!term.containsTextInRegion("Alpha", 0, 1, 20, 1)); // Not in row 2
    try testing.expect(term.containsTextInRegion("Gamma", 0, 1, 40, 1));
    try testing.expect(!term.containsTextInRegion("Gamma", 0, 0, 40, 1)); // Not in row 1
}

test "expectRegionEquals with trailing spaces" {
    var term = try VTerm.init(testing.allocator, 20, 5);
    defer term.deinit();

    term.write("Text    \n"); // Text with trailing spaces
    term.write("More    ");

    // Should match including spaces
    try term.expectRegionEquals(0, 0, 8, 1, "Text    ");
    try term.expectRegionEquals(0, 1, 8, 1, "More    ");
}

test "getRegion extracts rectangular area" {
    var term = try VTerm.init(testing.allocator, 20, 10);
    defer term.deinit();

    term.write("AAAAAAAAAA\n");
    term.write("ABBBBBBBBA\n");
    term.write("ABCCCCCCBA\n");
    term.write("ABBBBBBBBA\n");
    term.write("AAAAAAAAAA\n");

    // Extract inner region
    const region = try term.getRegion(testing.allocator, 2, 2, 6, 1);
    defer testing.allocator.free(region);

    try testing.expectEqualStrings("CCCCCC", region);
}

test "diff shows differences between terminals" {
    var term1 = try VTerm.init(testing.allocator, 20, 5);
    defer term1.deinit();
    var term2 = try VTerm.init(testing.allocator, 20, 5);
    defer term2.deinit();

    term1.write("Line 1\n");
    term1.write("Line 2\n");
    term1.write("Line 3");

    term2.write("Line 1\n");
    term2.write("Line X\n"); // Different
    term2.write("Line 3");

    var diff = try term1.diff(&term2, testing.allocator);
    defer diff.deinit(testing.allocator);

    try testing.expect(diff.hasDifferences());
    try testing.expectEqual(@as(usize, 1), diff.changedLines.len);
    try testing.expectEqual(@as(u16, 1), diff.changedLines[0]); // Line 2 is different
}
