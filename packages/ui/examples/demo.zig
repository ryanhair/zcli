//! Runnable showcase for the ui package (ADR-0013 steps 1–2): an animated
//! "deploy" frame — spinner, task list, live progress gauges, right-aligned
//! elapsed time — repainted in place through the frame-diff renderer.
//!
//! Everything on screen is the four-node vocabulary: the frame is a bordered
//! column of rows; right-alignment is a spacer; the gauges are one `custom`
//! leaf stretched with `fill`. The whole tree is rebuilt into an arena every
//! frame (a component is just a function), and the diff renderer emits only
//! the cells that changed.
//!
//! This example hand-rolls what the App loop (build-order step 3) will own:
//! reserving the live region's rows, parking the cursor at the top-left,
//! double-buffering surfaces, and restoring the cursor on exit.
//!
//! Run with: zig build run-demo   (from packages/ui, needs a real terminal)

const std = @import("std");
const ui = @import("ui");
const terminal = @import("terminal");

const frame_ms: u64 = 80;
const total_frames: u32 = 72;

const spinner = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

const heading: ui.Style = .{ .bold = true, .foreground = .cyan };
const faint: ui.Style = .{ .dim = true };
const good: ui.Style = .{ .foreground = .green };
const busy: ui.Style = .{ .foreground = .yellow };

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

/// A progress gauge as a `custom` leaf: it reports a small natural size and
/// paints whatever width the layout grants it — combined with `.fill` sizing
/// it stretches to absorb the row's leftover space.
const Gauge = struct {
    frac: f32,

    fn measureFn(_: *anyopaque, _: *const ui.RenderCtx, limits: ui.Limits) ui.Size {
        return .{ .w = @min(limits.max_w, 10), .h = @min(limits.max_h, 1) };
    }

    fn renderFn(context: *anyopaque, _: *const ui.RenderCtx, region: ui.Region) anyerror!void {
        const self: *const Gauge = @ptrCast(@alignCast(context));
        const w = region.width();
        const filled: u16 = @intFromFloat(self.frac * @as(f32, @floatFromInt(w)));
        var x: u16 = 0;
        while (x < w) : (x += 1) {
            const on = x < filled;
            _ = try region.writeText(x, 0, if (on) "█" else "░", if (on) good else faint);
        }
    }

    fn node(a: std.mem.Allocator, frac: f32) !ui.Node {
        const self = try a.create(Gauge);
        self.* = .{ .frac = frac };
        return .{
            .width = .{ .fill = 1 },
            .kind = .{ .custom = .{
                .context = self,
                .measureFn = measureFn,
                .renderFn = renderFn,
            } },
        };
    }
};

fn taskRow(a: std.mem.Allocator, task: Task, frame: u32) !ui.Node {
    const frac = task.fraction(frame);
    const running = frame > task.start and frac < 1;
    const glyph = if (frac >= 1)
        ui.text(good, "✓")
    else if (running)
        ui.text(busy, spinner[frame % spinner.len])
    else
        ui.text(faint, "◦");
    const name_style: ui.Style = if (running) .{ .bold = true } else if (frac >= 1) .{} else faint;
    const pct = try std.fmt.allocPrint(a, "{d:>3}%", .{@as(u8, @intFromFloat(frac * 100))});

    return ui.row(a, .{ .gap = 1 }, &.{
        glyph,
        ui.textOpts(.{ .style = name_style, .wrap = .truncate, .width = .{ .len = 16 } }, task.name),
        try Gauge.node(a, frac),
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
        if (all_done) ui.text(good, "✓") else ui.text(heading, spinner[frame % spinner.len]),
        ui.text(heading, "Deploying zcli demo"),
        ui.spacer(),
        ui.text(faint, elapsed),
    }));
    for (tasks) |t| try rows.append(a, try taskRow(a, t, frame));
    try rows.append(a, try ui.row(a, .{ .gap = 1 }, &.{
        ui.text(if (all_done) good else ui.Style{}, "overall"),
        try Gauge.node(a, sum / tasks.len),
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
    const w = &stdout.interface;

    const ws = terminal.getWindowSize(std.Io.File.stdout().handle) catch terminal.Winsize{ .row = 24, .col = 80 };
    const width: u16 = @min(64, ws.col);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // The frame's height is constant in this demo, so measure once upfront to
    // size the region and the surfaces.
    const rctx0 = ui.RenderCtx{ .allocator = arena.allocator() };
    const probe = try buildFrame(arena.allocator(), 0, width);
    const size = ui.measure(&rctx0, &probe, .{ .max_w = width, .max_h = ws.row -| 2 });

    var prev = try ui.Surface.init(gpa, size.w, size.h);
    defer prev.deinit();
    var next = try ui.Surface.init(gpa, size.w, size.h);
    defer next.deinit();

    try w.writeAll("ui demo — the frame below repaints in place through the diff renderer\n\n");

    // Reserve the live region's rows, then park the cursor at its top-left
    // (the diff renderer's addressing contract).
    try w.writeAll("\x1b[?25l");
    var i: u16 = 0;
    while (i < size.h) : (i += 1) try w.writeAll("\n");
    try w.print("\x1b[{d}A", .{size.h});
    try w.flush();

    const renderer = ui.Renderer{ .capability = .ansi_16 };

    var painted: ?*ui.Surface = null;
    var frame: u32 = 0;
    while (frame <= total_frames) : (frame += 1) {
        _ = arena.reset(.retain_capacity);
        const rctx = ui.RenderCtx{ .allocator = arena.allocator() };

        next.clear();
        const tree = try buildFrame(arena.allocator(), frame, width);
        try ui.render(&rctx, &tree, next.root());

        try renderer.paint(w, painted, &next);
        try w.flush();

        std.mem.swap(ui.Surface, &prev, &next);
        painted = &prev;

        io.sleep(.{ .nanoseconds = frame_ms * std.time.ns_per_ms }, .awake) catch break;
    }

    // Leave the finished frame in scrollback: cursor below the region, shown.
    try w.print("\x1b[{d}B", .{size.h -| 1});
    try w.writeAll("\n\x1b[?25h");
    try w.flush();
}
