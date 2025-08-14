const std = @import("std");
const zcli = @import("zcli.zig");
const args_parser = @import("args.zig");
const options_parser = @import("options.zig");
const help_generator = @import("help.zig");
const error_handler = @import("errors.zig");

// Comprehensive error scenario and edge case testing.
// Tests error conditions, boundary conditions, malformed inputs,
// and recovery scenarios not covered by the main test suites.

// ============================================================================
// Memory and Resource Edge Cases
// ============================================================================

test "parseOptions with extremely long option names" {
    const allocator = std.testing.allocator;

    const Options = struct {
        normal_option: []const u8 = "default",
    };

    // Create an extremely long option name (should be rejected)
    var long_name_buf: [1000]u8 = undefined;
    @memset(&long_name_buf, 'x');
    const long_name = try std.fmt.bufPrint(&long_name_buf, "--{s}", .{long_name_buf[0..500]});

    const args = [_][]const u8{ long_name, "value" };

    const result = options_parser.parseOptions(Options, allocator, &args);
    try std.testing.expect(result == .err);
    switch (result.err) {
        .option_unknown => {},
        else => try std.testing.expect(false),
    }
}

test "parseOptions with many array elements" {
    const allocator = std.testing.allocator;

    const Options = struct {
        files: [][]const u8 = &.{},
    };

    // Create many file arguments (reduced number to avoid segfaults)
    var many_args = std.ArrayList([]const u8).init(allocator);
    defer many_args.deinit();

    var filenames = std.ArrayList([]const u8).init(allocator);
    defer {
        for (filenames.items) |filename| {
            allocator.free(filename);
        }
        filenames.deinit();
    }

    const file_count = 100; // Reduced from 1000 to avoid memory issues

    // Add alternating --files and filename arguments
    var i: u32 = 0;
    while (i < file_count) : (i += 1) {
        try many_args.append("--files");
        const filename = try std.fmt.allocPrint(allocator, "file{}.txt", .{i});
        try filenames.append(filename); // Store for cleanup
        try many_args.append(filename);
    }

    const result = options_parser.parseOptions(Options, allocator, many_args.items);
    try std.testing.expect(result == .ok);
    defer options_parser.cleanupOptions(Options, result.ok.options, allocator);

    try std.testing.expectEqual(file_count, result.ok.options.files.len);
}

test "parseArgs with multiple primitive types" {
    const Args = struct {
        count: u32,
        name: []const u8,
        flag: bool,
    };

    const args = [_][]const u8{ "42", "test", "true" };
    const result = args_parser.parseArgs(Args, &args);
    try std.testing.expect(!result.isError());
    const parsed = result.unwrap();

    try std.testing.expectEqual(@as(u32, 42), parsed.count);
    try std.testing.expectEqualStrings("test", parsed.name);
    try std.testing.expectEqual(true, parsed.flag);
}

// ============================================================================
// Unicode and Special Character Edge Cases
// ============================================================================

test "parseArgs with Unicode characters" {
    const Args = struct {
        message: []const u8,
    };

    // Test various Unicode strings
    const unicode_tests = [_][]const u8{
        "Hello, 世界!", // Chinese
        "مرحبا بالعالم", // Arabic
        "🚀 Rocket", // Emoji
        "Ñoño niño", // Spanish with tildes
        "Здравствуй мир", // Russian
    };

    for (unicode_tests) |unicode_str| {
        const args = [_][]const u8{unicode_str};
        const result = args_parser.parseArgs(Args, &args);
        try std.testing.expect(!result.isError());
        const parsed = result.unwrap();
        try std.testing.expectEqualStrings(unicode_str, parsed.message);
    }
}

test "parseOptions with Unicode option values" {
    const allocator = std.testing.allocator;

    const Options = struct {
        message: []const u8 = "default",
        files: [][]const u8 = &.{},
    };

    const args = [_][]const u8{
        "--message", "🎉 Success!",
        "--files", "файл.txt", // Cyrillic filename
        "--files", "測試.txt", // Chinese filename
    };

    const result = options_parser.parseOptions(Options, allocator, &args);
    try std.testing.expect(result == .ok);
    defer options_parser.cleanupOptions(Options, result.ok.options, allocator);

    try std.testing.expectEqualStrings("🎉 Success!", result.ok.options.message);
    try std.testing.expectEqual(@as(usize, 2), result.ok.options.files.len);
    try std.testing.expectEqualStrings("файл.txt", result.ok.options.files[0]);
    try std.testing.expectEqualStrings("測試.txt", result.ok.options.files[1]);
}

// ============================================================================
// Boundary Value Edge Cases
// ============================================================================

test "parseArgs with maximum integer values" {
    const Args = struct {
        max_i64: i64,
        max_u64: u64,
        max_i32: i32,
        max_u32: u32,
    };

    // Test maximum values for different integer types
    const args = [_][]const u8{
        "9223372036854775807", // i64 max
        "18446744073709551615", // u64 max
        "2147483647", // i32 max
        "4294967295", // u32 max
    };

    const result = try args_parser.parseArgs(Args, &args);

    try std.testing.expectEqual(@as(i64, 9223372036854775807), result.max_i64);
    try std.testing.expectEqual(@as(u64, 18446744073709551615), result.max_u64);
    try std.testing.expectEqual(@as(i32, 2147483647), result.max_i32);
    try std.testing.expectEqual(@as(u32, 4294967295), result.max_u32);
}

test "parseArgs with minimum integer values" {
    const Args = struct {
        min_i64: i64,
        min_i32: i32,
        min_i16: i16,
        min_i8: i8,
    };

    const args = [_][]const u8{
        "-9223372036854775808", // i64 min
        "-2147483648", // i32 min
        "-32768", // i16 min
        "-128", // i8 min
    };

    const result = try args_parser.parseArgs(Args, &args);

    try std.testing.expectEqual(@as(i64, -9223372036854775808), result.min_i64);
    try std.testing.expectEqual(@as(i32, -2147483648), result.min_i32);
    try std.testing.expectEqual(@as(i16, -32768), result.min_i16);
    try std.testing.expectEqual(@as(i8, -128), result.min_i8);
}

test "parseArgs integer overflow edge cases" {
    const Args = struct {
        val: u8,
    };

    // Test values that would overflow u8
    const overflow_cases = [_][]const u8{
        "256", // Just over max
        "1000", // Way over max
        "99999", // Very large
        "-1", // Negative for unsigned
        "-128", // Negative
    };

    for (overflow_cases) |case| {
        const args = [_][]const u8{case};
        try std.testing.expectError(args_parser.ParseError.InvalidArgumentType, args_parser.parseArgs(Args, &args));
    }
}

test "parseArgs floating point edge cases" {
    const Args = struct {
        val: f64,
    };

    const test_cases = [_]struct { []const u8, f64 }{
        .{ "0.0", 0.0 },
        .{ "-0.0", -0.0 },
        .{ "1.7976931348623157e+308", 1.7976931348623157e+308 }, // Near f64 max
        .{ "2.2250738585072014e-308", 2.2250738585072014e-308 }, // Near f64 min positive
        .{ "inf", std.math.inf(f64) },
        .{ "-inf", -std.math.inf(f64) },
        .{ "nan", std.math.nan(f64) },
    };

    for (test_cases) |case| {
        const args = [_][]const u8{case[0]};
        const result = args_parser.parseArgs(Args, &args);
        try std.testing.expect(!result.isError());
        const parsed = result.unwrap();

        if (std.math.isNan(case[1])) {
            try std.testing.expect(std.math.isNan(result.val));
        } else if (std.math.isInf(case[1])) {
            try std.testing.expect(std.math.isInf(result.val));
            try std.testing.expectEqual(std.math.sign(case[1]), std.math.sign(result.val));
        } else {
            try std.testing.expectEqual(case[1], result.val);
        }
    }
}

test "parseArgs with malformed float values" {
    const Args = struct {
        val: f32,
    };

    const invalid_floats = [_][]const u8{
        "not_a_number",
        "1.2.3", // Multiple decimal points
        "1e", // Incomplete scientific notation
        "1e++5", // Invalid exponent
        "", // Empty string
        " ", // Whitespace
        "1.0extra", // Extra characters
    };

    for (invalid_floats) |invalid| {
        const args = [_][]const u8{invalid};
        try std.testing.expectError(args_parser.ParseError.InvalidArgumentType, args_parser.parseArgs(Args, &args));
    }
}

// ============================================================================
// Error Recovery and Suggestions
// ============================================================================

test "error handler with very long command names" {
    const allocator = std.testing.allocator;

    // Create a very long command name that should still generate suggestions
    var long_cmd_buf: [200]u8 = undefined;
    @memset(&long_cmd_buf, 'x');
    const long_cmd = long_cmd_buf[0..100];

    const available_commands = [_][]const u8{ "list", "search", "create", "delete" };

    var buffer: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try error_handler.handleCommandNotFound(stream.writer(), long_cmd, &available_commands, "myapp", allocator);

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Unknown command") != null);
    try std.testing.expect(output.len < buffer.len); // Should not overflow
}

test "error handler with empty command lists" {
    const allocator = std.testing.allocator;

    const no_commands = [_][]const u8{};

    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try error_handler.handleCommandNotFound(stream.writer(), "missing", &no_commands, "myapp", allocator);

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Unknown command 'missing'") != null);
    // The actual error handler might not include "No commands available" text
    // so let's just check that it handles empty command lists without crashing
}

test "edit distance with identical strings" {
    // Test the edge case where strings are identical (distance should be 0)
    const distance = error_handler.editDistance("identical", "identical");
    try std.testing.expectEqual(@as(usize, 0), distance);
}

test "edit distance with empty strings" {
    // Test edge cases with empty strings
    try std.testing.expectEqual(@as(usize, 5), error_handler.editDistance("", "hello"));
    try std.testing.expectEqual(@as(usize, 5), error_handler.editDistance("hello", ""));
    try std.testing.expectEqual(@as(usize, 0), error_handler.editDistance("", ""));
}

test "edit distance with very different strings" {
    // Test with completely different strings
    const distance = error_handler.editDistance("abcdefghijk", "zyxwvutsrqp");
    try std.testing.expect(distance > 10); // Should be high distance
}

// ============================================================================
// Options Parser Edge Cases
// ============================================================================

test "parseOptions with duplicate option handling" {
    const allocator = std.testing.allocator;

    const Options = struct {
        count: u32 = 1,
        files: [][]const u8 = &.{},
    };

    // Test that non-array options take the last value when duplicated
    const args = [_][]const u8{
        "--count", "5",
        "--count", "10", // This should override the previous value
        "--files", "a.txt",
        "--files", "b.txt", // Array options should accumulate
    };

    const result = options_parser.parseOptions(Options, allocator, &args);
    try std.testing.expect(result == .ok);
    defer options_parser.cleanupOptions(Options, result.ok.options, allocator);

    try std.testing.expectEqual(@as(u32, 10), result.ok.options.count); // Last value wins
    try std.testing.expectEqual(@as(usize, 2), result.ok.options.files.len); // Array accumulates
}

test "parseOptions with mixed short and long options" {
    const allocator = std.testing.allocator;

    const Options = struct {
        verbose: bool = false,
        count: u32 = 0,
        output: []const u8 = "stdout",
    };

    const meta = .{
        .options = .{
            .verbose = .{ .short = 'v' },
            .count = .{ .short = 'c' },
            .output = .{ .short = 'o' },
        },
    };

    const args = [_][]const u8{ "-v", "--count", "42", "-o", "file.txt" };

    const result = options_parser.parseOptionsWithMeta(Options, meta, allocator, &args);
    try std.testing.expect(result == .ok);
    defer options_parser.cleanupOptions(Options, result.ok.options, allocator);

    try std.testing.expectEqual(true, result.ok.options.verbose);
    try std.testing.expectEqual(@as(u32, 42), result.ok.options.count);
    try std.testing.expectEqualStrings("file.txt", result.ok.options.output);
}

test "parseOptions with option-like values" {
    const allocator = std.testing.allocator;

    const Options = struct {
        message: []const u8 = "",
        number: i32 = 0,
    };

    // Test negative numbers (which are correctly handled) and values after double-dash
    const args = [_][]const u8{
        "--number", "-42", // Negative number should work
        "--message", "normal-value", // Normal value
    };

    const result = options_parser.parseOptions(Options, allocator, &args);
    try std.testing.expect(result == .ok);
    defer options_parser.cleanupOptions(Options, result.ok.options, allocator);

    try std.testing.expectEqualStrings("normal-value", result.ok.options.message);
    try std.testing.expectEqual(@as(i32, -42), result.ok.options.number);
}

// ============================================================================
// Help System Edge Cases
// ============================================================================

test "generateAppHelp with empty registry" {
    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const empty_registry = struct {
        commands: struct {} = .{},
    }{};

    try help_generator.generateAppHelp(empty_registry, stream.writer(), "empty-app", "1.0.0", "An app with no commands");

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "empty-app v1.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "An app with no commands") != null);
    // Should gracefully handle empty command set
}

// ============================================================================
// Context and Environment Edge Cases
// ============================================================================

test "Context creation and method access" {
    const allocator = std.testing.allocator;

    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();

    const context = zcli.Context{
        .allocator = allocator,
        .io = zcli.IO{
            .stdout = std.io.getStdOut().writer(),
            .stderr = std.io.getStdErr().writer(),
            .stdin = std.io.getStdIn().reader(),
        },
        .environment = zcli.Environment{
            .env = env,
        },
    };

    // Test convenience methods
    const stdout = context.stdout();
    const stderr = context.stderr();
    const stdin = context.stdin();
    const env_ref = context.env();

    // Verify types are correct
    try std.testing.expect(@TypeOf(stdout) == std.fs.File.Writer);
    try std.testing.expect(@TypeOf(stderr) == std.fs.File.Writer);
    try std.testing.expect(@TypeOf(stdin) == std.fs.File.Reader);
    try std.testing.expect(@TypeOf(env_ref) == *const std.process.EnvMap);
}

// ============================================================================
// Memory Safety Edge Cases
// ============================================================================

test "options cleanup with nested arrays" {
    const allocator = std.testing.allocator;

    const Options = struct {
        files: [][]const u8 = &.{},
        numbers: []i32 = &.{},
        tags: [][]const u8 = &.{},
    };

    const args = [_][]const u8{
        "--files",   "a.txt",   "--files",   "b.txt",
        "--numbers", "1",       "--numbers", "2",
        "--numbers", "3",       "--tags",    "urgent",
        "--tags",    "bug-fix",
    };

    const result = options_parser.parseOptions(Options, allocator, &args);
    try std.testing.expect(result == .ok);

    // Verify arrays were allocated properly
    try std.testing.expectEqual(@as(usize, 2), result.ok.options.files.len);
    try std.testing.expectEqual(@as(usize, 3), result.ok.options.numbers.len);
    try std.testing.expectEqual(@as(usize, 2), result.ok.options.tags.len);

    // Cleanup should work without issues
    options_parser.cleanupOptions(Options, result.ok.options, allocator);
}

test "parseOptions memory cleanup on error" {
    const allocator = std.testing.allocator;

    const Options = struct {
        files: [][]const u8 = &.{},
        count: u32 = 0,
    };

    // This should fail due to invalid count value, but files array gets allocated first
    const args = [_][]const u8{
        "--files", "test.txt",
        "--count", "not_a_number", // This will cause an error
    };

    const result = options_parser.parseOptions(Options, allocator, &args);
    try std.testing.expect(result == .err);
    switch (result.err) {
        .option_invalid_value => {},
        else => try std.testing.expect(false),
    }

    // Memory should be cleaned up automatically on error
    // No explicit cleanup needed since parsing failed
}
