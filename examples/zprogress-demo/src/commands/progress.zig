const std = @import("std");
const zcli = @import("zcli");
const zprogress = zcli.zprogress;

pub const meta = .{
    .description = "Demonstrate progress bar configurations",
    .examples = &.{
        "zpdemo progress                 # Run all progress demos",
        "zpdemo progress --items 50      # Process 50 items",
        "zpdemo progress --width 60      # Use 60 char wide bar",
        "zpdemo progress --show-rate     # Show items/second",
    },
    .options = .{
        .items = .{ .description = "Number of items to process" },
        .width = .{ .description = "Width of the progress bar" },
        .@"show-rate" = .{ .description = "Show processing rate" },
        .@"show-elapsed" = .{ .description = "Show elapsed time" },
    },
};

pub const Args = struct {};

pub const Options = struct {
    items: u32 = 100,
    width: u32 = 40,
    @"show-rate": bool = false,
    @"show-elapsed": bool = false,
};

pub fn execute(_: Args, options: Options, context: anytype) !void {
    const stdout = context.stdout();

    try stdout.print("Progress Bar Demos\n", .{});
    try stdout.print("==================\n\n", .{});

    // Demo 1: Basic progress bar
    try stdout.print("Demo 1: Basic progress bar\n", .{});
    basicProgressDemo(options.items, options.width);

    // Demo 2: Progress bar with ETA
    try stdout.print("\nDemo 2: Progress bar with ETA\n", .{});
    etaProgressDemo(options.items, options.width);

    // Demo 3: Progress bar with rate
    if (options.@"show-rate") {
        try stdout.print("\nDemo 3: Progress bar with rate\n", .{});
        rateProgressDemo(options.items, options.width);
    }

    // Demo 4: Progress bar with elapsed time
    if (options.@"show-elapsed") {
        try stdout.print("\nDemo 4: Progress bar with elapsed time\n", .{});
        elapsedProgressDemo(options.items, options.width);
    }

    // Demo 5: Progress bar with custom characters
    try stdout.print("\nDemo 5: Progress bar with custom style\n", .{});
    customStyleDemo(options.items, options.width);

    // Demo 6: Progress with message updates
    try stdout.print("\nDemo 6: Progress with message updates\n", .{});
    messageUpdateDemo();

    try stdout.print("\nAll progress demos complete!\n", .{});
}

fn basicProgressDemo(items: u32, width: u32) void {
    var bar = zprogress.progressBar(.{
        .total = items,
        .width = width,
        .show_eta = false,
    });

    var i: usize = 0;
    while (i < items) : (i += 1) {
        bar.update(i + 1, null);
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    bar.finish();
}

fn etaProgressDemo(items: u32, width: u32) void {
    var bar = zprogress.progressBar(.{
        .total = items,
        .width = width,
        .show_eta = true,
    });

    var i: usize = 0;
    while (i < items) : (i += 1) {
        bar.update(i + 1, null);
        // Variable sleep to make ETA interesting
        const delay: u64 = 10 + (i % 30);
        std.Thread.sleep(delay * std.time.ns_per_ms);
    }
    bar.finish();
}

fn rateProgressDemo(items: u32, width: u32) void {
    var bar = zprogress.progressBar(.{
        .total = items,
        .width = width,
        .show_eta = false,
        .show_rate = true,
    });

    var i: usize = 0;
    while (i < items) : (i += 1) {
        bar.update(i + 1, null);
        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
    bar.finish();
}

fn elapsedProgressDemo(items: u32, width: u32) void {
    var bar = zprogress.progressBar(.{
        .total = items,
        .width = width,
        .show_eta = false,
        .show_elapsed = true,
    });

    var i: usize = 0;
    while (i < items) : (i += 1) {
        bar.update(i + 1, null);
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    bar.finish();
}

fn customStyleDemo(items: u32, width: u32) void {
    var bar = zprogress.progressBar(.{
        .total = items,
        .width = width,
        .complete_char = "=",
        .incomplete_char = "-",
        .show_eta = true,
    });

    var i: usize = 0;
    while (i < items) : (i += 1) {
        bar.update(i + 1, null);
        std.Thread.sleep(15 * std.time.ns_per_ms);
    }
    bar.finish();
}

fn messageUpdateDemo() void {
    const phases = [_]struct { count: usize, message: []const u8 }{
        .{ .count = 25, .message = "Initializing..." },
        .{ .count = 50, .message = "Processing data..." },
        .{ .count = 75, .message = "Almost there..." },
        .{ .count = 100, .message = "Finishing up..." },
    };

    var bar = zprogress.progressBar(.{
        .total = 100,
        .width = 30,
        .show_eta = true,
    });

    var current: usize = 0;
    for (phases) |phase| {
        bar.setMessage(phase.message);
        while (current < phase.count) : (current += 1) {
            bar.update(current + 1, null);
            std.Thread.sleep(30 * std.time.ns_per_ms);
        }
    }
    bar.finishWithMessage("Complete!");
}
