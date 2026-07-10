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
//! Focus is caller-owned. Rather than hand-write a `Field` enum and a dispatch
//! switch, this form derives both from `State` with `ui.widgets.FocusRing`
//! (ADR-0021 incr 4): the ring is `State`'s widget fields in declaration order,
//! `Ring.next`/`prev` walk it, and `Ring.dispatch` routes a key to the focused
//! widget — the enum + `focusNext`/`focusPrev` + the `switch` all collapse into
//! the struct-derived helper.
//!
//! Run with: zig build run-form   (from packages/ui, needs a real TTY)

const std = @import("std");
const ui = @import("ui");
const terminal = @import("terminal");

pub const panic = ui.panic;

// The focus ring is derived from `State`'s widget fields (types with a `handle`
// method) in declaration order — no hand-written enum. `Focus` is the reified
// enum; its `@intFromEnum` doubles as the index into `state.rects`.
const Ring = ui.widgets.FocusRing(State);
const Focus = Ring.Focus;

// `rects` (below) parallels the ring one-to-one for click-to-focus. Its length
// can't be `Ring.ring.len` — a `State` field whose *size* depends on the ring
// (which reads `@typeInfo(State)`) is a dependency loop — so it's a plain
// literal, checked against the derived ring in `main`.
const field_count = 5;

// Descriptive roles: the longer ones wrap to two lines in the field, so the
// select runs in `wrap` mode (physical-row windowing) rather than one row each.
const roles = [_][]const u8{
    "admin (all permissions)",
    "developer (read/write code and deploy to staging environments)",
    "viewer (read-only across the workspace)",
    "auditor (read-only plus access to the full audit log)",
    "billing (manage plans, invoices, and payment methods)",
    "support (impersonate users to reproduce reported issues)",
};
// A physical-row budget (wrapped mode): enough for a few options, so the select
// scrolls and shows its ↑/↓ gutter.
const role_rows: u16 = 6;

// One theme drives the whole screen's look (ADR-0020): the border derives from
// the app theme's surface tokens, and every widget's focus highlight from its
// prompt tokens. Declare a root `zcli_theme` to reskin everything at once.

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
    // Focus is held as a ring index rather than `Focus` directly: a `State`
    // field can't be typed `FocusRing(State).Focus` (it would make
    // `@typeInfo(State)` depend on itself), so State stores the index and the
    // `focused()` accessor hands back the enum.
    focus: usize = 0,
    submitted: bool = false,
    // The focused text field reports its caret here during render (ADR-0019);
    // the post-frame hook places the real terminal cursor there.
    caret: ?ui.Point = null,
    // Where each field last rendered — filled by `ui.probe` in `view`, read by
    // `update` to map a mouse click to a field (ADR-0019). Click-to-focus needs
    // nothing more than these rects.
    rects: [field_count]ui.Rect = [_]ui.Rect{.{ .x = 0, .y = 0, .w = 0, .h = 0 }} ** field_count,

    fn wire(self: *State) void {
        self.user.buffer = &self.user_buf;
        self.pass.buffer = &self.pass_buf;
    }

    fn focused(self: *const State) Focus {
        return @enumFromInt(self.focus);
    }

    fn rect(self: *State, f: Focus) *ui.Rect {
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
        .padding = .symmetric(2, 1),
        .gap = 1,
        .width = .{ .len = 46 },
    }, &.{
        ui.text(.{ .bold = true }, "Sign in"),
        // Each field is wrapped in `ui.probe` so its on-screen rect lands in
        // `state.rects` — that's all click-to-focus needs.
        try ui.probe(a, state.rect(.user), try labeled(a, "User", try state.user.view(a, .{
            .focused = state.focused() == .user,
            .placeholder = "username",
            .cursor_out = &state.caret,
        }))),
        try ui.probe(a, state.rect(.pass), try labeled(a, "Pass", try state.pass.view(a, .{
            .focused = state.focused() == .pass,
            .placeholder = "password",
            .cursor_out = &state.caret,
        }))),
        try ui.probe(a, state.rect(.role), try labeled(a, "Role", try state.role.view(a, .{
            .focused = state.focused() == .role,
            .options = &roles,
            .height = role_rows,
            .wrap = true,
        }))),
        try ui.probe(a, state.rect(.remember), try state.remember.view(a, .{
            .focused = state.focused() == .remember,
            .label = "Remember me",
        })),
        try ui.probe(a, state.rect(.submit), try state.submit.view(a, .{
            .focused = state.focused() == .submit,
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

/// Post-frame hook: place the real terminal cursor at the focused field's caret
/// (a text field filled `state.caret` during render), or hide it when no text
/// field is focused. Reset the cache so the next frame starts blank.
fn placeCursor(app: *ui.App, state: *State) !void {
    try app.cursorAt(state.caret);
    state.caret = null;
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
                    state.focus = i;
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

    const focus = state.focused();

    // The focused widget gets first crack via the ring: `dispatch` routes `key`
    // to `state.<focused>.handle(...)` and returns *consumed*. `extras` supplies
    // the multi-arg widgets' extra args (here just the Select's count/visible).
    // An unconsumed key falls through to navigation below.
    if (Ring.dispatch(state, focus, key, .{ .role = .{ roles.len, role_rows } })) {
        // The Button *is* the submit: a consumed key on it fires sign-in
        // (ADR-0018 — `Button.handle`'s `true` means *activated*); every other
        // widget consuming a key is an edit that stales a prior submit.
        if (focus == .submit) {
            state.submitted = true;
            return .keep;
        }
        return edited(state);
    }

    switch (key) {
        // Enter advances to the next field (it walks down to the submit button,
        // where the button consumes it and signs in). Tab does the same; the
        // button is the one place a key actually submits.
        .tab, .enter => state.focus = @intFromEnum(Ring.next(focus)),
        .back_tab => state.focus = @intFromEnum(Ring.prev(focus)),
        .escape => return .quit,
        .ctrl => |c| if (c == 'c') return .quit,
        else => {},
    }
    return .keep;
}

pub fn main(init: std.process.Init) !void {
    comptime std.debug.assert(Ring.ring.len == field_count); // rects parallels the ring
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
    // `placeCursor` runs after each frame — the real terminal cursor tracks the
    // focused text field's caret (ADR-0019).
    try app.run(io, &state, null, view, update, placeCursor); // no tick — a form blocks on input
}
