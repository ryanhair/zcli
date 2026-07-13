//! Resize-aware read loop — `readEvent` multiplexing keys and window resizes.
//!
//! A terminal resize is not a keypress and never arrives in the byte stream: on
//! POSIX it's a SIGWINCH signal, on Windows a console-size change. `ResizeWatcher`
//! captures that out-of-band source and `readEvent` folds it together with stdin
//! into a single blocking call that returns an `Event` — `.key` or `.resize`.
//!
//! This is exactly the loop prompts uses to keep a prompt correctly laid out
//! while you drag the window edge. Run it, then resize your terminal: the live
//! size line updates on every `.resize` event, with no polling thread.
//!
//! Resize the window to see `.resize` events; press any key to see `.key`;
//! q or Ctrl-C quits.
//!
//! Run with: zig build run-resize   (from packages/terminal — needs a real TTY)

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
    const stdout_handle = std.Io.File.stdout().handle;

    if (!terminal.isStdinTty()) {
        try w.writeAll("resize: needs an interactive terminal (stdin is not a tty)\n");
        try w.flush();
        return;
    }

    const raw = try terminal.enableRawMode(stdin_handle);
    terminal.guard.arm(stdout_handle, "\x1b[?25h", raw);

    // The watcher installs the SIGWINCH handler on `init` and removes it on
    // `deinit`. Construct it for the lifetime of the read loop only.
    var watcher = terminal.ResizeWatcher.init();
    defer {
        watcher.deinit();
        terminal.guard.disarm();
        raw.disable();
    }

    const ws0 = terminal.getWindowSize(stdout_handle) catch terminal.Winsize{ .row = 24, .col = 80 };
    try w.print("resize demo — start size {d}x{d}\r\n", .{ ws0.col, ws0.row });
    try w.writeAll("resize the window, or press keys; q or Ctrl-C to quit\r\n");
    try w.flush();

    while (true) {
        // One blocking call for both input sources. Bytes already buffered in
        // `reader` are consumed before the watcher polls, so no key is missed.
        switch (try terminal.readEvent(reader, stdin_handle, &watcher)) {
            .resize => {
                // The event only says "it changed" — re-query for the new size.
                const ws = terminal.getWindowSize(stdout_handle) catch continue;
                try w.print("  resize -> {d}x{d}\r\n", .{ ws.col, ws.row });
            },
            .key => |k| {
                try w.print("  key    -> {f}\r\n", .{k});
                switch (k) {
                    .char => |c| if (c == 'q') break,
                    .ctrl => |c| if (c == 'c') break,
                    else => {},
                }
            },
            // Mouse/focus/paste only arrive when those DECSET modes are enabled
            // (this example never turns them on), so they can't occur here.
            else => {},
        }
        try w.flush();
    }

    try w.writeAll("bye\r\n");
    try w.flush();
}
