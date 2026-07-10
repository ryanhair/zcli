//! An anchored dropdown (ADR-0019): a button that opens a menu floating directly
//! below it. It's pure composition of the pieces built across the TUI thread —
//!
//!   - `ui.probe` reports the button's on-screen rect (the anchor),
//!   - `ui.stack` composites the menu over the base (ADR-0016),
//!   - `ui.positioned` places the menu at the anchor's rect,
//!   - `ui.widgets.Select` is the menu list itself.
//!
//! Space/Enter/click opens the menu; ↑/↓ move the highlight; Enter chooses and
//! closes; Esc closes (or quits when already closed). No core engine change —
//! the popup is just cells painted over the base surface at an offset.
//!
//! The menu is positioned from the button's rect as probed on the PREVIOUS
//! frame; the button doesn't move, so that's exact (one frame of lag only on a
//! resize) — the immediate-mode trade `probe` already documents.
//!
//! Run with: zig build run-popup   (from packages/ui, needs a real TTY)

const std = @import("std");
const ui = @import("ui");
const terminal = @import("terminal");

pub const panic = ui.panic;

const options = [_][]const u8{ "Name", "Date modified", "Size", "Kind" };
const menu_rows: u16 = options.len; // short menu — show every option, no scroll

const State = struct {
    open: bool = false,
    menu: ui.widgets.Select = .{},
    // The button's rect, filled by `ui.probe` in `view` — the popup's anchor.
    button: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};

fn panel(a: std.mem.Allocator, child: ui.Node) !ui.Node {
    return ui.column(a, .{
        .border = .rounded,
        .border_style = .{ .foreground = .bright_cyan },
        .style = .{ .background = .{ .indexed = 236 } },
    }, &.{child});
}

fn view(a: std.mem.Allocator, state: *State) !ui.Node {
    const caret: []const u8 = if (state.open) "▴" else "▾";
    const label = try std.fmt.allocPrint(a, "Sort: {s}  {s}", .{ options[state.menu.highlighted], caret });

    // The button is the anchor — probe its rect so the menu can pin under it.
    const button_label = try ui.row(a, .{ .padding = .symmetric(1, 0) }, &.{
        ui.textOpts(.{ .wrap = .clip }, label),
    });
    const button = try ui.probe(a, &state.button, try panel(a, button_label));

    const base = try ui.column(a, .{
        .padding = .all(1),
        .gap = 1,
        .width = .{ .fill = 1 },
        .height = .{ .fill = 1 },
    }, &.{
        ui.text(.{ .bold = true }, "Anchored dropdown"),
        button,
        ui.spacer(),
        ui.text(.{ .dim = true }, "Space/Enter/click opens · ↑/↓ pick · Enter choose · Esc close · q quit"),
    });

    if (!state.open) return base;

    // Open: the menu floats in a stack layer, positioned just below the button.
    const menu = try panel(a, try state.menu.view(a, .{
        .focused = true,
        .options = &options,
        .height = menu_rows,
    }));
    return ui.stack(a, .{}, &.{
        base,
        try ui.positioned(a, state.button.x, state.button.y + state.button.h, menu),
    });
}

fn update(state: *State, ev: ?ui.Event) !ui.Flow {
    const e = ev orelse return .keep;
    switch (e) {
        .key => |k| {
            if (state.open) {
                // Menu open: navigation goes to the Select; Enter/Esc close it.
                if (state.menu.handle(k, options.len, menu_rows)) return .keep;
                switch (k) {
                    .enter, .escape => state.open = false, // Enter keeps the highlight
                    else => {},
                }
            } else switch (k) {
                .char => |c| switch (c) {
                    ' ' => state.open = true,
                    'q' => return .quit,
                    else => {},
                },
                .enter => state.open = true,
                .escape => return .quit,
                .ctrl => |c| if (c == 'c') return .quit,
                else => {},
            }
        },
        .mouse => |m| {
            // Click the button to toggle the menu (hit-test its probed rect).
            if (m.button == .left and m.action == .press) {
                const px = m.x -| 1;
                const py = m.y -| 1;
                const r = state.button;
                if (px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h) {
                    state.open = !state.open;
                }
            }
        },
        else => {},
    }
    return .keep;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    if (!terminal.isStdoutTty()) {
        var err_buf: [256]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(io, &err_buf);
        try stderr.interface.writeAll("popup: needs an interactive terminal\n");
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
        .mouse = true, // click the button to open
    });
    defer app.deinit();

    var state = State{};
    try app.run(io, &state, null, view, update, null); // no tick, no cursor hook
}
