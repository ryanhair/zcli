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

    // Adaptive glyphs resolve to Unicode or an ASCII fallback based on that same
    // detection — this is what prompts/progress do (via the theme's `Glyphs`
    // tokens) so a non-UTF-8 terminal gets readable output instead of mojibake.
    // The glyph *table* now lives in the theme; here we just show the mechanism:
    // `unicode ? preferred : fallback`.
    const glyph = struct {
        fn pick(uni: bool, preferred: []const u8, fallback: []const u8) []const u8 {
            return if (uni) preferred else fallback;
        }
    }.pick;
    try w.writeAll("adaptive glyphs (resolved for this terminal):\n");
    try w.print("  cursor  {s}\n", .{glyph(unicode, "❯", ">")});
    try w.print("  success {s}\n", .{glyph(unicode, "✔", "+")});
    try w.print("  failure {s}\n", .{glyph(unicode, "✖", "x")});
    try w.print("  warning {s}\n", .{glyph(unicode, "⚠", "!")});
    try w.print("  info    {s}\n", .{glyph(unicode, "ℹ", "i")});
    try w.print("  bullet  {s}\n", .{glyph(unicode, "•", "*")});
}
