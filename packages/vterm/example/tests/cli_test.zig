const std = @import("std");
const testing = std.testing;
const vterm = @import("vterm");
const VTerm = vterm.VTerm;

// Helper to simulate CLI output
fn simulateCliOutput(term: *VTerm, args: []const []const u8) !void {
    // This simulates what the CLI would output for given args
    const cmd = if (args.len > 0) args[0] else "";

    if (std.mem.eql(u8, cmd, "help")) {
        try simulateHelp(term);
    } else if (std.mem.eql(u8, cmd, "version")) {
        try simulateVersion(term);
    } else if (std.mem.eql(u8, cmd, "list")) {
        try simulateList(term, args[1..]);
    } else if (std.mem.eql(u8, cmd, "status")) {
        try simulateStatus(term);
    } else if (cmd.len == 0) {
        term.write("Usage: demo-cli <command> [options]\n");
        term.write("Try 'demo-cli help' for more information.\n");
    } else {
        term.write("\x1b[31mError:\x1b[0m Unknown command '");
        term.write(cmd);
        term.write("'\n");
        term.write("Try 'demo-cli help' for a list of available commands.\n");
    }
}

fn simulateHelp(term: *VTerm) !void {
    term.write("\x1b[1;34mDemo CLI Tool v1.0.0\x1b[0m\n");
    term.write("\x1b[90m");
    for (0..60) |_| term.write("=");
    term.write("\x1b[0m\n\n");

    term.write("\x1b[1mUSAGE:\x1b[0m\n");
    term.write("  demo-cli <command> [options]\n\n");

    term.write("\x1b[1mCOMMANDS:\x1b[0m\n");
    term.write("  \x1b[32mhelp\x1b[0m       Show this help message\n");
    term.write("  \x1b[32mversion\x1b[0m    Show version information\n");
    term.write("  \x1b[32mlist\x1b[0m       List items (use -v for verbose)\n");
    term.write("  \x1b[32mstatus\x1b[0m     Show current status\n\n");

    term.write("\x1b[1mOPTIONS:\x1b[0m\n");
    term.write("  \x1b[33m-h, --help\x1b[0m     Show help for a command\n");
    term.write("  \x1b[33m-v, --verbose\x1b[0m  Enable verbose output\n\n");

    term.write("\x1b[1mEXAMPLES:\x1b[0m\n");
    term.write("  demo-cli list\n");
    term.write("  demo-cli list -v\n");
    term.write("  demo-cli status\n");
}

fn simulateVersion(term: *VTerm) !void {
    term.write("demo-cli version 1.0.0\n");
    term.write("Built with Zig\n");
}

fn simulateList(term: *VTerm, args: []const []const u8) !void {
    var verbose = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        }
    }

    term.write("\x1b[1mListing items:\x1b[0m\n");

    const items = [_][]const u8{ "config.json", "data.txt", "README.md" };

    for (items, 0..) |item, i| {
        if (verbose) {
            var buf: [100]u8 = undefined;
            const line = try std.fmt.bufPrint(&buf, "  [{d}] \x1b[36m{s}\x1b[0m (file)\n", .{ i + 1, item });
            term.write(line);
        } else {
            term.write("  ");
            term.write(item);
            term.write("\n");
        }
    }

    term.write("\n");
    term.write("Total: 3 items\n");
}

fn simulateStatus(term: *VTerm) !void {
    // Clear screen and move cursor home
    term.write("\x1b[2J\x1b[H");

    term.write("\x1b[1;35m[STATUS REPORT]\x1b[0m\n\n");
    term.write("System: \x1b[32m● Online\x1b[0m\n");
    term.write("Database: \x1b[32m● Connected\x1b[0m\n");
    term.write("API: \x1b[33m● Warning\x1b[0m (high latency)\n");
    term.write("Cache: \x1b[31m● Error\x1b[0m (needs restart)\n");

    // Move cursor to specific position
    term.write("\x1b[6;1H\n");
    term.write("Last updated: just now\n");
}

// ============================================================================
// Actual Tests Using VTerm Testing API
// ============================================================================

test "help command displays usage information" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    try simulateCliOutput(&term, &.{"help"});

    // Test that help text is displayed
    try testing.expect(term.containsText("Demo CLI Tool"));
    try testing.expect(term.containsText("USAGE:"));
    try testing.expect(term.containsText("COMMANDS:"));
    try testing.expect(term.containsText("help"));
    try testing.expect(term.containsText("version"));
    try testing.expect(term.containsText("list"));
    try testing.expect(term.containsText("status"));
}

test "version command shows version info" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    try simulateCliOutput(&term, &.{"version"});

    try testing.expect(term.containsText("demo-cli version 1.0.0"));
    try testing.expect(term.containsText("Built with Zig"));
}

test "list command shows items" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    try simulateCliOutput(&term, &.{"list"});

    try testing.expect(term.containsText("Listing items:"));
    try testing.expect(term.containsText("config.json"));
    try testing.expect(term.containsText("data.txt"));
    try testing.expect(term.containsText("README.md"));
    try testing.expect(term.containsText("Total: 3 items"));
}

test "list command with verbose flag" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    try simulateCliOutput(&term, &.{ "list", "-v" });

    try testing.expect(term.containsText("[1]"));
    try testing.expect(term.containsText("[2]"));
    try testing.expect(term.containsText("[3]"));
    try testing.expect(term.containsText("(file)"));
}

test "status command clears screen and shows status" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // Put some initial content
    term.write("Initial content that should be cleared\n");

    try simulateCliOutput(&term, &.{"status"});

    // Screen should be cleared, so initial content is gone
    try testing.expect(!term.containsText("Initial content"));

    // Status content should be shown
    try testing.expect(term.containsText("[STATUS REPORT]"));
    try testing.expect(term.containsText("System:"));
    try testing.expect(term.containsText("Online"));
    try testing.expect(term.containsText("Database:"));
    try testing.expect(term.containsText("Connected"));

    // Cursor should have been moved
    try testing.expect(term.containsText("Last updated: just now"));
}

test "unknown command shows error" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    try simulateCliOutput(&term, &.{"invalid"});

    try testing.expect(term.containsText("Error:"));
    try testing.expect(term.containsText("Unknown command 'invalid'"));
    try testing.expect(term.containsText("Try 'demo-cli help'"));
}

test "no arguments shows usage" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    try simulateCliOutput(&term, &.{});

    try testing.expect(term.containsText("Usage: demo-cli"));
    try testing.expect(term.containsText("Try 'demo-cli help'"));
}

test "captureState captures terminal state" {
    var term = try VTerm.init(testing.allocator, 40, 10);
    defer term.deinit();

    term.write("Hello World");
    term.write("\x1b[2;5H"); // Move cursor to row 2, col 5
    term.write("Test");

    // Capture terminal state
    var state = try term.captureState(testing.allocator);
    defer state.deinit(testing.allocator);

    // Debug: print actual cursor position
    // std.debug.print("\nActual cursor: ({}, {})\n", .{state.cursor.x, state.cursor.y});

    // Verify state captured everything
    try testing.expectEqual(@as(u16, 8), state.cursor.x); // After "Test" (col 5 + 4 chars)
    try testing.expectEqual(@as(u16, 1), state.cursor.y); // Row 2 (0-indexed)
    try testing.expectEqual(@as(u16, 40), state.dimensions.width);
    try testing.expectEqual(@as(u16, 10), state.dimensions.height);

    // Content should be captured
    try testing.expect(state.content.len == 400); // 40*10
}

test "getAllText extracts complete terminal content" {
    var term = try VTerm.init(testing.allocator, 10, 3);
    defer term.deinit();

    term.write("Line 1\n");
    term.write("Line 2\n");
    term.write("Line 3");

    const text = try term.getAllText(testing.allocator);
    defer testing.allocator.free(text);

    // Total should be 30 chars (10*3)
    try testing.expectEqual(@as(usize, 30), text.len);
}

test "getLine extracts specific lines" {
    var term = try VTerm.init(testing.allocator, 20, 5);
    defer term.deinit();

    term.write("First line\n");
    term.write("Second line\n");
    term.write("Third line");

    const line0 = try term.getLine(testing.allocator, 0);
    defer testing.allocator.free(line0);
    const line1 = try term.getLine(testing.allocator, 1);
    defer testing.allocator.free(line1);
    const line2 = try term.getLine(testing.allocator, 2);
    defer testing.allocator.free(line2);

    try testing.expect(std.mem.startsWith(u8, line0, "First line"));
    try testing.expect(std.mem.startsWith(u8, line1, "Second line"));
    try testing.expect(std.mem.startsWith(u8, line2, "Third line"));
}

test "cursorAt validates cursor position" {
    var term = try VTerm.init(testing.allocator, 40, 10);
    defer term.deinit();

    // Initial position
    try testing.expect(term.cursorAt(0, 0));

    // Write and check position
    term.write("Hello");
    try testing.expect(term.cursorAt(5, 0));

    // Move cursor explicitly
    term.write("\x1b[5;10H"); // Row 5, Col 10
    try testing.expect(term.cursorAt(9, 4)); // 0-indexed
    try testing.expect(!term.cursorAt(0, 0)); // Not at origin anymore
}

test "ANSI color codes are parsed correctly" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // Text with various ANSI codes
    term.write("\x1b[31mRed text\x1b[0m ");
    term.write("\x1b[1;32mBold green\x1b[0m ");
    term.write("\x1b[4;34mUnderlined blue\x1b[0m");

    // Text should be present regardless of formatting
    try testing.expect(term.containsText("Red text"));
    try testing.expect(term.containsText("Bold green"));
    try testing.expect(term.containsText("Underlined blue"));
}

test "expectOutput helper function works" {
    // Test the static helper
    const input = "Test";
    const expected = "Test" ++ " " ** (80 * 24 - 4);
    try VTerm.expectOutput(input, expected);
}

// ============================================================================
// NEW: Advanced VTerm Features Demo
// ============================================================================

test "attribute testing - verify colors and formatting" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    // Simulate error output with red text
    term.write("\x1b[31mError:\x1b[0m Command failed\n");
    term.write("\x1b[1mBold warning\x1b[0m\n");
    term.write("\x1b[4mUnderlined text\x1b[0m");

    // Test color detection
    try testing.expectEqual(vterm.Color.red, term.getTextColor(0, 0)); // 'E' is red
    try testing.expectEqual(vterm.Color.default, term.getTextColor(7, 0)); // Space after reset

    // Test attribute detection
    try testing.expect(term.hasAttribute(0, 1, .bold)); // 'B' in "Bold" is bold
    try testing.expect(!term.hasAttribute(0, 0, .bold)); // 'E' in "Error" is not bold
    try testing.expect(term.hasAttribute(0, 2, .underline)); // 'U' in "Underlined" is underlined
}

test "pattern matching - wildcards and regex-like patterns" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    term.write("Processing file_001.txt\n");
    term.write("Processing file_002.log\n");
    term.write("Error at line 42\n");
    term.write("    Warning: deprecated function"); // Add indentation

    // Test wildcard patterns
    try testing.expect(term.containsPattern("file_*.txt")); // Glob pattern
    try testing.expect(term.containsPattern("file_00?.txt")); // Single char wildcard
    try testing.expect(!term.containsPattern("file_00?.dat")); // Should not match

    // Test regex-like patterns
    try testing.expect(term.containsPattern("Error.*line")); // .* matches anything
    try testing.expect(term.containsPattern("Warning:.*function")); // Another .* pattern

    // Test line anchors
    try testing.expect(term.containsPattern("^Processing")); // Line start
    try testing.expect(term.containsPattern("function$")); // Line end

    // Debug: let's see what the terminal content looks like
    const debug_content = try term.getAllText(testing.allocator);
    defer testing.allocator.free(debug_content);
    // std.debug.print("\nTerminal content: '{s}'\n", .{debug_content});

    try testing.expect(!term.containsPattern("^Warning")); // Not at start of line
}

test "case-insensitive search" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();

    term.write("ERROR: System malfunction\n");
    term.write("Warning: Check configuration\n");
    term.write("INFO: Process completed");

    // Test case-insensitive matching
    try testing.expect(term.containsTextIgnoreCase("error: system"));
    try testing.expect(term.containsTextIgnoreCase("WARNING: check"));
    try testing.expect(term.containsTextIgnoreCase("Info: Process"));
    try testing.expect(!term.containsTextIgnoreCase("debug: trace"));
}

test "region testing - verify UI layout components" {
    var term = try VTerm.init(testing.allocator, 40, 10);
    defer term.deinit();

    // Simulate a CLI dashboard with box drawing
    term.write("┌────────────────────┐\n");
    term.write("│     Status Panel   │\n");
    term.write("├────────────────────┤\n");
    term.write("│ CPU:  45%          │\n");
    term.write("│ RAM:  67%          │\n");
    term.write("│ DISK: 23%          │\n");
    term.write("└────────────────────┘\n");
    term.write("Last updated: 12:34");

    // Test the header region
    const header_expected =
        \\┌────────────────────┐
        \\│     Status Panel   │
        \\├────────────────────┤
    ;
    try term.expectRegionEquals(0, 0, 22, 3, header_expected);

    // Test the metrics region
    const metrics_expected =
        \\│ CPU:  45%          │
        \\│ RAM:  67%          │
        \\│ DISK: 23%          │
    ;
    try term.expectRegionEquals(0, 3, 22, 3, metrics_expected);

    // Test region-specific text search
    try testing.expect(term.containsTextInRegion("Status Panel", 0, 0, 22, 3));
    try testing.expect(term.containsTextInRegion("CPU:", 0, 3, 22, 3));
    try testing.expect(!term.containsTextInRegion("Last updated", 0, 0, 22, 6)); // Not in top region
}

test "pattern finding - locate specific matches" {
    var term = try VTerm.init(testing.allocator, 60, 10);
    defer term.deinit();

    term.write("Log entry 1: INFO - System started\n");
    term.write("Log entry 2: ERROR - Database failed\n");
    term.write("Log entry 3: WARN - Memory low");

    // Find all ERROR patterns
    const error_positions = try term.findPattern(testing.allocator, "ERROR");
    defer testing.allocator.free(error_positions);

    try testing.expect(error_positions.len > 0);
    // Error should be found on line 2 (1-indexed becomes 1 in 0-indexed)
    try testing.expectEqual(@as(u16, 1), error_positions[0].y);
}

test "terminal comparison - diff functionality" {
    var term1 = try VTerm.init(testing.allocator, 30, 5);
    defer term1.deinit();
    var term2 = try VTerm.init(testing.allocator, 30, 5);
    defer term2.deinit();

    // Set up similar but different content
    term1.write("Application Status\n");
    term1.write("Server: Running\n");
    term1.write("Database: Connected");

    term2.write("Application Status\n");
    term2.write("Server: Stopped\n"); // Different!
    term2.write("Database: Connected");

    // Compare terminals
    var diff = try term1.diff(&term2, testing.allocator);
    defer diff.deinit(testing.allocator);

    try testing.expect(diff.hasDifferences());
    try testing.expectEqual(@as(usize, 1), diff.changedLines.len);
    try testing.expectEqual(@as(u16, 1), diff.changedLines[0]); // Line 2 differs
}

test "terminal state testing - capture and analyze state" {
    var term = try VTerm.init(testing.allocator, 25, 8);
    defer term.deinit();

    // Simulate interactive CLI state
    term.write("$ demo-cli status\n");
    term.write("┌─── System Info ───┐\n");
    term.write("│ Status: Online    │\n");
    term.write("│ Uptime: 5h 23m    │\n");
    term.write("└───────────────────┘\n");
    term.write("$ "); // Command prompt

    // Capture terminal state
    var state = try term.captureState(testing.allocator);
    defer state.deinit(testing.allocator);

    // Debug: check actual content length
    // std.debug.print("\nActual content length: {}, Expected: 200\n", .{state.content.len});

    // Verify state captured everything
    // Note: Content length will be more than width*height due to UTF-8 box drawing chars
    try testing.expect(state.content.len == 266); // Actual UTF-8 encoded length
    try testing.expectEqual(@as(u16, 2), state.cursor.x); // After "$ "
    try testing.expectEqual(@as(u16, 5), state.cursor.y); // On prompt line
    try testing.expectEqual(@as(u16, 25), state.dimensions.width);
    try testing.expectEqual(@as(u16, 8), state.dimensions.height);

    // Verify content is preserved
    try testing.expect(std.mem.indexOf(u8, state.content, "System Info") != null);
    try testing.expect(std.mem.indexOf(u8, state.content, "Status: Online") != null);
}
