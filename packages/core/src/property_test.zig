const std = @import("std");
const testing = std.testing;
const zcli = @import("zcli.zig");
const args_parser = @import("args.zig");
const options_parser = @import("options.zig");
const command_parser = @import("command_parser.zig");

// ============================================================================
// Randomized property tests for zcli parser security
//
// Deliberately NOT called fuzzing: every run uses a fixed seed, so these are
// deterministic bounded-random property/stability tests — they explore the
// same inputs every time and serve as a CI smoke over hostile input shapes.
// Coverage-guided parser fuzzing lives in parser_fuzz_test.zig and runs through
// `zig build fuzz-smoke` / `zig build fuzz`.
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
        std.log.info("Argument property results: {} successful, {} failed out of {} iterations", .{
            successful_parses,
            failed_parses,
            iterations,
        });

        // There is deliberately no "crash rate" gate here. A crash cannot be
        // tallied from inside the process — a panic or UB takes the whole test
        // binary down — so reaching this line at all IS the crash check, and
        // testing.allocator turns any leak into a failure. (This used to read
        // `try expect(crashes < iterations / 100)` over a `const crashes = 0`,
        // i.e. `0 < N` — always true. #744.)
        //
        // What is worth asserting is that the generator still reaches both
        // outcomes. If it degenerated into all-reject (or all-accept) every
        // iteration above would go on exercising one path while looking like
        // full coverage. PropertyTestArgs takes at most 4 positionals and this
        // loop generates 1-10 of them, so a healthy run produces both parses
        // and ArgumentTooMany rejections.
        try testing.expect(successful_parses > 0);
        try testing.expect(failed_parses > 0);
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

        // `memory_errors < iterations` was vacuous — under testing.allocator
        // nothing ever runs out of memory, so it read `0 < N` (#744). Assert
        // the invariant that actually holds: with memory available, no input
        // may be reported as SystemOutOfMemory. That error is only ever
        // produced by mapping a real allocator failure (see the
        // convertLongOptionError/convertShortOptionError tables), so a nonzero
        // count means an unrelated failure was misclassified as exhaustion.
        // Genuine exhaustion behaviour is covered by the
        // checkAllAllocationFailures tests at the bottom of this file.
        try testing.expectEqual(@as(usize, 0), memory_errors);
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

        var parsed_verbatim: usize = 0;
        var rejections: usize = 0;

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
                // The property: a hostile payload is data. It must come back
                // byte-for-byte — neither interpreted (no substitution, no
                // escape processing) nor silently truncated at the first NUL.
                try testing.expectEqualStrings(malicious_input, parsed.name);
                parsed_verbatim += 1;
            } else |_| {
                rejections += 1;
            }
        }

        std.log.info("Malicious pattern results: {} parsed verbatim, {} rejected", .{
            parsed_verbatim,
            rejections,
        });

        // Every one of these is a single positional bound to a []const u8
        // field, so the parser has nothing to reject: the pass-through above
        // must hold for all of them. (This block previously counted
        // "dangerous parses" — payloads containing `$(` or a backtick — and
        // asserted nothing about the count, which was doubly misleading: a
        // literal `$(` in a string is the *expected* result, not a danger.
        // #744.)
        try testing.expectEqual(iterations, parsed_verbatim);
        try testing.expectEqual(@as(usize, 0), rejections);
    }

    /// Stress the parser with many small and a few large random inputs. This is
    /// a stability check, NOT a performance measurement — `testing.allocator`
    /// catches leaks and any crash/UB fails the test. It deliberately does not
    /// assert wall-clock budgets: those only measure the CI runner's load, not
    /// the parser, and were flaky in CI. (Named for what it does since #744;
    /// it was `checkPerformanceStress`, which promised timing it never took.)
    pub fn checkStabilityUnderLoad(random: std.Random, allocator: std.mem.Allocator) !void {
        // Many small parses.
        const small_iterations = 10000;
        for (0..small_iterations) |_| {
            const arg = try generateRandomString(random, allocator, 10);
            defer allocator.free(arg);

            try expectSinglePositionalRoundTrips(arg);
        }

        // A few large parses. Length is not supposed to change the outcome —
        // a 1000-byte positional round-trips exactly like a 10-byte one.
        const large_iterations = 10;
        for (0..large_iterations) |_| {
            const arg = try generateRandomString(random, allocator, 1000);
            defer allocator.free(arg);

            try expectSinglePositionalRoundTrips(arg);
        }
    }
};

/// The invariant every single-positional parse must satisfy, whatever the
/// bytes are: `PropertyTestArgs` binds one positional to `name` and leaves the
/// fields behind it at their declared defaults, and `[]const u8` values are
/// returned as-is (args.zig parseValue), so the parse must succeed and hand
/// back a *view* of the caller's buffer — same pointer, same length, same
/// bytes. Copying, truncating at an interior NUL, or reinterpreting the
/// payload all fail here.
fn expectSinglePositionalRoundTrips(arg: []const u8) !void {
    const args = [_][]const u8{arg};
    const parsed = try args_parser.parseArgs(PropertyTestArgs, &args, null);

    try testing.expectEqual(arg.ptr, parsed.name.ptr);
    try testing.expectEqual(arg.len, parsed.name.len);
    try testing.expectEqualStrings(arg, parsed.name);
    try testing.expectEqual(@as(?u32, null), parsed.count);
    try testing.expectEqual(@as(?[]const u8, null), parsed.file);
    try testing.expectEqual(false, parsed.enabled);
}

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

test "property: parser stability under load" {
    var prng = std.Random.DefaultPrng.init(99999);
    const random = prng.random();
    const allocator = testing.allocator;

    try PropertyTesting.checkStabilityUnderLoad(random, allocator);
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

        // Multi-byte codepoints must survive the parse intact: the parser is
        // byte-transparent, so nothing here may be split, re-encoded, or
        // rejected. (This loop used to be `_ = parseArgs(...) catch {}` — a
        // crash detector wearing the name of an encoding test. #744.)
        try expectSinglePositionalRoundTrips(valid_string);
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

/// One worker of the concurrent stress test below: parses its own seeded
/// random inputs on its own thread and records the first failure, if any.
const ParseWorker = struct {
    allocator: std.mem.Allocator,
    seed: u64,
    iterations: usize,
    result: anyerror!void = {},

    fn run(self: *ParseWorker) void {
        self.result = self.parseLoop();
    }

    fn parseLoop(self: *ParseWorker) !void {
        var prng = std.Random.DefaultPrng.init(self.seed);
        const random = prng.random();

        for (0..self.iterations) |_| {
            const test_string = try generateRandomString(random, self.allocator, 20);
            defer self.allocator.free(test_string);

            // The pointer identity in this invariant is what makes the test
            // concurrent rather than merely parallel: the parse must be a view
            // of THIS thread's buffer, never a copy and never another thread's
            // string.
            try expectSinglePositionalRoundTrips(test_string);
        }
    }
};

test "property: concurrent parsing stress" {
    // parseArgs takes no allocator and holds no state — it slices the argv it
    // is handed — so parsing must be safe from several threads at once. Run it
    // on real threads and assert each thread's results (this test used to run
    // 10 sequential batches with zero assertions — #744).
    //
    // Sharing testing.allocator across the workers is deliberate and safe: it
    // is a std.heap.DebugAllocator whose `thread_safe` config defaults to
    // `!builtin.single_threaded`, so it takes its mutex here — and sharing it
    // keeps its leak accounting whole across every thread.
    const allocator = testing.allocator;

    var workers: [10]ParseWorker = undefined;
    for (&workers, 0..) |*worker, i| {
        worker.* = .{ .allocator = allocator, .seed = @intCast(i + 1000), .iterations = 50 };
    }

    var threads: [workers.len]std.Thread = undefined;
    var spawned: usize = 0;
    for (&threads, &workers) |*thread, *worker| {
        thread.* = std.Thread.spawn(.{}, ParseWorker.run, .{worker}) catch break;
        spawned += 1;
    }
    for (threads[0..spawned]) |thread| thread.join();

    // A platform with no threads at all would make this test meaningless.
    try testing.expect(spawned > 0);
    for (workers[0..spawned]) |worker| try worker.result;
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

// ============================================================================
// Allocation-failure tests (#744)
//
// `std.testing.checkAllAllocationFailures` replays a parse once per allocation
// site with that one allocation forced to fail, and reports either a swallowed
// OOM (the parser returned success even though an allocation failed) or a leak
// (bytes allocated before the failure were never released). zcli maps allocator
// failure onto `ZcliError.SystemOutOfMemory`, so each wrapper below translates
// it back to `error.OutOfMemory`, which is the contract the helper asserts on.
// ============================================================================

/// `checkAllAllocationFailures` is a no-op when the workload never allocates —
/// it iterates over the allocations the first run made. Prove there is at least
/// one before leaning on it: with the very first allocation forced to fail, the
/// workload must report out of memory.
fn expectWorkloadAllocates(comptime workload: anytype, args: []const []const u8) !void {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, workload(failing.allocator(), args));
}

const OomOptions = struct {
    output: []const u8 = "stdout",
    files: []const []const u8 = &.{},
    tags: []const []const u8 = &.{},
    counts: []const u32 = &.{},
    verbose: bool = false,
};

const OomArgs = struct {
    command: []const u8,
    rest: []const []const u8,
};

/// Every allocation the options parser makes must be released on the failure
/// path, and a failed allocation must surface as SystemOutOfMemory.
fn parseOptionsUnderOom(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const result = options_parser.parseOptions(OomOptions, allocator, args, null) catch |err| switch (err) {
        zcli.ZcliError.SystemOutOfMemory => return error.OutOfMemory,
        else => return err,
    };
    defer options_parser.cleanupOptions(OomOptions, result.options, allocator);

    try testing.expectEqualStrings("out.txt", result.options.output);
    try testing.expectEqual(@as(usize, 2), result.options.files.len);
    try testing.expectEqual(@as(usize, 3), result.options.counts.len);
    try testing.expect(result.options.verbose);
}

test "property: option parsing under allocation failure" {
    const args = [_][]const u8{
        "--output",  "out.txt",
        "--files",   "a.txt",
        "--files",   "b.txt",
        "--tags",    "alpha",
        "--counts",  "1",
        "--counts",  "2",
        "--counts",  "3",
        "--verbose",
    };
    try expectWorkloadAllocates(parseOptionsUnderOom, &args);
    try testing.checkAllAllocationFailures(testing.allocator, parseOptionsUnderOom, .{&args});
}

/// The combined split-then-parse path: it allocates the option/positional
/// piles, the owned positional slice, and the option arrays.
fn parseCommandLineUnderOom(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const result = command_parser.parseCommandLine(OomArgs, OomOptions, .{}, allocator, null, args, null) catch |err| switch (err) {
        zcli.ZcliError.SystemOutOfMemory => return error.OutOfMemory,
        else => return err,
    };
    defer result.deinit();

    try testing.expectEqualStrings("build", result.args.command);
    try testing.expectEqual(@as(usize, 2), result.args.rest.len);
    try testing.expectEqual(@as(usize, 2), result.options.files.len);
}

test "property: command-line parsing under allocation failure" {
    const args = [_][]const u8{
        "build",    "--files", "a.txt",  "--files",
        "b.txt",    "target",  "--tags", "alpha",
        "--counts", "7",       "extra",
    };
    try expectWorkloadAllocates(parseCommandLineUnderOom, &args);
    try testing.checkAllAllocationFailures(testing.allocator, parseCommandLineUnderOom, .{&args});
}

/// The arena-per-command shape from ADR-0001: the command's allocations all go
/// into a per-invocation arena that is released wholesale, so a mid-parse
/// allocation failure must still leave the backing allocator balanced once the
/// arena is torn down — and must not be swallowed on the way out.
fn parseInArenaUnderOom(backing: std.mem.Allocator, args: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();

    const result = command_parser.parseCommandLine(OomArgs, OomOptions, .{}, arena.allocator(), null, args, null) catch |err| switch (err) {
        zcli.ZcliError.SystemOutOfMemory => return error.OutOfMemory,
        else => return err,
    };
    // No deinit(): the arena owns everything the parse allocated. That is the
    // property under test — the teardown above must reclaim it regardless.

    try testing.expectEqualStrings("build", result.args.command);
    try testing.expectEqual(@as(usize, 2), result.options.files.len);
}

test "property: arena-per-command path under allocation failure" {
    const args = [_][]const u8{
        "build",    "--files", "a.txt",  "--files",
        "b.txt",    "target",  "--tags", "alpha",
        "--counts", "7",       "extra",
    };
    try expectWorkloadAllocates(parseInArenaUnderOom, &args);
    try testing.checkAllAllocationFailures(testing.allocator, parseInArenaUnderOom, .{&args});
}
