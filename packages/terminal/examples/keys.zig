//! Key-event inspector — press keys and watch them decode.
//!
//! This is the canonical raw-mode read loop the README's Quick Start sketches,
//! made real. It demonstrates the full interactive lifecycle:
//!
//!   1. `enableRawMode` — bytes now arrive one at a time, unbuffered, no echo,
//!      and Ctrl-C is delivered as a key (`.ctrl='c'`) rather than a signal.
//!   2. `guard.arm` — register a restore blob (here just "show cursor") so an
//!      external `kill -TERM` or a panic still leaves the terminal usable. The
//!      guard is the safety net that `defer raw.disable()` can't provide, because
//!      `defer` never runs on a signal or a panic.
//!   3. `readKeyOpt` in a loop — assembles UTF-8 and ANSI escape sequences into
//!      one `Key` per press. `readKeyOpt` (vs `readKey`) polls briefly so a lone
//!      Escape is distinguishable from the start of an arrow-key sequence.
//!   4. Ordered teardown — `disarm` the guard, then `disable` raw mode, on the
//!      normal exit path.
//!
//! Press keys to see their decoded `Key`; `q` or Ctrl-C quits.
//!
//! Run with: zig build run-keys   (from packages/terminal — needs a real TTY)

const std = @import("std");
const terminal = @import("terminal");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;

    var in_buf: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &in_buf);
    const reader = &stdin.interface;

    const stdin_handle = std.Io.File.stdin().handle;

    if (!terminal.isStdinTty()) {
        try w.writeAll("keys: needs an interactive terminal (stdin is not a tty)\n");
        try w.flush();
        return;
    }

    // Take over the terminal. Raw mode is restored by `raw.disable()` below; the
    // guard covers the abnormal-exit paths where that defer never fires.
    const raw = try terminal.enableRawMode(stdin_handle);
    terminal.guard.arm(std.Io.File.stdout().handle, "\x1b[?25h", raw);
    defer {
        terminal.guard.disarm();
        raw.disable();
    }

    // In raw mode the terminal does no line ending translation, so every line we
    // print must end in CRLF ("\r\n"), not a bare "\n".
    try w.writeAll("key inspector — press keys to see them decode; q or Ctrl-C to quit\r\n");
    // Buffered writer: a blocking read parks with our prompt still in the buffer,
    // so flush before every read or the screen looks frozen.
    try w.flush();

    while (true) {
        // `readKeyOpt` passes the stdin handle so a bare ESC can be told apart
        // from an escape sequence via a short readiness poll.
        const k = try terminal.readKeyOpt(reader, stdin_handle);

        // Key has a `format` method, so `{f}` renders it as e.g. `<up>`, `'a'`,
        // `<ctrl+c>` — the same spelling the parser's doc comments use.
        try w.print("  {f}\r\n", .{k});
        try w.flush();

        switch (k) {
            .char => |c| if (c == 'q') break,
            .ctrl => |c| if (c == 'c') break,
            else => {},
        }
    }

    try w.writeAll("bye\r\n");
    try w.flush();
}
