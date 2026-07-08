//! Runnable showcase for the ui package (ADR-0013): the CLI/TUI hybrid in
//! one screen. An animated "deploy" frame — spinner, task list, live
//! progress gauges — repaints in place at the bottom edge, while completed
//! tasks are `emit`ted as static lines that flow into scrollback above it.
//!
//! Everything on screen is the four-node vocabulary: the frame is a bordered
//! column of rows; right-alignment is a spacer; the gauges are one `custom`
//! leaf stretched with `fill`. The tree is rebuilt from the App's frame
//! arena every frame (a component is just a function), and the diff renderer
//! emits only the cells that changed. The `App` owns the live region's rows,
//! the cursor, and the surfaces — the loop below is just build + emit.
//!
//! Run with: zig build run-demo   (from packages/ui, needs a real terminal)

const std = @import("std");
const ui = @import("ui");
const terminal = @import("terminal");

const frame_ms: u64 = 80;
const total_frames: u32 = 72;

const heading: ui.Style = .{ .bold = true, .foreground = .cyan };
const faint: ui.Style = .{ .dim = true };
const good: ui.Style = .{ .foreground = .green };

const Task = struct {
    name: []const u8,
    start: u32,
    duration: u32,

    fn fraction(self: Task, frame: u32) f32 {
        if (frame <= self.start) return 0;
        const elapsed = frame - self.start;
        if (elapsed >= self.duration) return 1;
        return @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(self.duration));
    }
};

const tasks = [_]Task{
    .{ .name = "compile zcli", .start = 0, .duration = 28 },
    .{ .name = "run tests", .start = 10, .duration = 34 },
    .{ .name = "bundle examples", .start = 22, .duration = 26 },
    .{ .name = "publish release", .start = 36, .duration = 24 },
};

fn taskRow(a: std.mem.Allocator, task: Task, frame: u32) !ui.Node {
    const frac = task.fraction(frame);
    const running = frame > task.start and frac < 1;
    const glyph = if (frac >= 1)
        ui.text(good, "✓")
    else if (running)
        ui.widgets.spinner(.{}, frame)
    else
        ui.text(faint, "◦");
    const name_style: ui.Style = if (running) .{ .bold = true } else if (frac >= 1) .{} else faint;
    const pct = try std.fmt.allocPrint(a, "{d:>3}%", .{@as(u8, @intFromFloat(frac * 100))});

    return ui.row(a, .{ .gap = 1 }, &.{
        glyph,
        ui.textOpts(.{ .style = name_style, .wrap = .truncate, .width = .{ .len = 16 } }, task.name),
        try ui.widgets.bar(a, .{}, frac),
        // .clip, not the .wrap default: the word-wrapper treats the pad
        // spaces in "  0%" as a break gap and would drop them.
        ui.textOpts(.{ .style = faint, .wrap = .clip }, pct),
    });
}

fn buildFrame(a: std.mem.Allocator, frame: u32, width: u16) !ui.Node {
    var sum: f32 = 0;
    var all_done = true;
    for (tasks) |t| {
        const f = t.fraction(frame);
        sum += f;
        if (f < 1) all_done = false;
    }

    const elapsed = try std.fmt.allocPrint(a, "{d:.1}s", .{
        @as(f32, @floatFromInt(frame)) * @as(f32, @floatFromInt(frame_ms)) / 1000.0,
    });

    var rows = std.ArrayList(ui.Node).empty;
    try rows.append(a, try ui.row(a, .{ .gap = 1 }, &.{
        if (all_done) ui.text(good, "✓") else ui.widgets.spinner(.{}, frame),
        ui.text(heading, "Deploying zcli demo"),
        ui.spacer(),
        ui.text(faint, elapsed),
    }));
    for (tasks) |t| try rows.append(a, try taskRow(a, t, frame));
    try rows.append(a, try ui.row(a, .{ .gap = 1 }, &.{
        ui.text(if (all_done) good else ui.Style{}, "overall"),
        try ui.widgets.bar(a, .{}, sum / tasks.len),
    }));

    return ui.column(a, .{
        .border = .rounded,
        .border_style = faint,
        .padding = .symmetric(1, 0),
        .width = .{ .len = width },
    }, rows.items);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var out_buf: [16384]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);

    const ws = terminal.getWindowSize(std.Io.File.stdout().handle) catch terminal.Winsize{ .row = 24, .col = 80 };
    const width: u16 = @min(64, ws.col);

    var app = try ui.App.init(gpa, &stdout.interface, .{ .capability = .ansi_16 });
    defer app.deinit();

    try app.emit("ui demo — finished tasks scroll up as static lines; the frame repaints in place", .{});

    var announced = [_]bool{false} ** tasks.len;
    var frame: u32 = 0;
    while (frame <= total_frames) : (frame += 1) {
        for (tasks, &announced) |task, *done| {
            if (!done.* and task.fraction(frame) >= 1) {
                done.* = true;
                try app.emit("✓ {s} ({d:.1}s)", .{
                    task.name,
                    @as(f32, @floatFromInt((task.start + task.duration) * frame_ms)) / 1000.0,
                });
            }
        }

        try app.frame(try buildFrame(app.arena(), frame, width));
        io.sleep(.{ .nanoseconds = frame_ms * std.time.ns_per_ms }, .awake) catch break;
    }

    try app.emit("deploy finished in {d:.1}s", .{
        @as(f32, @floatFromInt(total_frames * frame_ms)) / 1000.0,
    });
}
