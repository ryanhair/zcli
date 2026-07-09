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
    while (running) {
        try app.frame(try view(app.arena(), &state));
        const ev = try app.nextEvent(tick_ms) orelse {
            state.advance(); // timeout: refresh the table
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
