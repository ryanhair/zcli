//! A `top`-style full-screen TUI (ADR-0015): a live table of processes whose
//! CPU/MEM jitter on a 250ms tick, in a scrolling pane the arrow keys drive
//! (the selection scrolls into view — ADR-0017), with a `?`-toggled help
//! overlay (a centered modal composited over the table — ADR-0016). It drives
//! the `App.run(state, tick_ms, view, update)` loop —
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

// The help modal's border + fill come from one theme's surface tokens — change
// them in a single place and every panel reskins.
const th: ui.widgets.Theme = .{};

/// Visible rows in the scrolling process pane — a fixed window so `update` can
/// keep the selection in view without knowing the laid-out height.
const visible_rows: usize = 8;

const proc_names = [_][]const u8{
    "zig",      "zls",        "kernel_task",  "WindowServer",
    "Terminal", "firefox",    "Slack",        "node",
    "zcli",     "git",        "ripgrep",      "ssh",
    "dockerd",  "postgres",   "redis-server", "nginx",
    "python3",  "rustc",      "cargo",        "go",
    "vim",      "tmux",       "bash",         "launchd",
    "mdworker", "spotlightd", "cloudd",       "bluetoothd",
};

const Proc = struct { pid: u16, name: []const u8, cpu: f32, mem: f32 };

const State = struct {
    tick: u32 = 0,
    selected: usize = 0,
    scroll: u16 = 0, // first visible process row in the viewport
    show_help: bool = false,
    procs: [proc_names.len]Proc = undefined,
    last_mouse: ?ui.Mouse = null,
    focused: bool = true,
    // A printable preview of the last paste (copied out — `Event.paste` is only
    // borrowed for the current event).
    paste_len: usize = 0,
    paste_head: [24]u8 = undefined,
    paste_head_len: usize = 0,

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

    // The process rows live in a scrolling viewport (ADR-0017): the list is
    // taller than its fixed window, so `state.scroll` (kept in view by `update`)
    // slides it. The header above and the status below stay put.
    const proc_rows = try a.alloc(ui.Node, state.procs.len);
    for (state.procs, proc_rows, 0..) |p, *row_node, i| {
        const line = try std.fmt.allocPrint(a, "{d:>5} {d:>6.1} {d:>7.1}  {s}", .{
            p.pid, p.cpu, p.mem, p.name,
        });
        const style: ui.Style = if (i == state.selected) .{ .reverse = true } else .{};
        row_node.* = ui.textOpts(.{ .style = style, .wrap = .clip }, line);
    }
    try rows.append(a, try ui.viewport(a, .{
        .scroll_y = state.scroll,
        .height = .{ .len = @intCast(visible_rows) },
    }, try ui.column(a, .{}, proc_rows)));

    try rows.append(a, ui.spacer());
    const mouse = if (state.last_mouse) |m|
        try std.fmt.allocPrint(a, "{s} @ {d},{d}", .{ @tagName(m.button), m.x, m.y })
    else
        "—";
    const paste = if (state.paste_len > 0)
        try std.fmt.allocPrint(a, "{d}b \"{s}\"", .{ state.paste_len, state.paste_head[0..state.paste_head_len] })
    else
        "—";
    const status = try std.fmt.allocPrint(a, "↑/↓ select   click a cell   paste   ? help   q quit    focus:{s}  mouse:{s}  paste:{s}", .{
        if (state.focused) "on" else "off",
        mouse,
        paste,
    });
    try rows.append(a, ui.text(.{ .dim = true }, status));

    const base = try ui.column(
        a,
        .{ .width = .{ .fill = 1 }, .height = .{ .fill = 1 }, .padding = .all(1) },
        rows.items,
    );
    if (!state.show_help) return base;

    // An overlay (ADR-0016): a centered help modal composited over the table.
    // `stack` overlaps its layers back to front; `center` floats the opaque
    // modal in the middle while the table shows through the transparent
    // scaffold around it. No absolute addressing — the modal is just cells
    // painted on top of the base surface before the frame diff runs.
    return ui.stack(a, .{}, &.{
        base,
        try ui.center(a, try helpModal(a)),
    });
}

fn helpModal(a: std.mem.Allocator) !ui.Node {
    return ui.column(a, .{
        .border = .rounded,
        .border_style = th.surface.border.resolve(th.palette),
        .padding = .symmetric(2, 1),
        .style = th.surface.panel.resolve(th.palette), // opaque panel
        .gap = 0,
    }, &.{
        ui.text(.{ .bold = true }, "Keys"),
        ui.text(.{}, ""),
        ui.text(.{}, "↑ / ↓   select a process"),
        ui.text(.{}, "click   select a row"),
        ui.text(.{}, "?       close this help"),
        ui.text(.{}, "q       quit"),
    });
}

/// Slide the scroll offset so the selected row stays inside the fixed viewport
/// window — the immediate-mode analogue of a list widget's "scroll into view".
fn keepSelectionVisible(state: *State) void {
    if (state.selected < state.scroll) {
        state.scroll = @intCast(state.selected);
    } else if (state.selected >= state.scroll + visible_rows) {
        state.scroll = @intCast(state.selected - visible_rows + 1);
    }
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
            .char => |c| switch (c) {
                'q' => return .quit,
                '?' => state.show_help = !state.show_help, // toggle the overlay
                else => {},
            },
            .ctrl => |c| if (c == 'c') return .quit,
            .up => if (state.selected > 0) {
                state.selected -= 1;
                keepSelectionVisible(state);
            },
            .down => if (state.selected + 1 < state.procs.len) {
                state.selected += 1;
                keepSelectionVisible(state);
            },
            else => {},
        },
        .mouse => |m| {
            state.last_mouse = m;
            // Left-click a process row: the viewport starts at y=3 (padding +
            // title + header), so a click maps through the scroll offset.
            if (m.button == .left and m.action == .press and m.y >= 3) {
                const vis = m.y - 3;
                if (vis < visible_rows) {
                    const row = @as(usize, state.scroll) + vis;
                    if (row < state.procs.len) state.selected = row;
                }
            }
        },
        .focus => |f| state.focused = f == .in,
        .paste => |p| {
            state.paste_len = p.len;
            state.paste_head_len = @min(p.len, state.paste_head.len);
            for (p[0..state.paste_head_len], 0..) |c, i| {
                state.paste_head[i] = if (c >= 0x20 and c < 0x7f) c else ' ';
            }
        },
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
        .paste = true,
    });
    defer app.deinit(); // leaves alt-screen, restores cooked mode + cursor

    var state = State.init();
    try app.run(io, &state, tick_ms, view, update, null);
}
