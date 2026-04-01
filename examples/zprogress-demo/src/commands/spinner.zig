const std = @import("std");
const zcli = @import("zcli");
const zprogress = zcli.zprogress;

pub const meta = .{
    .description = "Demonstrate spinner animations",
    .examples = &.{
        "zpdemo spinner                  # Run all spinner demos",
        "zpdemo spinner --style dots     # Demo specific style",
        "zpdemo spinner --duration 3000  # Custom duration in ms",
    },
    .options = .{
        .style = .{ .description = "Spinner style: dots, dots2, dots3, line, arrow, bounce, clock, moon, simple" },
        .duration = .{ .description = "Duration in milliseconds for each demo" },
    },
};

pub const Args = struct {};

pub const Options = struct {
    style: ?[]const u8 = null,
    duration: u32 = 2000,
};

pub fn execute(_: Args, options: Options, context: anytype) !void {
    const stdout = context.stdout();

    if (options.style) |style_name| {
        // Demo a single style
        const style = parseStyle(style_name) orelse {
            try stdout.print("Unknown style: {s}\n", .{style_name});
            try stdout.print("Valid styles: dots, dots2, dots3, line, arrow, bounce, clock, moon, simple\n", .{});
            return;
        };
        demoSpinner(style, style_name, options.duration);
    } else {
        // Demo all styles
        try stdout.print("Spinner Style Demos\n", .{});
        try stdout.print("===================\n\n", .{});

        const styles = [_]struct { style: zprogress.SpinnerStyle, name: []const u8 }{
            .{ .style = .dots, .name = "dots" },
            .{ .style = .dots2, .name = "dots2" },
            .{ .style = .dots3, .name = "dots3" },
            .{ .style = .line, .name = "line" },
            .{ .style = .arrow, .name = "arrow" },
            .{ .style = .bounce, .name = "bounce" },
            .{ .style = .clock, .name = "clock" },
            .{ .style = .moon, .name = "moon" },
            .{ .style = .simple, .name = "simple" },
        };

        for (styles) |s| {
            demoSpinner(s.style, s.name, options.duration);
        }

        try stdout.print("\nAll spinner demos complete!\n", .{});
    }
}

fn parseStyle(name: []const u8) ?zprogress.SpinnerStyle {
    if (std.mem.eql(u8, name, "dots")) return .dots;
    if (std.mem.eql(u8, name, "dots2")) return .dots2;
    if (std.mem.eql(u8, name, "dots3")) return .dots3;
    if (std.mem.eql(u8, name, "line")) return .line;
    if (std.mem.eql(u8, name, "arrow")) return .arrow;
    if (std.mem.eql(u8, name, "bounce")) return .bounce;
    if (std.mem.eql(u8, name, "clock")) return .clock;
    if (std.mem.eql(u8, name, "moon")) return .moon;
    if (std.mem.eql(u8, name, "simple")) return .simple;
    return null;
}

fn demoSpinner(style: zprogress.SpinnerStyle, name: []const u8, duration: u32) void {
    var spinner = zprogress.spinner(.{
        .style = style,
    });

    var msg_buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Demonstrating '{s}' style...", .{name}) catch "Loading...";
    spinner.start(msg);

    const start = std.time.milliTimestamp();
    const duration_ms: i64 = @intCast(duration);

    while (std.time.milliTimestamp() - start < duration_ms) {
        spinner.tick();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    var success_buf: [64]u8 = undefined;
    const success_msg = std.fmt.bufPrint(&success_buf, "'{s}' style demo complete", .{name}) catch "Done!";
    spinner.succeed(success_msg);
}
