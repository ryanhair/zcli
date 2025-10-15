const std = @import("std");
const benchmark = @import("benchmark.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Check command line arguments
    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "--regression")) {
            try benchmark.runRegressionTests();
        } else if (std.mem.eql(u8, args[1], "--help")) {
            try printHelp();
        } else {
            try stderr.print("Unknown option: {s}\n", .{args[1]});
            try printHelp();
            return error.InvalidArgument;
        }
    } else {
        // Run standard benchmarks
        try benchmark.runBenchmarks(allocator);
    }
}

fn printHelp() !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        \\zcli Benchmark Runner
        \\
        \\Usage: benchmark [options]
        \\
        \\Options:
        \\  --regression    Run regression tests with performance thresholds
        \\  --help          Show this help message
        \\
        \\Without options, runs full performance benchmark suite.
        \\
    , .{});
}
