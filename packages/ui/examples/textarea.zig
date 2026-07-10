//! A full-screen multi-line editor built on the `TextArea` widget (ADR-0021
//! incr3): a single focused field over a caller-owned buffer. Type freely — the
//! text soft-wraps at the field width, Enter inserts a newline, the arrows move
//! by *visual* rows (across soft wraps and hard newlines alike), Home/End jump
//! to the current visual row's ends, PgUp/PgDn page by the field height, and the
//! field scrolls to keep the caret in view once the content outgrows its height.
//! The caret is the *real* terminal cursor: the field reports its cell during
//! render (`cursor_out`, ADR-0019 incr2) and the post-frame hook places the
//! hardware cursor there — the same channel `form.zig` uses for `TextInput`, so
//! the multi-line field drops into that loop with no new plumbing.
//!
//! Esc quits. The field's width and height are fixed here (`field_w`/`field_h`)
//! so the caller can pass the same numbers to `TextArea.handle`, which needs the
//! granted width/height to resolve visual-row motion against the same wrap the
//! render uses.
//!
//! Run with: zig build run-textarea   (from packages/ui, needs a real TTY)

const std = @import("std");
const ui = @import("ui");
const terminal = @import("terminal");

pub const panic = ui.panic;

// The field's fixed content geometry. `handle` needs the same width/height the
// render is granted, so pinning them keeps the two in step without threading the
// laid-out size back out of `view`.
const field_w: u16 = 44;
const field_h: u16 = 8;

const State = struct {
    // Caller-owned storage: the field never allocates. Big enough for a few
    // paragraphs; a full buffer simply drops further keystrokes.
    buf: [1024]u8 = undefined,
    area: ui.widgets.TextArea = .{ .buffer = &.{} },
    // The focused field reports its caret here during render (ADR-0019); the
    // post-frame hook places the real terminal cursor there.
    caret: ?ui.Point = null,

    fn init() State {
        var s = State{};
        s.area.buffer = &s.buf;
        // Seed a paragraph long enough to wrap and to overflow `field_h`, so the
        // scroll behaviour is visible on first paint.
        const seed = "Type here. This paragraph is long enough to soft-wrap at the field width, and pressing Enter starts a new line. Keep typing past the bottom edge and the view scrolls to follow the caret.";
        @memcpy(s.buf[0..seed.len], seed);
        s.area.len = seed.len;
        s.area.cursor = seed.len;
        return s;
    }
};

fn view(a: std.mem.Allocator, state: *State) !ui.Node {
    const editor = try state.area.view(a, .{
        .focused = true,
        .placeholder = "Start typing…",
        .width = .{ .len = field_w },
        .height = field_h,
        .cursor_out = &state.caret,
    });

    const body = try ui.column(a, .{
        .border = .rounded,
        .padding = .symmetric(2, 1),
        .gap = 1,
        .width = .{ .len = field_w + 6 },
    }, &.{
        ui.text(.{ .bold = true }, "Notes"),
        editor,
        ui.text(.{ .dim = true }, "Enter newline · ↑/↓ rows · Home/End · PgUp/PgDn · Esc quit"),
    });

    return ui.center(a, body);
}

/// Post-frame hook: place the real terminal cursor at the field's reported caret
/// (ADR-0019), then clear the cache so the next frame starts blank.
fn placeCursor(app: *ui.App, state: *State) !void {
    try app.cursorAt(state.caret);
    state.caret = null;
}

fn update(state: *State, ev: ?ui.Event) !ui.Flow {
    const e = ev orelse return .keep;
    const key = switch (e) {
        .key => |k| k,
        else => return .keep,
    };
    // The field gets first crack; it consumes every editing key (including Enter,
    // the multi-line distinction) and bubbles only Tab/Shift-Tab/Esc.
    if (state.area.handle(key, field_w, field_h)) return .keep;
    switch (key) {
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
        try stderr.interface.writeAll("textarea: needs an interactive terminal\n");
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
    });
    defer app.deinit();

    var state = State.init();
    // `placeCursor` runs after each frame — the real terminal cursor tracks the
    // field's caret (ADR-0019).
    try app.run(io, &state, null, view, update, placeCursor);
}
