const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner.zig");

/// Assert that the exit code matches expected value
pub fn expectExitCode(result: runner.Result, expected: u8) !void {
    if (result.exit_code != expected) {
        if (!builtin.is_test) std.debug.print("\nExpected exit code {d}, but got {d}\n", .{ expected, result.exit_code });
        if (result.stderr.len > 0) {
            if (!builtin.is_test) std.debug.print("stderr: {s}\n", .{result.stderr});
        }
        return error.ExitCodeMismatch;
    }
}

/// Assert that the exit code does not match a value
pub fn expectExitCodeNot(result: runner.Result, not_expected: u8) !void {
    if (result.exit_code == not_expected) {
        if (!builtin.is_test) std.debug.print("\nExpected exit code to not be {d}, but it was\n", .{not_expected});
        return error.UnexpectedExitCode;
    }
}

/// Assert that stdout is empty
pub fn expectStdoutEmpty(result: runner.Result) !void {
    if (result.stdout.len > 0) {
        if (!builtin.is_test) std.debug.print("\nExpected stdout to be empty, but got:\n{s}\n", .{result.stdout});
        return error.StdoutNotEmpty;
    }
}

/// Assert that stderr is empty
pub fn expectStderrEmpty(result: runner.Result) !void {
    if (result.stderr.len > 0) {
        if (!builtin.is_test) std.debug.print("\nExpected stderr to be empty, but got:\n{s}\n", .{result.stderr});
        return error.StderrNotEmpty;
    }
}

/// Assert that output contains a substring
pub fn expectContains(output: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, output, needle) == null) {
        if (!builtin.is_test) std.debug.print("\nExpected output to contain:\n  '{s}'\n\nActual output:\n{s}\n", .{ needle, output });
        return error.SubstringNotFound;
    }
}

/// Assert that output does not contain a substring
pub fn expectNotContains(output: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, output, needle) != null) {
        if (!builtin.is_test) std.debug.print("\nExpected output to NOT contain:\n  '{s}'\n\nActual output:\n{s}\n", .{ needle, output });
        return error.UnexpectedSubstring;
    }
}

/// Assert that output is valid JSON
pub fn expectValidJson(output: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, output, .{}) catch |err| {
        if (!builtin.is_test) std.debug.print("\nExpected valid JSON but got error: {}\n\nOutput:\n{s}\n", .{ err, output });
        return error.InvalidJson;
    };
    defer parsed.deinit();
}

test "expectExitCode" {
    const result = runner.Result{
        .stdout = "",
        .stderr = "",
        .exit_code = 0,
        .allocator = undefined,
    };

    try expectExitCode(result, 0);
    try std.testing.expectError(error.ExitCodeMismatch, expectExitCode(result, 1));
}

test "expectContains" {
    const output = "Hello, World!";

    try expectContains(output, "Hello");
    try expectContains(output, "World");
    try std.testing.expectError(error.SubstringNotFound, expectContains(output, "Goodbye"));
}

test "expectValidJson" {
    try expectValidJson(
        \\{"name": "test", "value": 42}
    );

    try std.testing.expectError(error.InvalidJson, expectValidJson("not json"));
}

test "expectStdoutEmpty" {
    const empty_result = runner.Result{
        .stdout = "",
        .stderr = "some error",
        .exit_code = 0,
        .allocator = undefined,
    };

    const non_empty_result = runner.Result{
        .stdout = "output",
        .stderr = "",
        .exit_code = 0,
        .allocator = undefined,
    };

    try expectStdoutEmpty(empty_result);
    try std.testing.expectError(error.StdoutNotEmpty, expectStdoutEmpty(non_empty_result));
}

test "expectStderrEmpty" {
    const empty_result = runner.Result{
        .stdout = "output",
        .stderr = "",
        .exit_code = 0,
        .allocator = undefined,
    };

    const non_empty_result = runner.Result{
        .stdout = "",
        .stderr = "error",
        .exit_code = 0,
        .allocator = undefined,
    };

    try expectStderrEmpty(empty_result);
    try std.testing.expectError(error.StderrNotEmpty, expectStderrEmpty(non_empty_result));
}

test "expectContains with edge cases" {
    // Empty string tests
    try expectContains("hello", ""); // Empty substring should always be found
    try std.testing.expectError(error.SubstringNotFound, expectContains("", "hello"));

    // Case sensitivity
    try expectContains("Hello World", "Hello");
    try std.testing.expectError(error.SubstringNotFound, expectContains("Hello World", "hello"));

    // Special characters
    try expectContains("Line 1\nLine 2\tTabbed", "\n");
    try expectContains("Line 1\nLine 2\tTabbed", "\t");
    try expectContains("Contains \"quotes\"", "\"quotes\"");

    // Unicode support
    try expectContains("Hello 🌍 World", "🌍");
    try expectContains("café", "é");
}

test "expectExitCode with various codes" {
    const success_result = runner.Result{
        .stdout = "",
        .stderr = "",
        .exit_code = 0,
        .allocator = undefined,
    };

    const error_result = runner.Result{
        .stdout = "",
        .stderr = "",
        .exit_code = 1,
        .allocator = undefined,
    };

    const signal_result = runner.Result{
        .stdout = "",
        .stderr = "",
        .exit_code = 130, // SIGINT
        .allocator = undefined,
    };

    // Test various exit codes
    try expectExitCode(success_result, 0);
    try expectExitCode(error_result, 1);
    try expectExitCode(signal_result, 130);

    // Test mismatches
    try std.testing.expectError(error.ExitCodeMismatch, expectExitCode(success_result, 1));
    try std.testing.expectError(error.ExitCodeMismatch, expectExitCode(error_result, 0));
}

test "expectValidJson with complex structures" {
    // Test various JSON structures
    try expectValidJson("null");
    try expectValidJson("true");
    try expectValidJson("false");
    try expectValidJson("42");
    try expectValidJson("\"string\"");
    try expectValidJson("[]");
    try expectValidJson("{}");

    // Complex nested structure
    try expectValidJson(
        \\{
        \\  "users": [
        \\    {
        \\      "id": 1,
        \\      "name": "John",
        \\      "active": true,
        \\      "metadata": {
        \\        "created": "2024-01-01",
        \\        "tags": ["admin", "user"]
        \\      }
        \\    }
        \\  ],
        \\  "count": 1
        \\}
    );

    // Test invalid JSON variations
    try std.testing.expectError(error.InvalidJson, expectValidJson("{"));
    try std.testing.expectError(error.InvalidJson, expectValidJson("{\"key\": }"));
    try std.testing.expectError(error.InvalidJson, expectValidJson("{\"key\": \"unclosed string}"));
    try std.testing.expectError(error.InvalidJson, expectValidJson("[1, 2, 3,]"));
}
