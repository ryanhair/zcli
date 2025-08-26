const std = @import("std");
const zcli = @import("zcli.zig");
const command_parser = @import("command_parser.zig");
const build_utils = @import("build_utils.zig");

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
    name: []const u8,
    iterations: u64,
    comptime benchFn: fn () anyerror!void,
) !BenchmarkResult {
    var timer = try std.time.Timer.start();
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var total_ns: u64 = 0;

    // Warm up
    var warm_up: u64 = 0;
    while (warm_up < 10) : (warm_up += 1) {
        try benchFn();
    }

    // Actual benchmark
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        timer.reset();
        try benchFn();
        const elapsed = timer.read();

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
fn benchParseSimpleArgs() !void {
    const TestArgs = struct {
        name: []const u8,
        count: u32,
        verbose: bool,
    };
    const TestOptions = struct {};

    const test_args = [_][]const u8{ "myapp", "42", "true" };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const result = try command_parser.parseCommandLine(TestArgs, TestOptions, null, allocator, &test_args);
    defer result.deinit();
}

/// Benchmark parsing complex arguments with optionals and varargs
fn benchParseComplexArgs() !void {
    const TestArgs = struct {
        command: []const u8,
        port: ?u16,
        host: ?[]const u8,
        verbose: bool,
        files: [][]const u8,
    };
    const TestOptions = struct {};

    const test_args = [_][]const u8{ "serve", "8080", "localhost", "false", "file1.txt", "file2.txt", "file3.txt" };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const result = try command_parser.parseCommandLine(TestArgs, TestOptions, null, allocator, &test_args);
    defer result.deinit();
}

/// Benchmark parsing options
fn benchParseOptions() !void {
    const TestArgs = struct {};
    const TestOptions = struct {
        output: ?[]const u8 = null,
        verbose: bool = false,
        jobs: u32 = 1,
        include: [][]const u8 = &.{},
    };

    const allocator = std.heap.page_allocator;
    const test_args = [_][]const u8{ "--output", "result.txt", "--verbose", "--jobs", "4", "--include", "src", "--include", "lib" };
    const result = try command_parser.parseCommandLine(TestArgs, TestOptions, null, allocator, &test_args);
    defer result.deinit();
}

/// Benchmark mixed args and options parsing (unified parser)
fn benchParseMixed() !void {
    const TestArgs = struct {
        command: []const u8,
        target: []const u8,
    };

    const TestOptions = struct {
        verbose: bool = false,
        jobs: u32 = 1,
    };

    const allocator = std.heap.page_allocator;
    const test_input = [_][]const u8{ "--verbose", "--jobs", "8", "build", "release" };

    // Single unified parsing call - much simpler and handles mixed syntax correctly
    const result = try command_parser.parseCommandLine(TestArgs, TestOptions, null, allocator, &test_input);
    defer result.deinit();
}

/// Benchmark command discovery for build system
fn benchCommandDiscovery() !void {
    const allocator = std.heap.page_allocator;

    // Create a temporary directory structure
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const commands_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(commands_path);

    // Create some command files
    try tmp_dir.dir.makeDir("commands");
    const cmd_dir = try tmp_dir.dir.openDir("commands", .{});

    try cmd_dir.writeFile(.{ .sub_path = "hello.zig", .data = "pub fn execute() void {}" });
    try cmd_dir.writeFile(.{ .sub_path = "build.zig", .data = "pub fn execute() void {}" });
    try cmd_dir.writeFile(.{ .sub_path = "test.zig", .data = "pub fn execute() void {}" });

    // Benchmark discovery
    const commands_subpath = try std.fs.path.join(allocator, &.{ commands_path, "commands" });
    defer allocator.free(commands_subpath);

    var discovered = try build_utils.discoverCommands(allocator, commands_subpath);
    defer discovered.deinit();
}

/// Benchmark enum parsing
fn benchParseEnum() !void {
    const LogLevel = enum { debug, info, warn, err, fatal };
    const TestArgs = struct {
        level: LogLevel,
    };
    const TestOptions = struct {};

    const test_args = [_][]const u8{"warn"};
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const result = try command_parser.parseCommandLine(TestArgs, TestOptions, null, allocator, &test_args);
    defer result.deinit();
}

/// Benchmark error path performance
fn benchErrorPath() !void {
    const TestArgs = struct {
        name: []const u8,
        count: u32,
    };
    const TestOptions = struct {};

    // Intentionally invalid input
    const test_args = [_][]const u8{ "myapp", "not_a_number" };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const result = command_parser.parseCommandLine(TestArgs, TestOptions, null, allocator, &test_args);
    if (result) |parsed| {
        parsed.deinit();
        return error.ExpectedError;
    } else |_| {
        // Expected error path
    }
}

/// Run all benchmarks
pub fn runBenchmarks(allocator: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();

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
    var results = std.ArrayList(BenchmarkResult).init(allocator);
    defer results.deinit();

    // Run benchmarks
    try results.append(try benchmark("Parse Simple Args", iterations, benchParseSimpleArgs));
    try results.append(try benchmark("Parse Complex Args", iterations, benchParseComplexArgs));
    try results.append(try benchmark("Parse Options", iterations, benchParseOptions));
    try results.append(try benchmark("Parse Mixed Args/Options", iterations / 10, benchParseMixed));
    try results.append(try benchmark("Parse Enum", iterations, benchParseEnum));
    try results.append(try benchmark("Error Path", iterations, benchErrorPath));
    try results.append(try benchmark("Command Discovery", 100, benchCommandDiscovery));

    // Print results
    for (results.items) |result| {
        try result.format(stdout);
    }

    try stdout.print("\n", .{});
}

/// Regression test to ensure performance doesn't degrade
pub fn runRegressionTests(allocator: std.mem.Allocator) !void {
    _ = allocator; // Not used in this implementation
    const stdout = std.io.getStdOut().writer();

    try stdout.print("\n=== zcli Performance Regression Tests ===\n\n", .{});

    // Define performance thresholds (in microseconds)
    const thresholds = .{
        .parse_simple_args = 1.0, // Should complete in < 1μs
        .parse_complex_args = 2.0, // Should complete in < 2μs
        .parse_options = 10.0, // Should complete in < 10μs
        .parse_enum = 0.5, // Should complete in < 0.5μs
        .error_path = 5.0, // Error handling should be < 5μs
    };

    var passed: u32 = 0;
    var failed: u32 = 0;

    // Test simple args parsing
    {
        const result = try benchmark("Parse Simple Args", 1000, benchParseSimpleArgs);
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
        const result = try benchmark("Parse Complex Args", 1000, benchParseComplexArgs);
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
        const result = try benchmark("Parse Options", 1000, benchParseOptions);
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
        const result = try benchmark("Parse Enum", 1000, benchParseEnum);
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
        const result = try benchmark("Error Path", 1000, benchErrorPath);
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

// Test to ensure benchmarks compile and run
test "benchmarks compile and run" {
    // Just run a few iterations to ensure they work
    _ = try benchmark("Test Simple Args", 10, benchParseSimpleArgs);
    _ = try benchmark("Test Complex Args", 10, benchParseComplexArgs);
    _ = try benchmark("Test Enum", 10, benchParseEnum);
    _ = try benchmark("Test Error Path", 10, benchErrorPath);
}
