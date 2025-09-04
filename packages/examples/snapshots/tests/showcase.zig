const std = @import("std");
const snapshot = @import("snapshot");

// Helper to run the demo executable and capture output
fn runDemo(allocator: std.mem.Allocator, args: []const []const u8) !struct { stdout: []u8, stderr: []u8 } {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = args,
        .max_output_bytes = 1024 * 1024,
    });

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

// Test 1: Default snapshot testing with masking and ANSI preservation
test "default snapshot behavior - colors with masking" {
    const allocator = std.testing.allocator;

    const result = try runDemo(allocator, &.{ "zig-out/bin/snapshot-demo", "colors" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Default options: mask=true, ansi=true
    // This preserves ANSI colors and masks any dynamic content
    try snapshot.expectSnapshot(result.stdout, @src(), "colors_default", .{});
}

// Test 2: Plain text only - no ANSI, no masking
test "plain text snapshot - strip colors and no masking" {
    const allocator = std.testing.allocator;

    const result = try runDemo(allocator, &.{ "zig-out/bin/snapshot-demo", "colors" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Strip ANSI colors and don't mask anything
    try snapshot.expectSnapshot(result.stdout, @src(), "colors_plain", .{ .ansi = false, .mask = false });
}

// Test 3: ANSI preserved but no masking
test "colors preserved but no masking" {
    const allocator = std.testing.allocator;

    const result = try runDemo(allocator, &.{ "zig-out/bin/snapshot-demo", "table" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Keep ANSI colors but don't mask any content
    try snapshot.expectSnapshot(result.stdout, @src(), "table_with_colors", .{ .mask = false });
}

// Test 4: Dynamic content masking showcase
test "dynamic content masking" {

    // Create controlled dynamic content to show what gets masked
    const dynamic_content =
        \\User ID: 550e8400-e29b-41d4-a716-446655440000
        \\Timestamp: 1705312245
        \\ISO Time: 2024-01-15T10:30:45.123Z
        \\Memory address: 0x7fff5fbff710
        \\Pointer: 0x12345abcdef
        \\Session: sess_a1b2c3d4e5f67890
        \\Request ID: req_12345678
        \\
    ;

    // This will mask UUIDs, ISO timestamps, memory addresses automatically
    // Note: Plain integer timestamps and custom prefixed IDs are NOT masked
    try snapshot.expectSnapshot(dynamic_content, @src(), "dynamic_masked", .{});
}

// Test 5: Real dynamic executable output (shows masking limitations)
test "real dynamic output demonstration" {
    const allocator = std.testing.allocator;

    const result = try runDemo(allocator, &.{ "zig-out/bin/snapshot-demo", "dynamic" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // This demonstrates that our masking catches some but not all dynamic content
    // UUIDs and ISO timestamps will be masked, but integer timestamps and
    // custom session IDs will vary between runs

    // Verify the content contains expected patterns
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "User ID:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Timestamp:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "0x") != null);

    // Note: This is intentionally NOT snapshot tested to show the real-world
    // challenge of dynamic content that varies between test runs
}

// Test 6: Structured data (JSON) - perfect for plain snapshots
test "json output snapshot" {
    const allocator = std.testing.allocator;

    const result = try runDemo(allocator, &.{ "zig-out/bin/snapshot-demo", "json" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // JSON doesn't need ANSI processing or masking
    try snapshot.expectSnapshot(result.stdout, @src(), "json_output", .{ .ansi = false, .mask = false });
}

// Test 7: Log output with timestamps - great for masking demo
test "log output with timestamp masking" {
    const allocator = std.testing.allocator;

    const result = try runDemo(allocator, &.{ "zig-out/bin/snapshot-demo", "logs" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Logs contain timestamps and UUIDs that should be masked
    try snapshot.expectSnapshot(result.stdout, @src(), "logs_masked", .{});
}

// Test 8: Help output - clean text example
test "help text snapshot" {
    const allocator = std.testing.allocator;

    const result = try runDemo(allocator, &.{ "zig-out/bin/snapshot-demo", "help" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Help text is static and goes to stderr
    try snapshot.expectSnapshot(result.stderr, @src(), "help_output", .{ .ansi = false, .mask = false });
}

// Test 9: Error output with colors
test "error output with colors" {
    const allocator = std.testing.allocator;

    const result = try runDemo(allocator, &.{ "zig-out/bin/snapshot-demo", "invalid" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Error messages with ANSI colors
    try snapshot.expectSnapshot(result.stderr, @src(), "error_with_colors", .{});
}

// Test 10: Utility functions demonstration
test "utility functions showcase" {
    const allocator = std.testing.allocator;

    // Test dynamic content masking utility
    const dynamic_text = "User 550e8400-e29b-41d4-a716-446655440000 logged in at 2024-01-15T10:30:45.123Z from 0x7fff5fbff710";
    const masked = try snapshot.maskDynamicContent(allocator, dynamic_text);
    defer allocator.free(masked);

    try snapshot.expectSnapshot(masked, @src(), "utility_masked", .{ .ansi = false, .mask = false });

    // Test ANSI stripping utility
    const ansi_text = "\x1b[32mGreen\x1b[0m and \x1b[31mRed\x1b[0m text";
    const stripped = try snapshot.stripAnsi(allocator, ansi_text);
    defer allocator.free(stripped);

    try snapshot.expectSnapshot(stripped, @src(), "utility_stripped", .{ .ansi = false, .mask = false });
}

// Test 11: Complex mixed content
test "complex mixed content showcase" {
    const allocator = std.testing.allocator;

    // Create complex content that has both ANSI and dynamic elements
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    try output.writer().print("\x1b[34m[INFO]\x1b[0m Session 550e8400-e29b-41d4-a716-446655440000 started\n", .{});
    try output.writer().print("\x1b[33m[WARN]\x1b[0m Memory usage at 0x7fff5fbff710: high\n", .{});
    try output.writer().print("\x1b[32m[SUCCESS]\x1b[0m Operation completed at 2024-01-15T10:30:45.123Z\n", .{});

    // Test different option combinations
    try snapshot.expectSnapshot(output.items, @src(), "mixed_full", .{}); // Default: mask + ansi
    try snapshot.expectSnapshot(output.items, @src(), "mixed_colors_only", .{ .mask = false }); // ANSI but no masking
    try snapshot.expectSnapshot(output.items, @src(), "mixed_masked_plain", .{ .ansi = false }); // Masked but no ANSI
}

// Test 12: Performance and edge cases
test "edge cases and special content" {
    // Empty content
    try snapshot.expectSnapshot("", @src(), "empty_content", .{});

    // Only whitespace
    try snapshot.expectSnapshot("   \n  \t\n   ", @src(), "whitespace_only", .{});

    // Very long lines (should be truncated in diff output)
    const long_line = "This is a very long line that should be truncated in the diff output when there are mismatches because it exceeds the reasonable display width for terminal output and would make the diff hard to read";
    try snapshot.expectSnapshot(long_line, @src(), "long_line", .{});

    // Multiple consecutive ANSI codes
    const complex_ansi = "\x1b[1m\x1b[32m\x1b[4mBold Green Underlined\x1b[0m\x1b[0m\x1b[0m Normal";
    try snapshot.expectSnapshot(complex_ansi, @src(), "complex_ansi", .{});
}
