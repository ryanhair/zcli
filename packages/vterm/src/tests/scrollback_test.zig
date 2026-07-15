const std = @import("std");
const testing = std.testing;
const vterm = @import("../vterm.zig");
const VTerm = vterm.VTerm;

test "initWithScrollback creates buffer with correct size" {
    var term = try VTerm.initWithScrollback(testing.allocator, 80, 24, .{
        .scrollback_lines = 100,
    });
    defer term.deinit();

    // Should have space for scrollback_lines
    try testing.expectEqual(@as(u16, 100), term.scrollback_lines);
    try testing.expectEqual(@as(u16, 80), term.width);
    try testing.expectEqual(@as(u16, 24), term.height);

    // Buffer should be allocated for full scrollback
    try testing.expectEqual(@as(usize, 100 * 80), term.cells.len);
}

test "basic init uses default scrollback size" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // Should have reasonable default scrollback
    try testing.expectEqual(@as(u16, 1000), term.scrollback_lines);
}

test "viewport starts at bottom of buffer" {
    var term = try VTerm.initWithScrollback(testing.allocator, 80, 10, .{
        .scrollback_lines = 50,
    });
    defer term.deinit();

    // Viewport offset should be 0 (viewing bottom)
    try testing.expectEqual(@as(i32, 0), term.viewport_offset);

    // Cursor should be at top-left of viewport
    try testing.expectEqual(@as(u16, 0), term.cursor.x);
    try testing.expectEqual(@as(u16, 0), term.cursor.y);
}

test "getScrollbackPosition returns correct info" {
    var term = try VTerm.initWithScrollback(testing.allocator, 40, 5, .{
        .scrollback_lines = 20,
    });
    defer term.deinit();

    const pos = term.getScrollbackPosition();

    // Initially no lines written
    try testing.expectEqual(@as(u32, 0), pos.current_line);
    try testing.expectEqual(@as(u32, 0), pos.total_lines);
    try testing.expect(pos.at_bottom);
}

test "writing text updates total lines written" {
    var term = try VTerm.initWithScrollback(testing.allocator, 40, 5, .{
        .scrollback_lines = 20,
    });
    defer term.deinit();

    term.write("Line 1\n");
    term.write("Line 2\n");

    // Should track lines written (Line 1 goes to line 0, then \n creates line 1, Line 2 goes to line 1, then \n creates line 2, so we have 3 total)
    try testing.expectEqual(@as(u32, 3), term.total_lines_written);

    const pos = term.getScrollbackPosition();
    try testing.expectEqual(@as(u32, 3), pos.total_lines);
}

test "bufferLineIndex handles circular wrapping" {
    var term = try VTerm.initWithScrollback(testing.allocator, 40, 5, .{
        .scrollback_lines = 10,
    });
    defer term.deinit();

    // Absolute logical line → ring row (`line % scrollback_lines`), the one
    // mapping both writes and viewport reads share (#393).
    try testing.expectEqual(@as(u16, 0), term.bufferLineIndex(0));
    try testing.expectEqual(@as(u16, 5), term.bufferLineIndex(5));
    try testing.expectEqual(@as(u16, 0), term.bufferLineIndex(10)); // Wraps
    try testing.expectEqual(@as(u16, 3), term.bufferLineIndex(23)); // Second lap
}

// #393: the viewport must keep tracking the newest lines after the ring laps —
// the old capped getBottomLine desynced reads from writes once total lines
// passed a second multiple of scrollback_lines.
test "viewport stays on the newest lines after the ring laps repeatedly" {
    var term = try VTerm.initWithScrollback(testing.allocator, 20, 3, .{
        .scrollback_lines = 5,
    });
    defer term.deinit();

    // Write 10 lines (L0..L9): ring lapped once.
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        var buf: [8]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "L{d}\n", .{i}) catch unreachable;
        term.write(line);
    }
    // Total is 11 logical lines (the trailing \n opens an empty L10), so the
    // 3-row viewport shows L8, L9, and the empty line.
    try testing.expect(term.containsText("L8"));
    try testing.expect(term.containsText("L9"));
    try testing.expect(!term.containsText("L4"));

    // Continue to 23 lines (L10..L22): well into the second lap.
    while (i < 23) : (i += 1) {
        var buf: [8]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "L{d}\n", .{i}) catch unreachable;
        term.write(line);
    }
    try testing.expect(term.containsText("L21"));
    try testing.expect(term.containsText("L22"));
    try testing.expect(!term.containsText("L18")); // scrolled out of the viewport
}

test "viewportToBuffer converts viewport coords correctly" {
    var term = try VTerm.initWithScrollback(testing.allocator, 40, 5, .{
        .scrollback_lines = 20,
    });
    defer term.deinit();

    // Write some lines
    for (0..10) |_| {
        term.write("Test line\n");
    }

    // At bottom (viewport_offset = 0), with 11 total lines, visible lines are 6-10
    // y=4 (bottom of viewport) should map to line 10
    const buffer_line = term.viewportToBuffer(4);
    try testing.expect(buffer_line != null);
    try testing.expectEqual(@as(u16, 10), buffer_line.?);
}

test "viewport navigation scrolls through history" {
    var term = try VTerm.initWithScrollback(testing.allocator, 40, 5, .{
        .scrollback_lines = 20,
    });
    defer term.deinit();

    // Write 10 lines
    for (0..10) |i| {
        var buf: [20]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "Line {}\n", .{i});
        term.write(line);
    }

    // Should be at bottom showing lines 5-9
    try testing.expectEqual(@as(i32, 0), term.viewport_offset);

    // Scroll up 3 lines
    term.scrollViewportUp(3);
    try testing.expectEqual(@as(i32, -3), term.viewport_offset);

    // Should now show lines 2-6
    const pos = term.getScrollbackPosition();
    try testing.expect(!pos.at_bottom);

    // Scroll to bottom
    term.scrollToBottom();
    try testing.expectEqual(@as(i32, 0), term.viewport_offset);
    try testing.expect(term.getScrollbackPosition().at_bottom);
}

test "pageUp and pageDown scroll by viewport height" {
    var term = try VTerm.initWithScrollback(testing.allocator, 40, 5, .{
        .scrollback_lines = 50,
    });
    defer term.deinit();

    // Write 30 lines
    for (0..30) |_| {
        term.write("Line\n");
    }

    // Page up should scroll by height (5 lines)
    term.pageUp();
    try testing.expectEqual(@as(i32, -5), term.viewport_offset);

    // Page up again
    term.pageUp();
    try testing.expectEqual(@as(i32, -10), term.viewport_offset);

    // Page down
    term.pageDown();
    try testing.expectEqual(@as(i32, -5), term.viewport_offset);
}

test "cannot scroll beyond buffer limits" {
    var term = try VTerm.initWithScrollback(testing.allocator, 40, 5, .{
        .scrollback_lines = 20,
    });
    defer term.deinit();

    // Write 10 lines
    for (0..10) |_| {
        term.write("Line\n");
    }

    // Try to scroll up more than available history
    term.scrollViewportUp(20);
    // Should stop at max scroll (11 - 5 = 6 lines of history above viewport)
    try testing.expectEqual(@as(i32, -6), term.viewport_offset);

    // Try to scroll down past bottom
    term.scrollViewportDown(20);
    try testing.expectEqual(@as(i32, 0), term.viewport_offset);
}

test "writing new content auto-scrolls to bottom" {
    var term = try VTerm.initWithScrollback(testing.allocator, 40, 5, .{
        .scrollback_lines = 20,
    });
    defer term.deinit();

    // Write initial content
    for (0..10) |_| {
        term.write("Line\n");
    }

    // Scroll up to view history
    term.scrollViewportUp(5);
    try testing.expectEqual(@as(i32, -5), term.viewport_offset);

    // Writing new content should auto-scroll to bottom
    term.write("New line\n");
    try testing.expectEqual(@as(i32, 0), term.viewport_offset);
    try testing.expect(term.getScrollbackPosition().at_bottom);
}
