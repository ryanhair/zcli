//! A `top`-style full-screen TUI (ADR-0015 step 4): the whole viewport is a
//! live table of processes whose CPU/MEM jitter on a 250ms tick, with an
//! arrow-key selection. It validates the loop shape the ADR proposes —
//!
//!     frame(view(state))            paint the whole screen
//!     nextEvent(250) orelse tick()  block for a key/resize, or refresh
//!
//! — reusing the same layout engine as the hybrid, just in alt-screen mode.
//! On exit (q or Ctrl-C) the shell's screen and scrollback come back exactly
//! as they were: the final frame does not persist (that is the feature).
//!
//! The tick is scheduled against an absolute DEADLINE, not a fresh
//! `nextEvent(250)` each pass: a burst of key input (holding an arrow repeats
//! every ~30ms) must not keep resetting the timeout and starve the refresh.
//! Each early wakeup shrinks the remaining window instead of restarting it, so
//! the table keeps churning on wall-clock time no matter how fast keys arrive —
//! one thread, no timer, exactly the loop shape the ADR intended.
//!
//! Run with: zig build run-fullscreen   (from packages/ui, needs a real TTY)

const std = @import("std");
const ui = @import("ui");
const terminal = @import("terminal");

const tick_ms: u32 = 250;

const proc_names = [_][]const u8{
    "zig",      "zls",     "kernel_task", "WindowServer",
    "Terminal", "firefox", "Slack",       "node",
    "zcli",     "git",     "ripgrep",     "ssh",
};

const Proc = struct { pid: u16, name: []const u8, cpu: f32, mem: f32 };

const State = struct {
    tick: u32 = 0,
    selected: usize = 0,
    procs: [proc_names.len]Proc = undefined,

    fn init() State {
        var s = State{};
        for (proc_names, 0..) |n, i| {
            s.procs[i] = .{ .pid = @intCast(1000 + i * 137), .name = n, .cpu = 0, .mem = 0 };
        }
        s.refresh();
        return s;
    }

    /// Cheap deterministic per-cell jitter — no RNG dependency, just a hash of
    /// (tick, row) so the table visibly churns each refresh.
    fn refresh(self: *State) void {
        for (&self.procs, 0..) |*p, i| {
            const seed = self.tick *% 2654435761 +% @as(u32, @intCast(i)) *% 40503 +% 1;
            p.cpu = @as(f32, @floatFromInt(seed % 1000)) / 10.0;
            p.mem = @as(f32, @floatFromInt((seed >> 7) % 5000)) / 10.0;
        }
    }

    fn advance(self: *State) void {
        self.tick += 1;
        self.refresh();
    }
};

/// Monotonic milliseconds — the clock the deadline loop schedules against
/// (the same `std.Io.Clock` source `progress` uses for its animation timing).
fn nowMs(io: std.Io) u64 {
    const ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}

fn view(a: std.mem.Allocator, state: *const State) !ui.Node {
    var rows = std.ArrayList(ui.Node).empty;

    const elapsed = try std.fmt.allocPrint(a, "{d:.1}s", .{
        @as(f32, @floatFromInt(state.tick * tick_ms)) / 1000.0,
    });
    try rows.append(a, try ui.row(a, .{ .gap = 1 }, &.{
        ui.text(.{ .bold = true }, "zcli top"),
        ui.spacer(),
        ui.text(.{ .dim = true }, elapsed),
    }));

    try rows.append(a, ui.textOpts(
        .{ .style = .{ .bold = true, .underline = true }, .wrap = .clip },
        "  PID   CPU%    MEM%  COMMAND",
    ));

    for (state.procs, 0..) |p, i| {
        const line = try std.fmt.allocPrint(a, "{d:>5} {d:>6.1} {d:>7.1}  {s}", .{
            p.pid, p.cpu, p.mem, p.name,
        });
        const style: ui.Style = if (i == state.selected) .{ .reverse = true } else .{};
        try rows.append(a, ui.textOpts(.{ .style = style, .wrap = .clip }, line));
    }

    try rows.append(a, ui.spacer());
    try rows.append(a, ui.text(.{ .dim = true }, "↑/↓ select   q quit"));

    return ui.column(
        a,
        .{ .width = .{ .fill = 1 }, .height = .{ .fill = 1 }, .padding = .all(1) },
        rows.items,
    );
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    if (!terminal.isStdoutTty()) {
        var err_buf: [256]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(io, &err_buf);
        try stderr.interface.writeAll("fullscreen: needs an interactive terminal\n");
        try stderr.interface.flush();
        return;
    }

    var out_buf: [1 << 14]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    var in_buf: [256]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &in_buf);

    var app = try ui.App.init(gpa, &stdout.interface, .{
        .capability = .ansi_256,
        .mode = .full_screen,
        .stdin = &stdin.interface,
    });
    defer app.deinit(); // leaves alt-screen, restores cooked mode + cursor

    var state = State.init();
    var running = true;
    var next_tick = nowMs(io) + tick_ms;
    while (running) {
        try app.frame(try view(app.arena(), &state));

        // Wait only until the next scheduled tick — not a full `tick_ms` — so
        // continuous key input can't keep pushing the refresh out (see the
        // module header). A wakeup at or past the deadline is itself a tick.
        const now = nowMs(io);
        if (now >= next_tick) {
            state.advance();
            next_tick = now + tick_ms;
            continue;
        }
        const ev = try app.nextEvent(@intCast(next_tick - now)) orelse {
            state.advance(); // deadline reached with no input: refresh the table
            next_tick = nowMs(io) + tick_ms;
            continue;
        };
        switch (ev) {
            .key => |k| switch (k) {
                .char => |c| if (c == 'q') {
                    running = false;
                },
                .ctrl => |c| if (c == 'c') {
                    running = false; // Ctrl-C is a key here (raw mode cleared ISIG)
                },
                .up => if (state.selected > 0) {
                    state.selected -= 1;
                },
                .down => if (state.selected + 1 < state.procs.len) {
                    state.selected += 1;
                },
                else => {},
            },
            .resize => {}, // next frame re-anchors and re-measures
        }
    }
}
