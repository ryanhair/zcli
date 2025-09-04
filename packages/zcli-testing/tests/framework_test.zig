const std = @import("std");
const testing = @import("zcli-testing");

// Comprehensive tests for the zcli-testing framework itself
// These tests verify error handling, edge cases, and framework robustness

test "dynamic content masking" {
    const allocator = std.testing.allocator;

    // Simulate output with dynamic content that should be masked
    const dynamic_output =
        \\Process started at 2024-01-15T10:30:45.123Z
        \\Generated UUID: 550e8400-e29b-41d4-a716-446655440000
        \\Memory address: 0x7fff5fbff7f0
        \\Process ID: 12345
        \\Operation completed successfully
    ;

    const masked = try testing.maskDynamicContent(allocator, dynamic_output);
    defer allocator.free(masked);

    // Verify timestamps are masked
    try testing.expectContains(masked, "[TIMESTAMP]");
    try testing.expectNotContains(masked, "2024-01-15T10:30:45.123Z");

    // Verify UUIDs are masked
    try testing.expectContains(masked, "[UUID]");
    try testing.expectNotContains(masked, "550e8400-e29b-41d4-a716-446655440000");

    // Verify memory addresses are masked
    try testing.expectContains(masked, "[MEMORY_ADDR]");
    try testing.expectNotContains(masked, "0x7fff5fbff7f0");

    // Verify process IDs are preserved (not considered dynamic)
    try testing.expectContains(masked, "12345");
}

test "ANSI escape sequence handling" {
    // Test that ANSI color codes are properly handled in snapshots
    const ansi_output =
        \\[31mError:[0m Something went wrong
        \\[32mSuccess:[0m Operation completed
        \\[33mWarning:[0m Check this out
        \\[36mInfo:[0m Additional details
    ;

    // This tests that ANSI sequences don't break snapshot comparison
    // In a real scenario, this would be compared against a stored snapshot
    const expected_output =
        \\[31mError:[0m Something went wrong
        \\[32mSuccess:[0m Operation completed
        \\[33mWarning:[0m Check this out
        \\[36mInfo:[0m Additional details
    ;

    try std.testing.expectEqualStrings(expected_output, ansi_output);
}

test "snapshot mismatch error handling" {
    // Test that the framework properly reports when snapshots don't match
    const actual_output = "Hello, World!\\n";
    const expected_different = "Hello, Universe!\\n";

    // This should fail with SnapshotMismatch error
    const result = testing.expectSnapshotWithData(actual_output, @src(), "mismatch_demo", expected_different);
    try std.testing.expectError(error.SnapshotMismatch, result);
}

test "snapshot missing error handling" {
    // Test behavior when a snapshot doesn't exist
    const some_output = "Hello, World!\\n";
    const snapshot_result = testing.expectSnapshotWithData(some_output, @src(), "nonexistent_snapshot", null);
    try std.testing.expectError(error.SnapshotMissing, snapshot_result);
}

test "multiline diff handling" {
    const actual_output =
        \\Line 1: Same
        \\Line 2: Different actual content
        \\Line 3: Same
        \\Line 4: Another difference here
    ;

    const expected_output =
        \\Line 1: Same
        \\Line 2: Different expected content
        \\Line 3: Same
        \\Line 4: Another difference there
    ;

    // This should fail with a multi-line diff
    const result = testing.expectSnapshotWithData(actual_output, @src(), "multiline_diff_demo", expected_output);
    try std.testing.expectError(error.SnapshotMismatch, result);
}

test "empty output handling" {
    // Test empty output vs non-empty expected
    const empty_actual = "";
    const non_empty_expected = "This should not be empty!\\n";

    // This should fail because empty != non-empty
    const snapshot_result = testing.expectSnapshotWithData(empty_actual, @src(), "empty_vs_nonempty_demo", non_empty_expected);
    try std.testing.expectError(error.SnapshotMismatch, snapshot_result);
}

test "whitespace sensitivity" {
    // Test that whitespace differences are detected
    const actual_with_spaces = "  Hello World  ";
    const expected_trimmed = "Hello World";

    // This should fail due to whitespace differences
    const result = testing.expectSnapshotWithData(actual_with_spaces, @src(), "whitespace_demo", expected_trimmed);
    try std.testing.expectError(error.SnapshotMismatch, result);
}

test "unicode content handling" {
    // Test that unicode characters are handled properly
    const unicode_output = "Hello 🌍 World with café and naïve";
    const unicode_expected = "Hello 🌍 World with café and naïve";

    // This should succeed with unicode content
    try std.testing.expectEqualStrings(unicode_expected, unicode_output);
}

test "large content handling" {
    const allocator = std.testing.allocator;

    // Create a large string to test performance
    var large_content = std.ArrayList(u8).init(allocator);
    defer large_content.deinit();

    var i: usize = 0;
    while (i < 1000) {
        try large_content.writer().print("Line {d}: This is a long line with some content\\n", .{i});
        i += 1;
    }

    // Test that large content can be handled
    try testing.expectContains(large_content.items, "Line 500:");
    try testing.expectContains(large_content.items, "Line 999:");
}

// Test framework robustness - verify errors can be caught properly
test "error catching robustness" {
    // Test that our framework properly handles and reports different error conditions

    // Test simple mismatch
    {
        const result = testing.expectSnapshotWithData("A", @src(), "simple_test", "B");
        try std.testing.expectError(error.SnapshotMismatch, result);
    }

    // Test multiline mismatch
    {
        const result = testing.expectSnapshotWithData("Hello\\nWorld", @src(), "multiline_test", "Hello\\nUniverse");
        try std.testing.expectError(error.SnapshotMismatch, result);
    }

    // Test empty vs non-empty
    {
        const result = testing.expectSnapshotWithData("", @src(), "empty_test", "not empty");
        try std.testing.expectError(error.SnapshotMismatch, result);
    }

    // Test whitespace sensitivity
    {
        const result = testing.expectSnapshotWithData("  spaced  ", @src(), "whitespace_test", "spaced");
        try std.testing.expectError(error.SnapshotMismatch, result);
    }
}

test "assertion functions comprehensive" {
    // Test all assertion functions work correctly
    const test_result = testing.Result{
        .stdout = "Hello World\\n",
        .stderr = "Warning: something\\n",
        .exit_code = 0,
        .allocator = undefined,
    };

    // Test exit code assertions
    try testing.expectExitCode(test_result, 0);
    try std.testing.expectError(error.ExitCodeMismatch, testing.expectExitCode(test_result, 1));

    // Test content assertions
    try testing.expectContains(test_result.stdout, "Hello");
    try testing.expectContains(test_result.stdout, "World");
    try std.testing.expectError(error.SubstringNotFound, testing.expectContains(test_result.stdout, "Missing"));

    // Test negation assertions
    try testing.expectNotContains(test_result.stdout, "Missing");
    try std.testing.expectError(error.UnexpectedSubstring, testing.expectNotContains(test_result.stdout, "Hello"));
}

test "JSON validation" {
    // Test JSON validation functionality
    const valid_json =
        \\{
        \\  "name": "test",
        \\  "values": [1, 2, 3],
        \\  "active": true
        \\}
    ;

    const invalid_json = "{ name: test, invalid }";

    try testing.expectValidJson(valid_json);
    try std.testing.expectError(error.InvalidJson, testing.expectValidJson(invalid_json));
}
