//! Anchored dropdowns (ADR-0019): buttons that open a menu floating directly by
//! them, kept on screen with smart placement. It's composition of the pieces
//! built across the TUI thread —
//!
//!   - `ui.probe` reports each button's on-screen rect (the anchor),
//!   - `ui.stack` composites the menu over the base (ADR-0016),
//!   - `ui.anchored` places the menu at the anchor — flipping above / clamping
//!     left so it stays on screen (the smart counterpart to `ui.positioned`),
//!   - `ui.widgets.Select` is the menu list itself.
//!
//! Two buttons show the two behaviours: the top-left one opens its menu *below*
//! (plenty of room); the bottom-right one has no room below and would spill off
//! the right, so its menu **flips above** and **clamps left**. No core engine
//! change — the popup is just cells painted over the base at a computed offset.
//!
//! Click a button (or Space/Enter for the top one) to open; ↑/↓ move the
//! highlight; Enter chooses and closes; Esc closes (or quits when closed).
//!
//! The menu is anchored from the button's rect as probed on the PREVIOUS frame;
//! the button doesn't move, so that's exact (one frame of lag only on a resize) —
//! the immediate-mode trade `probe` already documents.
//!
//! Run with: zig build run-popup   (from packages/ui, needs a real TTY)

const std = @import("std");
const ui = @import("ui");
const terminal = @import("terminal");

pub const panic = ui.panic;

const options = [_][]const u8{ "Name", "Date modified", "Size", "Kind" };
const menu_rows: u16 = options.len; // short menu — show every option, no scroll

const State = struct {
    /// Which dropdown is open (at most one at a time).
    open: enum { none, top, corner } = .none,
    top: ui.widgets.Select = .{},
    corner: ui.widgets.Select = .{},
    // Each button's rect, filled by `ui.probe` in `view` — its menu's anchor.
    top_rect: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    corner_rect: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};

// A panel's border + (opaque) fill derive from the app theme's surface tokens
// (ADR-0020) — declare a root `zcli_theme` and every panel reskins.
fn panel(a: std.mem.Allocator, child: ui.Node) !ui.Node {
    return ui.panel(a, .{}, &.{child});
}

/// A dropdown button: a bordered label whose rect is probed into `out`.
fn button(a: std.mem.Allocator, out: *ui.Rect, label: []const u8) !ui.Node {
    const inner = try ui.row(a, .{ .padding = .symmetric(1, 0) }, &.{
        ui.textOpts(.{ .wrap = .clip }, label),
    });
    return ui.probe(a, out, try panel(a, inner));
}

fn view(a: std.mem.Allocator, state: *State) !ui.Node {
    // The top button is wide ("Sort: <value>"), but it fills its row, so its
    // left edge is pinned regardless of the value — its menu never moves.
    const top_caret: []const u8 = if (state.open == .top) "▴" else "▾";
    const top_label = try std.fmt.allocPrint(a, "Sort: {s}  {s}", .{ options[state.top.highlighted], top_caret });
    const top_button = try button(a, &state.top_rect, top_label);

    // The corner button is compact (narrower than its menu, so the menu visibly
    // clamps left) and RIGHT-anchored. Its label is FIXED — it doesn't reflow
    // with the selection — on purpose: a value-reflowing right-anchored button
    // would move its own left edge frame-to-frame, and the menu, faithfully
    // anchored to it, would appear to jitter (worsened by probe's one-frame lag).
    // A fixed-width trigger keeps the anchor still. The choice shows in the menu.
    const corner_label: []const u8 = if (state.open == .corner) "Sort ▴" else "Sort ▾";
    const corner_button = try button(a, &state.corner_rect, corner_label);

    // Base: top button in the top-left, corner button pinned bottom-right.
    const base = try ui.column(a, .{
        .padding = .all(1),
        .gap = 1,
        .width = .{ .fill = 1 },
        .height = .{ .fill = 1 },
    }, &.{
        ui.text(.{ .bold = true }, "Anchored dropdowns — flip + clamp"),
        top_button,
        ui.spacer(),
        ui.text(.{ .dim = true }, "Click a button (or Space for the top one) · ↑/↓ pick · Enter choose · Esc close · q quit"),
        try ui.row(a, .{}, &.{ ui.spacer(), corner_button }),
    });

    if (state.open == .none) return base;

    // Open: the menu floats in a stack layer, anchored to its button. `anchored`
    // opens it below when there's room (top) and flips above + clamps left when
    // there isn't (corner) — the same helper, the placement adapts to the rect.
    const sel = if (state.open == .top) &state.top else &state.corner;
    const rect = if (state.open == .top) state.top_rect else state.corner_rect;
    const menu = try panel(a, try sel.view(a, .{
        .focused = true,
        .options = &options,
        .height = menu_rows,
    }));
    return ui.stack(a, .{}, &.{
        base,
        try ui.anchored(a, rect, .{}, menu),
    });
}

fn hit(r: ui.Rect, x: u16, y: u16) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

fn update(state: *State, ev: ?ui.Event) !ui.Flow {
    const e = ev orelse return .keep;
    switch (e) {
        .key => |k| {
            if (state.open != .none) {
                // Menu open: navigation goes to the active Select; Enter/Esc close.
                const sel = if (state.open == .top) &state.top else &state.corner;
                if (sel.handle(k, options.len, menu_rows)) return .keep;
                switch (k) {
                    .enter, .escape => state.open = .none, // Enter keeps the highlight
                    else => {},
                }
            } else switch (k) {
                .char => |c| switch (c) {
                    ' ' => state.open = .top,
                    'q' => return .quit,
                    else => {},
                },
                .enter => state.open = .top,
                .escape => return .quit,
                .ctrl => |c| if (c == 'c') return .quit,
                else => {},
            }
        },
        .mouse => |m| {
            // Click a button to toggle its menu (hit-test the probed rects).
            if (m.button == .left and m.action == .press) {
                const px = m.x -| 1;
                const py = m.y -| 1;
                if (hit(state.top_rect, px, py)) {
                    state.open = if (state.open == .top) .none else .top;
                } else if (hit(state.corner_rect, px, py)) {
                    state.open = if (state.open == .corner) .none else .corner;
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
        .session = .{ .mouse = true }, // click a button to open
    });
    defer app.deinit();

    var state = State{};
    try app.run(io, &state, null, view, update, null); // no tick, no cursor hook
}
