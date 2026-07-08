//! The Claude-Code-shaped hybrid (ADR-0013 step 4): streaming text flowing
//! into scrollback while an animated, bordered status frame — spinner,
//! multi-bar of parallel fetches — repaints in place at the bottom edge.
//!
//! This is the shape the whole engine exists for: `emit` for every line of
//! prose (static, line-oriented, retained for resize reflow), `frame` for
//! the live region, `ui.widgets` for the progress vocabulary. Resize the
//! terminal mid-run: the prose tail rewraps along with the frame.
//!
//! Run with: zig build run-hybrid   (from packages/ui, needs a real terminal)

const std = @import("std");
const ui = @import("ui");
const terminal = @import("terminal");

const frame_ms: u64 = 80;

const prose = [_][]const u8{
    "I'll refactor the parser to use the new streaming API.",
    "",
    "Looking at src/parser.zig, the tokenizer currently buffers the",
    "whole input before emitting anything. The streaming API lets us",
    "yield tokens as they decode, which drops peak memory on large",
    "files and lets the formatter start work immediately.",
    "",
    "Fetching the three modules that depend on the tokenizer so the",
    "call sites migrate in the same change...",
};

const Fetch = struct {
    name: []const u8,
    start: u32,
    duration: u32,

    fn fraction(self: Fetch, frame: u32) f32 {
        if (frame <= self.start) return 0;
        const elapsed = frame - self.start;
        if (elapsed >= self.duration) return 1;
        return @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(self.duration));
    }
};

const fetches = [_]Fetch{
    .{ .name = "src/parser.zig", .start = 4, .duration = 40 },
    .{ .name = "src/formatter.zig", .start = 12, .duration = 44 },
    .{ .name = "src/lsp/handlers.zig", .start = 20, .duration = 36 },
};
const total_frames: u32 = 72;

fn statusFrame(a: std.mem.Allocator, frame: u32, width: u16) !ui.Node {
    const elapsed = try std.fmt.allocPrint(a, "{d:.1}s", .{
        @as(f32, @floatFromInt(frame)) * @as(f32, @floatFromInt(frame_ms)) / 1000.0,
    });

    var items: [fetches.len]ui.widgets.MultiBarItem = undefined;
    for (fetches, &items) |f, *item| {
        item.* = .{ .label = f.name, .fraction = f.fraction(frame) };
    }

    return ui.column(a, .{
        .border = .rounded,
        .border_style = .{ .dim = true },
        .padding = .symmetric(1, 0),
        .width = .{ .len = width },
        .gap = 0,
    }, &.{
        try ui.row(a, .{ .gap = 1 }, &.{
            ui.widgets.spinner(.{}, frame),
            ui.text(.{ .bold = true }, "Reading dependencies"),
            ui.spacer(),
            ui.text(.{ .dim = true }, elapsed),
        }),
        try ui.widgets.multiBar(a, .{}, &items),
    });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var out_buf: [16384]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);

    const ws = terminal.getWindowSize(std.Io.File.stdout().handle) catch terminal.Winsize{ .row = 24, .col = 80 };
    const width: u16 = @min(64, ws.col);

    var app = try ui.App.init(gpa, &stdout.interface, .{ .capability = .ansi_256 });
    defer app.deinit();

    var prose_i: usize = 0;
    var announced = [_]bool{false} ** fetches.len;
    var frame: u32 = 0;
    while (frame <= total_frames) : (frame += 1) {
        // Stream a prose line into the static region every few ticks.
        if (frame % 4 == 0 and prose_i < prose.len) {
            try app.emit("{s}", .{prose[prose_i]});
            prose_i += 1;
        }
        for (fetches, &announced) |f, *done| {
            if (!done.* and f.fraction(frame) >= 1) {
                done.* = true;
                try app.emit("✓ read {s}", .{f.name});
            }
        }

        try app.frame(try statusFrame(app.arena(), frame, width));
        io.sleep(.{ .nanoseconds = frame_ms * std.time.ns_per_ms }, .awake) catch break;
    }

    try app.emit("all dependencies read — starting the refactor", .{});
}
