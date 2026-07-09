//! A `top`-style full-screen TUI (ADR-0015): the whole viewport is a live table
//! of processes whose CPU/MEM jitter on a 250ms tick, with an arrow-key
//! selection. It drives the `App.run(state, tick_ms, view, update)` loop —
//!
//!     view(state)           render the whole screen from state
//!     update(state, ev)      handle a key/resize, or a `null` tick; -> keep|quit
//!
//! — reusing the same layout engine as the hybrid, just in alt-screen mode. On
//! exit (q or Ctrl-C) the shell's screen and scrollback come back exactly as
//! they were: the final frame does not persist (that is the feature).
//!
//! `run` owns the loop and schedules the tick against a deadline (a burst of
//! keys shrinks the wait rather than resetting it, so input can't starve the
//! refresh). The explicit `frame`/`nextEvent` loop `run` wraps is still there
//! if you need it — see `App.run`'s doc comment.
//!
//! Run with: zig build run-fullscreen   (from packages/ui, needs a real TTY)

const std = @import("std");
const ui = @import("ui");
const terminal = @import("terminal");

/// Restore the terminal on a panic before the trace prints — required for
/// full-screen (a panic doesn't run `defer app.deinit()`, and would otherwise
/// strand the alt-screen). `App.initFullScreen` won't compile without it.
pub const panic = ui.panic;

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
    last_mouse: ?ui.Mouse = null,
    focused: bool = true,

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

fn view(a: std.mem.Allocator, state: *State) !ui.Node {
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
    const mouse = if (state.last_mouse) |m|
        try std.fmt.allocPrint(a, "{s} @ {d},{d}", .{ @tagName(m.button), m.x, m.y })
    else
        "—";
    const status = try std.fmt.allocPrint(a, "↑/↓ select   click a cell   q quit    focus:{s}  mouse:{s}", .{
        if (state.focused) "on" else "off",
        mouse,
    });
    try rows.append(a, ui.text(.{ .dim = true }, status));

    return ui.column(
        a,
        .{ .width = .{ .fill = 1 }, .height = .{ .fill = 1 }, .padding = .all(1) },
        rows.items,
    );
}

/// A `null` event is the tick (advance the jittering table); keys drive
/// selection and quitting. Ctrl-C is an ordinary key here (raw mode cleared
/// ISIG). Resize needs nothing — `run` re-renders every pass.
fn update(state: *State, ev: ?ui.Event) !ui.Flow {
    const e = ev orelse {
        state.advance();
        return .keep;
    };
    switch (e) {
        .key => |k| switch (k) {
            .char => |c| if (c == 'q') return .quit,
            .ctrl => |c| if (c == 'c') return .quit,
            .up => if (state.selected > 0) {
                state.selected -= 1;
            },
            .down => if (state.selected + 1 < state.procs.len) {
                state.selected += 1;
            },
            else => {},
        },
        .mouse => |m| {
            state.last_mouse = m;
            // Left-click a table row (rows start at y=3: padding + title + header).
            if (m.button == .left and m.action == .press and m.y >= 3) {
                const row = m.y - 3;
                if (row < state.procs.len) state.selected = row;
            }
        },
        .focus => |f| state.focused = f == .in,
        .resize => {},
    }
    return .keep;
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

    var app = try ui.App.initFullScreen(gpa, &stdout.interface, .{
        .capability = .ansi_256,
        .stdin = &stdin.interface,
        .mouse = true,
        .focus = true,
    });
    defer app.deinit(); // leaves alt-screen, restores cooked mode + cursor

    var state = State.init();
    try app.run(io, &state, tick_ms, view, update);
}
