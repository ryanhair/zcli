const std = @import("std");
const testing = std.testing;
const vterm = @import("../vterm.zig");
const VTerm = vterm.VTerm;

test "basic terminal state capture" {
    var term = try VTerm.init(testing.allocator, 5, 3);
    defer term.deinit();

    term.write("Hello");

    var state = try term.captureState(testing.allocator);
    defer state.deinit(testing.allocator);

    // Content should be single string
    try testing.expect(state.content.len == 15); // 5*3 chars
    try testing.expectEqual(@as(u16, 0), state.cursor.x); // Wrapped to next line
    try testing.expectEqual(@as(u16, 1), state.cursor.y);
    try testing.expectEqual(@as(u16, 5), state.dimensions.width);
    try testing.expectEqual(@as(u16, 3), state.dimensions.height);
}

test "terminal state capture stability" {
    var term = try VTerm.init(testing.allocator, 10, 2);
    defer term.deinit();

    term.write("Test");

    var state1 = try term.captureState(testing.allocator);
    defer state1.deinit(testing.allocator);
    var state2 = try term.captureState(testing.allocator);
    defer state2.deinit(testing.allocator);

    try testing.expectEqualStrings(state1.content, state2.content);
    try testing.expectEqual(state1.cursor.x, state2.cursor.x);
    try testing.expectEqual(state1.cursor.y, state2.cursor.y);
    try testing.expectEqual(state1.dimensions.width, state2.dimensions.width);
    try testing.expectEqual(state1.dimensions.height, state2.dimensions.height);
}
