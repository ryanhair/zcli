const std = @import("std");
const benchmark = @import("benchmark.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Check command line arguments
    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "--regression")) {
            try benchmark.runRegressionTests(allocator);
        } else if (std.mem.eql(u8, args[1], "--help")) {
            try printHelp();
        } else {
            try std.io.getStdErr().writer().print("Unknown option: {s}\n", .{args[1]});
            try printHelp();
            return error.InvalidArgument;
        }
    } else {
        // Run standard benchmarks
        try benchmark.runBenchmarks(allocator);
    }
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
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
