//! Terminal capability report — the read-only half of the terminal package.
//!
//! Queries everything you can learn about the environment *without* taking over
//! the terminal: is stdin/stdout a TTY, how big is the window, does the locale
//! advertise UTF-8, and how the adaptive `symbols.*` set resolves as a result.
//!
//! This is the only fully non-interactive example: it never enables raw mode, so
//! it runs cleanly even when piped (`zig build run-report | cat`) — where it
//! degrades gracefully, reporting "not a tty" and falling back to an 80x24 size.
//!
//! Run with: zig build run-report   (from packages/terminal)

const std = @import("std");
const terminal = @import("terminal");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;
    // Buffered writer: nothing reaches the terminal until we flush. A `defer`
    // here is enough because this example never blocks on input mid-run.
    defer w.flush() catch {};

    const stdin_tty = terminal.isStdinTty();
    const stdout_tty = terminal.isStdoutTty();

    try w.writeAll("terminal capability report\n");
    try w.writeAll("==========================\n\n");

    try w.print("stdin is a tty : {}\n", .{stdin_tty});
    try w.print("stdout is a tty: {}\n", .{stdout_tty});

    // getWindowSize needs a real console; when stdout is redirected the ioctl
    // fails, so we fall back to the conventional 80x24 the way a real renderer
    // would. Query the stdout handle — that's the surface you'd paint onto.
    const ws = terminal.getWindowSize(std.Io.File.stdout().handle) catch
        terminal.Winsize{ .row = 24, .col = 80 };
    try w.print("window size    : {d} cols x {d} rows{s}\n", .{
        ws.col,
        ws.row,
        if (stdout_tty) "" else "  (fallback — stdout is not a tty)",
    });

    // Unicode support is inferred from the locale env vars (LC_ALL/LC_CTYPE/LANG),
    // so it works even off a TTY. Pass the process environment through explicitly
    // (the runtime hands it to us as `init.environ_map`) rather than reaching for
    // a global — the package never touches getenv itself.
    const unicode = terminal.unicodeSupported(init.environ_map);
    try w.print("unicode (utf-8): {}\n\n", .{unicode});

    // The adaptive symbol set resolves to Unicode glyphs or ASCII fallbacks based
    // on that detection — this is what prompts/progress use so a non-UTF-8 terminal
    // still gets readable output instead of mojibake.
    try w.writeAll("adaptive symbols (resolved for this terminal):\n");
    try w.print("  cursor  {s}\n", .{terminal.symbols.select_cursor(unicode)});
    try w.print("  success {s}\n", .{terminal.symbols.success(unicode)});
    try w.print("  failure {s}\n", .{terminal.symbols.failure(unicode)});
    try w.print("  warning {s}\n", .{terminal.symbols.warning(unicode)});
    try w.print("  info    {s}\n", .{terminal.symbols.info(unicode)});
    try w.print("  bullet  {s}\n", .{terminal.symbols.bullet(unicode)});
}
