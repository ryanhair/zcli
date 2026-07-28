//! Entry point for `zig build benchmark` (report) and `zig build regression`
//! (gate). Both run this one executable; `--regression` selects the gating
//! mode. See benchmark.zig for the measurements and their budgets.

const std = @import("std");
const benchmark = @import("benchmark.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var stderr_buffer: [1024]u8 = undefined;
    // Streaming, never positional — see the note on `zcli.Stdio.init`: a
    // positional writer pwrites from its own zero-based offset and clobbers a
    // shared-fd append (`zig build benchmark >>run.log`) from byte 0.
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    // Buffered output is dropped if the process exits without flushing, so every
    // path below flushes before returning (0.16's explicit-IO contract).
    defer stderr.flush() catch {};

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // Check command line arguments
    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "--regression")) {
            try benchmark.runRegressionTests(io);
        } else if (std.mem.eql(u8, args[1], "--help")) {
            try printHelp(io);
        } else {
            try stderr.print("Unknown option: {s}\n", .{args[1]});
            try printHelp(io);
            return error.InvalidArgument;
        }
    } else {
        // Run standard benchmarks
        try benchmark.runBenchmarks(allocator, io);
    }
}

fn printHelp(io: std.Io) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
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
    // The original never flushed this writer, so `--help` printed nothing.
    try stdout.flush();
}
