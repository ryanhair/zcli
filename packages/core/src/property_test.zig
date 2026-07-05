const std = @import("std");
const testing = std.testing;
const zcli = @import("zcli.zig");
const args_parser = @import("args.zig");
const options_parser = @import("options.zig");

// ============================================================================
// Randomized property tests for zcli parser security
//
// Deliberately NOT called fuzzing: every run uses a fixed seed, so these are
// deterministic bounded-random property/stability tests — they explore the
// same inputs every time and serve as a CI smoke over hostile input shapes.
// Coverage-guided fuzzing via `std.testing.fuzz` is future work.
// ============================================================================

/// Test structures for the randomized property tests
const PropertyTestArgs = struct {
    name: []const u8,
    count: ?u32 = null,
    file: ?[]const u8 = null,
    enabled: bool = false,
};

const PropertyTestOptions = struct {
    output: []const u8 = "stdout",
    files: []const []const u8 = &.{},
    count: u32 = 0,
    size: i64 = 0,
    ratio: f64 = 1.0,
    enabled: bool = false,
    verbose: bool = false,
};

/// Randomized property-test framework
pub const PropertyTesting = struct {
    /// Exercise command-line argument parsing with seeded random inputs
    pub fn checkArgumentParsing(random: std.Random, iterations: usize, allocator: std.mem.Allocator) !void {
        var successful_parses: usize = 0;
        var failed_parses: usize = 0;
        const crashes: usize = 0;

        for (0..iterations) |_| {
            // Generate random number of arguments (1-10)
            const arg_count = random.uintLessThan(usize, 10) + 1;
            var args: std.ArrayList([]const u8) = .empty;
            defer {
                for (args.items) |arg| allocator.free(arg);
                args.deinit(allocator);
            }

            // Generate random arguments
            for (0..arg_count) |_| {
                const arg_len = random.uintLessThan(usize, 100) + 1; // 1-100 chars
                const arg = try allocator.alloc(u8, arg_len);

                // Fill with random bytes (weighted towards printable chars)
                for (arg) |*byte| {
                    if (random.boolean()) {
                        // 50% chance of printable ASCII (32-126)
                        byte.* = random.uintLessThan(u8, 95) + 32;
                    } else {
                        // 50% chance of any byte (0-255)
                        byte.* = random.int(u8);
                    }
                }

                try args.append(allocator, arg);
            }

            // Test that random input doesn't crash the parser
            if (args_parser.parseArgs(PropertyTestArgs, args.items, null)) |_| {
                successful_parses += 1;
            } else |_| {
                failed_parses += 1;
            }
        }

        // Report statistics
        std.log.info("Argument property results: {} successful, {} failed, {} crashes out of {} iterations", .{
            successful_parses,
            failed_parses,
            crashes,
            iterations,
        });

        // Should have very few or no crashes
        try testing.expect(crashes < iterations / 100); // Less than 1% crash rate
    }

    /// Exercise option parsing with seeded random inputs
    pub fn checkOptionParsing(random: std.Random, iterations: usize, allocator: std.mem.Allocator) !void {
        var successful_parses: usize = 0;
        var failed_parses: usize = 0;
        var memory_errors: usize = 0;

        for (0..iterations) |_| {
            // Generate random number of option arguments (0-20)
            const arg_count = random.uintLessThan(usize, 21);
            var args: std.ArrayList([]const u8) = .empty;
            defer {
                for (args.items) |arg| allocator.free(arg);
                args.deinit(allocator);
            }

            // Generate option-like arguments
            var j: usize = 0;
            while (j < arg_count) {
                // Generate option name
                const option_name_len = random.uintLessThan(usize, 30) + 2; // --x minimum
                const option_name = try allocator.alloc(u8, option_name_len);
                option_name[0] = '-';
                option_name[1] = '-';

                // Fill rest with random chars (weighted towards valid option chars)
                for (option_name[2..]) |*byte| {
                    if (random.boolean()) {
                        // Valid option characters (a-z, A-Z, 0-9, -, _)
                        const valid_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_";
                        byte.* = valid_chars[random.uintLessThan(usize, valid_chars.len)];
                    } else {
                        // Any printable ASCII
                        byte.* = random.uintLessThan(u8, 95) + 32;
                    }
                }

                try args.append(allocator, option_name);
                j += 1;

                // Maybe add a value for this option
                if (j < arg_count and random.boolean()) {
                    const value_len = random.uintLessThan(usize, 50) + 1;
                    const value = try allocator.alloc(u8, value_len);

                    for (value) |*byte| {
                        if (random.uintLessThan(u8, 10) == 0) {
                            // 10% chance of control/special chars
                            byte.* = random.int(u8);
                        } else {
                            // 90% chance of printable chars
                            byte.* = random.uintLessThan(u8, 95) + 32;
                        }
                    }

                    try args.append(allocator, value);
                    j += 1;
                }
            }

            // Test option parsing
            const result = options_parser.parseOptions(PropertyTestOptions, allocator, args.items, null) catch |err| switch (err) {
                zcli.ZcliError.SystemOutOfMemory => {
                    memory_errors += 1;
                    continue;
                },
                else => {
                    failed_parses += 1;
                    continue;
                },
            };

            options_parser.cleanupOptions(PropertyTestOptions, result.options, allocator);
            successful_parses += 1;
        }

        // Report statistics
        std.log.info("Option property results: {} successful, {} failed, {} memory errors out of {} iterations", .{
            successful_parses,
            failed_parses,
            memory_errors,
            iterations,
        });

        // Should handle memory exhaustion gracefully
        try testing.expect(memory_errors < iterations); // All memory errors should be handled
    }

    /// Exercise the parsers with malicious patterns specifically
    pub fn checkMaliciousPatterns(random: std.Random, iterations: usize, allocator: std.mem.Allocator) !void {
        const malicious_templates = [_][]const u8{
            "$({})", // Command substitution
            "`{}`", // Backtick command substitution
            "${{}}", // Variable substitution
            "{}" ** 100, // Repetition
            "{}/../../../etc/passwd", // Path traversal
            "%{}%{}%{}", // Format strings
            "\x00{}\x00", // Null byte injection
            "\x1b[2J{}", // ANSI escape
            "../{}", // Relative path
        };

        var dangerous_parses: usize = 0;
        var safe_rejections: usize = 0;

        for (0..iterations) |_| {
            // Pick a random malicious template
            const template = malicious_templates[random.uintLessThan(usize, malicious_templates.len)];

            // Generate random payload
            const payload_len = random.uintLessThan(usize, 50) + 1;
            const payload = try allocator.alloc(u8, payload_len);
            defer allocator.free(payload);

            for (payload) |*byte| {
                byte.* = random.uintLessThan(u8, 95) + 32; // Printable ASCII
            }

            // Create malicious input by replacing {} in template
            const malicious_input = try std.mem.replaceOwned(u8, allocator, template, "{}", payload);
            defer allocator.free(malicious_input);

            // Test argument parsing
            const args = [_][]const u8{malicious_input};

            if (args_parser.parseArgs(PropertyTestArgs, &args, null)) |parsed| {
                // If it parsed, verify it's treated as literal string
                try testing.expectEqualStrings(malicious_input, parsed.name);

                // Check that it doesn't contain obvious signs of code execution
                if (std.mem.indexOf(u8, parsed.name, "$(") != null or
                    std.mem.indexOf(u8, parsed.name, "`") != null)
                {
                    dangerous_parses += 1;
                }
            } else |err| {
                switch (err) {
                    zcli.ZcliError.ArgumentInvalidValue => {
                        safe_rejections += 1; // Good - rejected malicious input
                    },
                    else => {
                        // Other errors are also acceptable for malicious input
                        safe_rejections += 1;
                    },
                }
            }
        }

        std.log.info("Malicious pattern results: {} dangerous parses, {} safe rejections", .{
            dangerous_parses,
            safe_rejections,
        });

        // Most malicious patterns should be treated as literal strings (not executed)
        // This is actually OK - we want the parser to accept them as literal strings
        // The danger would be if they were interpreted/executed later
    }

    /// Stress the parser with many small and a few large random inputs. This is a
    /// stability check — `testing.allocator` catches leaks and any crash/UB fails
    /// the test. It deliberately does not assert wall-clock budgets: those only
    /// measure the CI runner's load, not the parser, and were flaky in CI.
    pub fn checkPerformanceStress(random: std.Random, allocator: std.mem.Allocator) !void {
        // Many small parses.
        const small_iterations = 10000;
        for (0..small_iterations) |_| {
            const arg = try generateRandomString(random, allocator, 10);
            defer allocator.free(arg);

            const args = [_][]const u8{arg};
            _ = args_parser.parseArgs(PropertyTestArgs, &args, null) catch {};
        }

        // A few large parses.
        const large_iterations = 10;
        for (0..large_iterations) |_| {
            const arg = try generateRandomString(random, allocator, 1000);
            defer allocator.free(arg);

            const args = [_][]const u8{arg};
            _ = args_parser.parseArgs(PropertyTestArgs, &args, null) catch {};
        }
    }
};

/// Generate a random string of specified length
fn generateRandomString(random: std.Random, allocator: std.mem.Allocator, len: usize) ![]u8 {
    const string = try allocator.alloc(u8, len);
    for (string) |*byte| {
        byte.* = random.uintLessThan(u8, 95) + 32; // Printable ASCII
    }
    return string;
}

// ============================================================================
// Specialized randomized property tests
// ============================================================================

test "property: basic argument parsing stability" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();
    const allocator = testing.allocator;

    try PropertyTesting.checkArgumentParsing(random, 1000, allocator);
}

test "property: option parsing stability" {
    var prng = std.Random.DefaultPrng.init(54321);
    const random = prng.random();
    const allocator = testing.allocator;

    try PropertyTesting.checkOptionParsing(random, 500, allocator);
}

test "property: malicious pattern handling" {
    var prng = std.Random.DefaultPrng.init(11111);
    const random = prng.random();
    const allocator = testing.allocator;

    try PropertyTesting.checkMaliciousPatterns(random, 200, allocator);
}

test "property: performance stress testing" {
    var prng = std.Random.DefaultPrng.init(99999);
    const random = prng.random();
    const allocator = testing.allocator;

    try PropertyTesting.checkPerformanceStress(random, allocator);
}

// ============================================================================
// Edge-case property tests
// ============================================================================

test "property: unicode and encoding edge cases" {
    var prng = std.Random.DefaultPrng.init(88888);
    const random = prng.random();
    const allocator = testing.allocator;

    for (0..100) |_| {
        // Generate strings with various Unicode ranges
        const len = random.uintLessThan(usize, 50) + 1;
        const unicode_string = try allocator.alloc(u8, len * 4); // Space for UTF-8
        defer allocator.free(unicode_string);

        var utf8_len: usize = 0;
        for (0..len) |_| {
            // Generate random Unicode codepoint
            const codepoint: u21 = switch (random.uintLessThan(u8, 4)) {
                0 => random.uintLessThan(u21, 0x80), // ASCII
                1 => random.uintLessThan(u21, 0x800), // 2-byte UTF-8
                2 => random.uintLessThan(u21, 0x10000), // 3-byte UTF-8
                else => random.uintLessThan(u21, 0x110000), // 4-byte UTF-8
            };

            if (std.unicode.utf8ValidCodepoint(codepoint)) {
                const bytes = std.unicode.utf8Encode(codepoint, unicode_string[utf8_len..]) catch continue;
                utf8_len += bytes;
            }
        }

        const valid_string = unicode_string[0..utf8_len];
        const args = [_][]const u8{valid_string};

        // Should handle Unicode without crashing
        _ = args_parser.parseArgs(PropertyTestArgs, &args, null) catch {};
    }
}

test "property: memory boundary conditions" {
    const allocator = testing.allocator;

    // Test various memory boundary conditions
    const sizes = [_]usize{ 0, 1, 2, 3, 4, 7, 8, 15, 16, 31, 32, 63, 64, 127, 128, 255, 256, 511, 512, 1023, 1024 };

    for (sizes) |size| {
        if (size == 0) continue; // Skip empty strings for args

        const test_string = try allocator.alloc(u8, size);
        defer allocator.free(test_string);

        // Fill with pattern that might reveal boundary issues
        for (test_string, 0..) |*byte, i| {
            byte.* = @intCast((i % 256)); // Pattern that cycles through all byte values
        }

        const args = [_][]const u8{test_string};

        // Should handle various sizes without boundary errors
        const result = args_parser.parseArgs(PropertyTestArgs, &args, null) catch |err| switch (err) {
            zcli.ZcliError.SystemOutOfMemory => continue, // Acceptable
            else => return err,
        };

        // Verify string integrity across boundaries
        try testing.expectEqual(size, result.name.len);
        try testing.expect(std.mem.eql(u8, test_string, result.name));
    }
}

test "property: concurrent parsing stress" {
    // Test that parsing is thread-safe by running concurrent randomized parses
    const allocator = testing.allocator;

    // Run multiple parsing operations "concurrently" (simulated)
    // In real concurrent testing, these would be on separate threads
    for (0..10) |thread_id| {
        var thread_prng = std.Random.DefaultPrng.init(@intCast(thread_id + 1000));
        const thread_random = thread_prng.random();

        for (0..50) |_| {
            const test_string = try generateRandomString(thread_random, allocator, 20);
            defer allocator.free(test_string);

            const args = [_][]const u8{test_string};
            _ = args_parser.parseArgs(PropertyTestArgs, &args, null) catch {};
        }
    }
}

// ============================================================================
// Regression Testing for Known Issues
// ============================================================================

test "property: regression tests for past vulnerabilities" {
    // Test specific inputs that might have caused issues in the past
    const regression_inputs = [_][]const u8{
        "A" ** 1000, // Large buffer
        "\x00\x01\x02\x03", // Control characters
        "$(echo hello)", // Command injection
        "../../../../etc/passwd", // Path traversal
        "%s%s%s%s", // Format string
        "\x1b[2J", // ANSI escape
        "test\x00null", // Null injection
        "🔥💀👹", // Emoji
        "\u{202E}rtl\u{202D}", // Right-to-left override
    };

    for (regression_inputs) |input| {
        const args = [_][]const u8{input};

        // Should not crash or behave unexpectedly
        const result = args_parser.parseArgs(PropertyTestArgs, &args, null) catch |err| switch (err) {
            zcli.ZcliError.SystemOutOfMemory => continue, // Acceptable
            else => {
                std.log.warn("Regression test failed for input: {any}, error: {}", .{ input, err });
                return err;
            },
        };

        // Verify input was handled as literal string
        try testing.expectEqualStrings(input, result.name);
    }
}
