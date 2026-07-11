//! A `top`-style full-screen TUI (ADR-0015): a live table of processes whose
//! CPU/MEM jitter on a 250ms tick, driven by the `Table` widget (ADR-0021) —
//! the arrow keys and PgUp/PgDn move the selection and the widget keeps it in
//! its scroll window, so the example carries no manual scroll bookkeeping. A
//! `Tabs` bar (ADR-0021 incr2) pages between the live process view and an
//! "About" pane — ←/→ or the number keys switch the active tab, and the caller
//! (this example) swaps the content it renders below the bar; the widget is only
//! the chrome. A `?`-toggled help overlay (a centered modal composited over the
//! screen — ADR-0016) floats on top. It drives the `App.run(state, tick_ms,
//! view, update)` loop —
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

/// Visible body rows in the process `Table` — the height its scroll window pages
/// by, passed to both `Table.view` and `Table.handle` so they stay in step.
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

/// The process table's columns. Numeric columns are fixed-width (`.len`) so they
/// don't jitter as the values churn; COMMAND fills the leftover width.
const proc_columns = [_]ui.widgets.Table.Column{
    .{ .header = "PID", .width = .{ .len = 5 } },
    .{ .header = "CPU%", .width = .{ .len = 6 } },
    .{ .header = "MEM%", .width = .{ .len = 6 } },
    .{ .header = "COMMAND", .width = .{ .fill = 1 } },
};

const Proc = struct { pid: u16, name: []const u8, cpu: f32, mem: f32 };

/// The tab-bar labels. The active index (`State.active_tab`) is caller-owned;
/// `Tabs` only advances it — the content pane below the bar is switched here.
const tab_labels = [_][]const u8{ "1 Processes", "2 About" };

const State = struct {
    tick: u32 = 0,
    /// The `Tabs` bar's active index — caller-owned, advanced by `Tabs.handle`.
    tabs: ui.widgets.Tabs = .{},
    active_tab: usize = 0,
    /// The process grid: `table.highlighted` is the selected row and `table.scroll`
    /// its window top — both maintained by `Table.handle`, so `update` no longer
    /// tracks the selection or slides a scroll offset by hand.
    table: ui.widgets.Table = .{},
    /// The process table's rendered rect (written by `ui.probe` each frame), so a
    /// click hit-tests against the very layout it's reacting to — no magic offsets.
    table_rect: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
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

    // The `Tabs` bar (ADR-0021 incr2): a strip of styled labels with the active
    // one highlighted. It owns no content — the caller (below) switches which
    // pane it renders on `state.active_tab`.
    try rows.append(a, try state.tabs.view(a, .{
        .focused = true,
        .labels = &tab_labels,
        .active = state.active_tab,
    }));
    try rows.append(a, ui.text(.{}, ""));

    // Tab 0 is the live process grid; tab 1 is a static About pane. The tab bar
    // is chrome; this switch is what "owns the content" means in the ADR.
    if (state.active_tab == 0) {
        // The process grid is a real `Table` (ADR-0021): PID/CPU%/MEM%/COMMAND
        // columns whose widths the layout engine sizes (`.len`/`.fill`), the
        // selected row highlighted, and a proportional scrollbar in the gutter
        // (`scrollbar = true`, ADR-0021 incr5 — the richer indicator replacing the
        // overflow arrows). The list is taller than the `visible_rows` window, so
        // `Table` scrolls to keep the selection in view — no manual scroll offset.
        const grid = try a.alloc([]const []const u8, state.procs.len);
        for (state.procs, grid) |p, *cells| {
            const row_cells = try a.alloc([]const u8, 4);
            row_cells[0] = try std.fmt.allocPrint(a, "{d}", .{p.pid});
            row_cells[1] = try std.fmt.allocPrint(a, "{d:.1}", .{p.cpu});
            row_cells[2] = try std.fmt.allocPrint(a, "{d:.1}", .{p.mem});
            row_cells[3] = p.name;
            cells.* = row_cells;
        }
        // Wrap the table in `ui.probe` so its rendered rect lands in `table_rect`
        // for click hit-testing (see `update`'s mouse arm). The probe is layout-
        // transparent — it reports the rect, it doesn't change the layout.
        try rows.append(a, try ui.probe(a, &state.table_rect, try state.table.view(a, .{
            .focused = true,
            .columns = &proc_columns,
            .rows = grid,
            .height = @intCast(visible_rows),
            .scrollbar = true,
        })));
    } else {
        try rows.append(a, ui.text(.{ .bold = true }, "About"));
        try rows.append(a, ui.text(.{}, ""));
        try rows.append(a, ui.text(.{ .dim = true }, "A full-screen zcli/ui demo: Table + Tabs + an overlay,"));
        try rows.append(a, ui.text(.{ .dim = true }, "all on the same immediate-mode layout engine (ADR-0021)."));
    }

    try rows.append(a, ui.spacer());
    const mouse = if (state.last_mouse) |m|
        try std.fmt.allocPrint(a, "{s} @ {d},{d}", .{ @tagName(m.button), m.x, m.y })
    else
        "—";
    const paste = if (state.paste_len > 0)
        try std.fmt.allocPrint(a, "{d}b \"{s}\"", .{ state.paste_len, state.paste_head[0..state.paste_head_len] })
    else
        "—";
    const status = try std.fmt.allocPrint(a, "←/→ tab   ↑/↓ select   PgUp/PgDn page   click a row   ? help   q quit    focus:{s}  mouse:{s}  paste:{s}", .{
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
    // A panel's border + (opaque) fill derive from the app theme's surface
    // tokens (ADR-0020) — declare a root `zcli_theme` and every panel reskins.
    return ui.panel(a, .{
        .padding = .symmetric(2, 1),
    }, &.{
        ui.text(.{ .bold = true }, "Keys"),
        ui.text(.{}, ""),
        ui.text(.{}, "← / →        switch tab (or 1/2)"),
        ui.text(.{}, "↑ / ↓        select a process"),
        ui.text(.{}, "PgUp / PgDn  page the selection"),
        ui.text(.{}, "click        select a row"),
        ui.text(.{}, "?            close this help"),
        ui.text(.{}, "q            quit"),
    });
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
        .key => |k| {
            // The `Tabs` bar consumes ←/→ and the number keys (1/2) to switch the
            // active tab; the Table consumes selection/paging keys (↑/↓/Home/End/
            // PgUp/PgDn) on the process tab. Only unconsumed keys fall through to
            // form-level navigation (q, ?, Ctrl-C) below.
            if (state.tabs.handle(k, &state.active_tab, tab_labels.len)) return .keep;
            if (state.active_tab == 0 and
                state.table.handle(k, state.procs.len, @intCast(visible_rows))) return .keep;
            switch (k) {
                .char => |c| switch (c) {
                    'q' => return .quit,
                    '?' => state.show_help = !state.show_help, // toggle the overlay
                    else => {},
                },
                .ctrl => |c| if (c == 'c') return .quit,
                else => {},
            }
        },
        .mouse => |m| {
            state.last_mouse = m;
            // Left-click a process row (process tab only). `Table.rowAt` maps the
            // click through the probed rect and the widget's scroll window — it
            // subtracts the header row itself, so there are no layout magic numbers
            // here. Mouse reports are 1-based; `probe` rects are 0-based, so pass
            // `m.y - 1`. `rowAt` rejects the header; we clamp against the row count.
            if (state.active_tab == 0 and m.button == .left and m.action == .press) {
                if (state.table.rowAt(state.table_rect, m.y - 1)) |row| {
                    if (row < state.procs.len) state.table.highlighted = row;
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
