//! Micro-benchmarks and their regression budgets for the argument-parsing hot
//! path (`zig build benchmark` reports, `zig build regression` gates).
//!
//! This file is also compiled into `zig build test` (packages/core/build.zig's
//! `core_test_files`) so its own `test "benchmarks compile and run"` runs on
//! every PR: for the whole of the Zig 0.16 era it was reachable only from
//! benchmark_runner.zig, which meant nothing compiled it and both build steps
//! had silently rotted (#738). Being in the test aggregator is what stops that
//! recurring — the budgets below can only gate what still builds.

const std = @import("std");
const command_parser = @import("command_parser.zig");
const command_discovery = @import("build_utils/command_discovery.zig");

/// Performance benchmark results
const BenchmarkResult = struct {
    name: []const u8,
    iterations: u64,
    total_ns: u64,
    avg_ns: u64,
    min_ns: u64,
    max_ns: u64,

    pub fn format(self: @This(), writer: anytype) !void {
        const avg_us = @as(f64, @floatFromInt(self.avg_ns)) / 1000.0;
        const min_us = @as(f64, @floatFromInt(self.min_ns)) / 1000.0;
        const max_us = @as(f64, @floatFromInt(self.max_ns)) / 1000.0;

        try writer.print("{s:<40} | {d:>10} | {d:>8.2}μs | {d:>8.2}μs | {d:>8.2}μs\n", .{
            self.name,
            self.iterations,
            avg_us,
            min_us,
            max_us,
        });
    }
};

/// Run a benchmark function multiple times and collect statistics
fn benchmark(
    io: std.Io,
    name: []const u8,
    iterations: u64,
    comptime benchFn: fn (allocator: std.mem.Allocator, io: std.Io) anyerror!void,
) !BenchmarkResult {
    // `std.time.Timer` is gone in 0.16; the monotonic clock now comes from the
    // Io implementation. `.awake` is the CLOCK_MONOTONIC equivalent — the right
    // choice for durations (unaffected by wall-clock jumps).
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var total_ns: u64 = 0;

    // `std.heap.GeneralPurposeAllocator` (what this used before 0.16) is now
    // `DebugAllocator`, and using it here would measure the allocator's safety
    // metadata rather than the parser: it made every parse cost ~7μs and threw
    // 200ms outliers as it released pages back to the OS — noise no realistic
    // budget could sit above. `smp_allocator` is what `std.process.Init` hands
    // a release build, so it is also the allocator a shipped CLI actually
    // parses with. Leak detection is not lost by this: the same parse paths run
    // under `std.testing.allocator` throughout the parser's own test files.
    const allocator = std.heap.smp_allocator;

    // Warm up
    var warm_up: u64 = 0;
    while (warm_up < 10) : (warm_up += 1) {
        try benchFn(allocator, io);
    }

    // Actual benchmark
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        const start = std.Io.Clock.awake.now(io);
        try benchFn(allocator, io);
        const elapsed: u64 = @intCast(@max(0, start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds));

        total_ns += elapsed;
        min_ns = @min(min_ns, elapsed);
        max_ns = @max(max_ns, elapsed);
    }

    return BenchmarkResult{
        .name = name,
        .iterations = iterations,
        .total_ns = total_ns,
        .avg_ns = total_ns / iterations,
        .min_ns = min_ns,
        .max_ns = max_ns,
    };
}

/// Benchmark parsing simple arguments
fn benchParseSimpleArgs(allocator: std.mem.Allocator, io: std.Io) !void {
    _ = io;
    const TestArgs = struct {
        name: []const u8,
        count: u32,
        verbose: bool,
    };
    const TestOptions = struct {};

    const test_args = [_][]const u8{ "myapp", "42", "true" };

    const result = try command_parser.parseCommandLine(
        TestArgs,
        TestOptions,
        null,
        allocator,
        null,
        &test_args,
        null,
    );
    defer result.deinit();
}

/// Benchmark parsing complex arguments with optionals and varargs
fn benchParseComplexArgs(allocator: std.mem.Allocator, io: std.Io) !void {
    _ = io;
    const TestArgs = struct {
        command: []const u8,
        port: ?u16,
        host: ?[]const u8,
        verbose: bool,
        files: [][]const u8,
    };
    const TestOptions = struct {};

    const test_args = [_][]const u8{ "serve", "8080", "localhost", "false", "file1.txt", "file2.txt", "file3.txt" };

    const result = try command_parser.parseCommandLine(TestArgs, TestOptions, null, allocator, null, &test_args, null);
    defer result.deinit();
}

/// Benchmark parsing options
fn benchParseOptions(allocator: std.mem.Allocator, io: std.Io) !void {
    _ = io;
    const TestArgs = struct {};
    const TestOptions = struct {
        output: ?[]const u8 = null,
        verbose: bool = false,
        jobs: u32 = 1,
        include: [][]const u8 = &.{},
    };

    const test_args = [_][]const u8{ "--output", "result.txt", "--verbose", "--jobs", "4", "--include", "src", "--include", "lib" };
    const result = try command_parser.parseCommandLine(TestArgs, TestOptions, null, allocator, null, &test_args, null);
    defer result.deinit();
}

/// Benchmark mixed args and options parsing (unified parser)
fn benchParseMixed(allocator: std.mem.Allocator, io: std.Io) !void {
    _ = io;
    const TestArgs = struct {
        command: []const u8,
        target: []const u8,
    };

    const TestOptions = struct {
        verbose: bool = false,
        jobs: u32 = 1,
    };

    const test_input = [_][]const u8{ "--verbose", "--jobs", "8", "build", "release" };

    // Single unified parsing call - much simpler and handles mixed syntax correctly
    const result = try command_parser.parseCommandLine(TestArgs, TestOptions, null, allocator, null, &test_input, null);
    defer result.deinit();
}

/// Benchmark build-time command discovery over a small on-disk command tree.
///
/// Not `std.testing.tmpDir` — that asserts `builtin.is_test`, so it cannot
/// exist in the benchmark *executable*; and not `discoverCommands`, which takes
/// a `*std.Build` there is none of here. Both are why this function could never
/// have compiled since 0.16. It builds the fixture by hand and calls
/// `discoverInDir`, the shared core both the build and `zcli tree` go through.
///
/// The fixture is created and torn down inside the timed region, so this number
/// includes filesystem work — it is a report-only trend line, deliberately not
/// one of the gated budgets in `runRegressionTests`.
const discovery_fixture_dir = ".zig-cache/tmp/zcli-benchmark-discovery";

fn benchCommandDiscovery(allocator: std.mem.Allocator, io: std.Io) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, discovery_fixture_dir) catch {};
    defer cwd.deleteTree(io, discovery_fixture_dir) catch {};

    var cmd_dir = try cwd.createDirPathOpen(io, discovery_fixture_dir, .{ .open_options = .{ .iterate = true } });
    defer cmd_dir.close(io);

    for ([_][]const u8{ "hello.zig", "build.zig", "test.zig" }) |name| {
        try cmd_dir.writeFile(io, .{ .sub_path = name, .data = "pub fn execute() void {}" });
    }

    var discovered = try command_discovery.discoverInDir(allocator, io, cmd_dir);
    defer discovered.deinit();
}

/// Benchmark enum parsing
fn benchParseEnum(allocator: std.mem.Allocator, io: std.Io) !void {
    _ = io;
    const LogLevel = enum { debug, info, warn, err, fatal };
    const TestArgs = struct {
        level: LogLevel,
    };
    const TestOptions = struct {};

    const test_args = [_][]const u8{"warn"};

    const result = try command_parser.parseCommandLine(TestArgs, TestOptions, null, allocator, null, &test_args, null);
    defer result.deinit();
}

/// Benchmark error path performance
fn benchErrorPath(allocator: std.mem.Allocator, io: std.Io) !void {
    _ = io;
    const TestArgs = struct {
        name: []const u8,
        count: u32,
    };
    const TestOptions = struct {};

    // Intentionally invalid input
    const test_args = [_][]const u8{ "myapp", "not_a_number" };

    const result = command_parser.parseCommandLine(TestArgs, TestOptions, null, allocator, null, &test_args, null);
    if (result) |parsed| {
        parsed.deinit();
        return error.ExpectedError;
    } else |_| {
        // Expected error path
    }
}

/// Run all benchmarks.
///
/// `allocator` is for the results list only — the measured code deliberately
/// does NOT use it. Each benchmark parses with `smp_allocator` internally (see
/// `benchmark` above) so the allocator under measurement is fixed and matches a
/// release build's, regardless of what the caller happens to hand us.
pub fn runBenchmarks(allocator: std.mem.Allocator, io: std.Io) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    try stdout.print("\n=== zcli Performance Benchmarks ===\n\n", .{});
    try stdout.print("{s:<40} | {s:>10} | {s:>10} | {s:>10} | {s:>10}\n", .{
        "Benchmark",
        "Iterations",
        "Avg Time",
        "Min Time",
        "Max Time",
    });
    try stdout.print("{s:-<40}-+-{s:-<10}-+-{s:-<10}-+-{s:-<10}-+-{s:-<10}\n", .{
        "",
        "",
        "",
        "",
        "",
    });

    const iterations = 10000;
    var results = std.ArrayList(BenchmarkResult).empty;
    defer results.deinit(allocator);

    // Run benchmarks
    try results.append(allocator, try benchmark(io, "Parse Simple Args", iterations, benchParseSimpleArgs));
    try results.append(allocator, try benchmark(io, "Parse Complex Args", iterations, benchParseComplexArgs));
    try results.append(allocator, try benchmark(io, "Parse Options", iterations, benchParseOptions));
    try results.append(allocator, try benchmark(io, "Parse Mixed Args/Options", iterations / 10, benchParseMixed));
    try results.append(allocator, try benchmark(io, "Parse Enum", iterations, benchParseEnum));
    try results.append(allocator, try benchmark(io, "Error Path", iterations, benchErrorPath));
    try results.append(allocator, try benchmark(io, "Command Discovery", 100, benchCommandDiscovery));

    // Print results
    for (results.items) |result| {
        try result.format(stdout);
    }

    try stdout.print("\n", .{});
}

/// Regression test to ensure performance doesn't degrade
pub fn runRegressionTests(io: std.Io) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    try stdout.print("\n=== zcli Performance Regression Tests ===\n\n", .{});

    // Budgets in microseconds, per parse, ReleaseFast.
    //
    // These are CEILINGS, not targets. Observed on an M-series dev box:
    //
    //   parse_simple_args    0.07 μs  →  2.0 μs ceiling  (~28x)
    //   parse_complex_args   0.08 μs  →  2.0 μs ceiling  (~25x)
    //   parse_options        0.52 μs  →  5.0 μs ceiling  (~10x)
    //   parse_enum           0.06 μs  →  2.0 μs ceiling  (~33x)
    //   error_path           0.06 μs  →  2.0 μs ceiling  (~33x)
    //
    // The multiple is not uniform, and that is intentional rather than sloppy:
    // the four sub-0.1μs cases share one absolute floor (2.0 μs) because at
    // that scale the ceiling is set by measurement noise, not by the work —
    // scaling a 0.06 μs baseline by a "consistent" multiple would just encode
    // scheduler jitter as policy. `parse_options` does ~7x the work of the
    // others, so its budget scales with the work instead and lands at ~10x.
    //
    // PROVISIONAL BASELINE: those figures were taken on a machine under heavy
    // load (several parallel builds, plus a wedged system daemon pinning a
    // core), so treat them as an upper bound on the true quiet-machine numbers
    // rather than as the numbers. Re-measure with `zig build benchmark` on an
    // idle box before tightening anything. Nothing here needs *loosening* on
    // that account — a degraded machine can only have made the baseline look
    // worse than it is.
    //
    // The 2.0μs floor is where it is because the noisy case, not the slow case,
    // is what decides whether a perf gate survives. Timing these same parses
    // while the machine was busy compiling took "Parse Complex Args" from
    // 0.08μs to 0.91μs — an 11x swing from CPU contention alone, with no code
    // change. A shared GitHub runner is exactly that environment (co-tenant
    // steal, no thermal guarantee), so 2.0μs sits ~2x above the worst
    // contention figure actually observed. The build serializes the two halves
    // of `zig build regression` so that contention is at least not
    // self-inflicted (see build.zig), but the budget has to survive a runner we
    // do not control either way.
    //
    // Ceilings this loose still catch everything worth gating: an accidental
    // O(n²) scan, an allocation added to the per-parse path, a comptime table
    // demoted to a runtime loop. Those move these numbers by two orders of
    // magnitude, not by 30% — and a gate that flakes gets deleted, at which
    // point it catches nothing at all.
    //
    // Adding one: measure locally with `zig build benchmark`, then take
    // whichever is larger of the 2.0μs noise floor and ~10x the reported
    // average, rounded to something legible.
    const thresholds = .{
        .parse_simple_args = 2.0,
        .parse_complex_args = 2.0,
        .parse_options = 5.0,
        .parse_enum = 2.0,
        .error_path = 2.0,
    };

    var passed: u32 = 0;
    var failed: u32 = 0;

    // Test simple args parsing
    {
        const result = try benchmark(io, "Parse Simple Args", 1000, benchParseSimpleArgs);
        const avg_us = @as(f64, @floatFromInt(result.avg_ns)) / 1000.0;

        if (avg_us <= thresholds.parse_simple_args) {
            try stdout.print("✓ Parse Simple Args: {d:.3}μs (threshold: {d}μs)\n", .{ avg_us, thresholds.parse_simple_args });
            passed += 1;
        } else {
            try stdout.print("✗ Parse Simple Args: {d:.3}μs (threshold: {d}μs) - FAILED\n", .{ avg_us, thresholds.parse_simple_args });
            failed += 1;
        }
    }

    // Test complex args parsing
    {
        const result = try benchmark(io, "Parse Complex Args", 1000, benchParseComplexArgs);
        const avg_us = @as(f64, @floatFromInt(result.avg_ns)) / 1000.0;

        if (avg_us <= thresholds.parse_complex_args) {
            try stdout.print("✓ Parse Complex Args: {d:.3}μs (threshold: {d}μs)\n", .{ avg_us, thresholds.parse_complex_args });
            passed += 1;
        } else {
            try stdout.print("✗ Parse Complex Args: {d:.3}μs (threshold: {d}μs) - FAILED\n", .{ avg_us, thresholds.parse_complex_args });
            failed += 1;
        }
    }

    // Test options parsing
    {
        const result = try benchmark(io, "Parse Options", 1000, benchParseOptions);
        const avg_us = @as(f64, @floatFromInt(result.avg_ns)) / 1000.0;

        if (avg_us <= thresholds.parse_options) {
            try stdout.print("✓ Parse Options: {d:.3}μs (threshold: {d}μs)\n", .{ avg_us, thresholds.parse_options });
            passed += 1;
        } else {
            try stdout.print("✗ Parse Options: {d:.3}μs (threshold: {d}μs) - FAILED\n", .{ avg_us, thresholds.parse_options });
            failed += 1;
        }
    }

    // Test enum parsing
    {
        const result = try benchmark(io, "Parse Enum", 1000, benchParseEnum);
        const avg_us = @as(f64, @floatFromInt(result.avg_ns)) / 1000.0;

        if (avg_us <= thresholds.parse_enum) {
            try stdout.print("✓ Parse Enum: {d:.3}μs (threshold: {d}μs)\n", .{ avg_us, thresholds.parse_enum });
            passed += 1;
        } else {
            try stdout.print("✗ Parse Enum: {d:.3}μs (threshold: {d}μs) - FAILED\n", .{ avg_us, thresholds.parse_enum });
            failed += 1;
        }
    }

    // Test error path
    {
        const result = try benchmark(io, "Error Path", 1000, benchErrorPath);
        const avg_us = @as(f64, @floatFromInt(result.avg_ns)) / 1000.0;

        if (avg_us <= thresholds.error_path) {
            try stdout.print("✓ Error Path: {d:.3}μs (threshold: {d}μs)\n", .{ avg_us, thresholds.error_path });
            passed += 1;
        } else {
            try stdout.print("✗ Error Path: {d:.3}μs (threshold: {d}μs) - FAILED\n", .{ avg_us, thresholds.error_path });
            failed += 1;
        }
    }

    try stdout.print("\nResults: {d} passed, {d} failed\n", .{ passed, failed });

    if (failed > 0) {
        return error.RegressionTestFailed;
    }
}

// The guard that keeps `zig build benchmark` / `zig build regression` alive:
// this file rides into `zig build test` (packages/core/build.zig), so anything
// that stops the harness compiling — a removed std API, a changed parser
// signature — fails a PR instead of rotting unnoticed for a release cycle.
// Iteration counts are tiny; this is a compile-and-run check, not a
// measurement (the measuring is what `regression` does).
test "benchmarks compile and run" {
    const io = std.testing.io;
    _ = try benchmark(io, "Test Simple Args", 10, benchParseSimpleArgs);
    _ = try benchmark(io, "Test Complex Args", 10, benchParseComplexArgs);
    _ = try benchmark(io, "Test Enum", 10, benchParseEnum);
    _ = try benchmark(io, "Test Error Path", 10, benchErrorPath);
}

// The two entry points the build steps call. Nothing else in the tree
// references them, so without this they would compile only inside
// benchmark_runner.zig's own (ReleaseFast, non-test) build — exactly the blind
// spot #738 was about. Referencing them here type-checks both signatures under
// `zig build test`.
test "regression + benchmark entry points type-check" {
    _ = &runBenchmarks;
    _ = &runRegressionTests;
}
