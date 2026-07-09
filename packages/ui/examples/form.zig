//! A focusable form (ADR-0018): two text fields, a select, a checkbox, and a
//! submit button, with Tab / Shift-Tab (and Enter) moving focus, a mouse click
//! focusing a field (ADR-0019), ↑/↓ picking within the select, Space toggling
//! the checkbox, the button signing in on Enter/Space, and Esc quitting. It
//! shows the whole widget contract in one screen:
//!
//!   - each widget is a plain struct in `State` (immediate mode — no retained
//!     widget tree);
//!   - `update` gives the focused widget first crack at a key via `handle`,
//!     which returns whether it consumed it. An unconsumed key (Tab, Enter, Esc)
//!     is form-level navigation. That one bool is the entire routing model.
//!   - `view` passes `focused` to each widget so it draws its caret/highlight.
//!
//! Focus is caller-owned (a `Field` enum); `ui.widgets.focusNext`/`focusPrev`
//! are the only helpers the library adds.
//!
//! Run with: zig build run-form   (from packages/ui, needs a real TTY)

const std = @import("std");
const ui = @import("ui");
const terminal = @import("terminal");

pub const panic = ui.panic;

const Field = enum { user, pass, role, remember, submit };
const field_count = @typeInfo(Field).@"enum".fields.len;

const roles = [_][]const u8{ "admin", "developer", "viewer", "auditor", "billing", "support" };
// Fewer visible rows than roles, so the select scrolls and shows its ↑/↓ gutter.
const role_rows: u16 = 3;

const State = struct {
    user_buf: [48]u8 = undefined,
    pass_buf: [48]u8 = undefined,
    // `buffer` is wired to the inline buffers by `wire()` once the State has its
    // final address (a self-referential struct can't do it in the initializer).
    user: ui.widgets.TextInput = .{ .buffer = &.{} },
    pass: ui.widgets.TextInput = .{ .buffer = &.{}, .mask = '*' },
    role: ui.widgets.Select = .{},
    remember: ui.widgets.Checkbox = .{},
    submit: ui.widgets.Button = .{},
    focus: Field = .user,
    submitted: bool = false,
    // Where each field last rendered — filled by `ui.probe` in `view`, read by
    // `update` to map a mouse click to a field (ADR-0019). Click-to-focus needs
    // nothing more than these rects.
    rects: [field_count]ui.Rect = [_]ui.Rect{.{ .x = 0, .y = 0, .w = 0, .h = 0 }} ** field_count,

    fn wire(self: *State) void {
        self.user.buffer = &self.user_buf;
        self.pass.buffer = &self.pass_buf;
    }

    fn rect(self: *State, f: Field) *ui.Rect {
        return &self.rects[@intFromEnum(f)];
    }
};

fn labeled(a: std.mem.Allocator, label: []const u8, field: ui.Node) !ui.Node {
    return ui.row(a, .{ .gap = 1 }, &.{
        ui.textOpts(.{ .width = .{ .len = 5 }, .wrap = .clip }, label),
        field,
    });
}

fn view(a: std.mem.Allocator, state: *State) !ui.Node {
    const status = if (state.submitted)
        try std.fmt.allocPrint(a, "✓ signed in as \"{s}\" ({s}){s}", .{
            state.user.value(),
            roles[state.role.highlighted],
            if (state.remember.checked) " · remembered" else "",
        })
    else
        "Tab/Enter next · click a field · ↑/↓ pick role · Space toggles · Esc quit";

    const form = try ui.column(a, .{
        .border = .rounded,
        .border_style = .{ .foreground = .bright_cyan },
        .padding = .symmetric(2, 1),
        .gap = 1,
        .width = .{ .len = 46 },
    }, &.{
        ui.text(.{ .bold = true }, "Sign in"),
        // Each field is wrapped in `ui.probe` so its on-screen rect lands in
        // `state.rects` — that's all click-to-focus needs.
        try ui.probe(a, state.rect(.user), try labeled(a, "User", try state.user.view(a, .{
            .focused = state.focus == .user,
            .placeholder = "username",
        }))),
        try ui.probe(a, state.rect(.pass), try labeled(a, "Pass", try state.pass.view(a, .{
            .focused = state.focus == .pass,
            .placeholder = "password",
        }))),
        try ui.probe(a, state.rect(.role), try labeled(a, "Role", try state.role.view(a, .{
            .focused = state.focus == .role,
            .options = &roles,
            .height = role_rows,
        }))),
        try ui.probe(a, state.rect(.remember), try state.remember.view(a, .{
            .focused = state.focus == .remember,
            .label = "Remember me",
        })),
        try ui.probe(a, state.rect(.submit), try state.submit.view(a, .{
            .focused = state.focus == .submit,
            .label = "Sign in",
        })),
        ui.text(.{ .dim = !state.submitted }, status),
    });

    // Center the form on the otherwise-blank alt-screen.
    return ui.center(a, form);
}

/// An editing widget consumed the key: a prior submit is now stale.
fn edited(state: *State) ui.Flow {
    state.submitted = false;
    return .keep;
}

fn update(state: *State, ev: ?ui.Event) !ui.Flow {
    const e = ev orelse return .keep;

    // Click-to-focus (ADR-0019): map a left-click to the field whose probed rect
    // contains it. Mouse coords are 1-based; the surface is 0-based.
    if (e == .mouse) {
        const m = e.mouse;
        if (m.button == .left and m.action == .press) {
            const px = m.x -| 1;
            const py = m.y -| 1;
            for (state.rects, 0..) |r, i| {
                if (px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h) {
                    state.focus = @enumFromInt(i);
                    break;
                }
            }
        }
        return .keep;
    }

    const key = switch (e) {
        .key => |k| k,
        else => return .keep,
    };

    // The focused widget gets first crack; an unconsumed key falls through to
    // navigation. Editing invalidates a prior submit; the Button *is* the submit
    // (Enter/Space on it fires), which is why it can't share the editors' arm.
    switch (state.focus) {
        .user => if (state.user.handle(key)) return edited(state),
        .pass => if (state.pass.handle(key)) return edited(state),
        .role => if (state.role.handle(key, roles.len, role_rows)) return edited(state),
        .remember => if (state.remember.handle(key)) return edited(state),
        .submit => if (state.submit.handle(key)) {
            state.submitted = true;
            return .keep;
        },
    }

    switch (key) {
        // Enter advances to the next field (it walks down to the submit button,
        // where the button consumes it and signs in). Tab does the same; the
        // button is the one place a key actually submits.
        .tab, .enter => state.focus = ui.widgets.focusNext(Field, state.focus),
        .back_tab => state.focus = ui.widgets.focusPrev(Field, state.focus),
        .escape => return .quit,
        .ctrl => |c| if (c == 'c') return .quit,
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
        try stderr.interface.writeAll("form: needs an interactive terminal\n");
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
        .mouse = true, // click-to-focus (ADR-0019)
    });
    defer app.deinit();

    var state = State{};
    state.wire();
    try app.run(io, &state, null, view, update); // no tick — a form blocks on input
}
