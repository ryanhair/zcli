//! `interpolation` — the headline trick: markdown is parsed at *comptime*, but
//! `std.fmt` format specifiers (`{s}`, `{d}`, `{d:.2}`, `{x}`, ...) survive the
//! parse untouched and are filled in at *runtime*. So you get styled output with
//! zero runtime parsing cost AND dynamic values.
//!
//! Run:  zig build run-interpolation

const std = @import("std");
const md = @import("markdown");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var fmt = md.formatter(out, .true_color);

    // Runtime values — nothing here is known at comptime.
    const host = "db-01.internal";
    const port: u16 = 5432;
    const rows: u64 = 1_048_576;
    const latency_ms: f64 = 3.14159;
    const pct: f64 = 0.9427;

    // --- Specifiers inside inline markers ------------------------------------
    // The `{s}` sits inside `**...**`; after parsing it's still a plain `{s}`
    // wrapped in bold ANSI codes, so std.fmt interpolates it normally.
    try out.writeAll("\n--- Specifiers inside inline markers ---\n\n");
    try fmt.write(
        \\Connected to **{s}** on port *{d}*.
        \\
    , .{ host, port });

    // --- Precision / format flags are preserved verbatim. --------------------
    try out.writeAll("\n--- Precision and format flags ---\n\n");
    try fmt.write(
        \\Latency: **{d:.2}ms** (raw {d})
        \\Success rate: **{d:.1}%**
        \\Port in hex: **0x{x}**
        \\
    , .{ latency_ms, latency_ms, pct * 100.0, port });

    // --- Specifiers inside block elements (lists, headers). ------------------
    // NOTE: braces inside *inline code* and *fenced code blocks* are escaped to
    // literals (so `{d}` prints as `{d}`, not a value). Put specifiers you want
    // interpolated in regular text or emphasis, as below.
    try out.writeAll("\n--- Specifiers inside block elements ---\n\n");
    try fmt.write(
        \\# Report for **{s}**
        \\
        \\- Rows scanned: **{d}**
        \\- Port: **{d}**
        \\- Coverage: *{d:.1}%*
        \\
    , .{ host, rows, port, pct * 100.0 });

    // --- Specifiers inside semantic tags. ------------------------------------
    try out.writeAll("\n--- Specifiers inside semantic tags ---\n\n");
    try fmt.write(
        \\<success>Loaded **{d}** rows</success> from <path>{s}:{d}</path>.
        \\
    , .{ rows, host, port });

    // --- The `print` method: same parse, but returns an allocated string
    // instead of writing — handy when you need the styled bytes as a value
    // (log lines, building a larger message, etc.).
    try out.writeAll("\n--- fmt.print returns an allocated string ---\n\n");
    const line = try fmt.print(init.gpa, "<info>host=**{s}** port=**{d}**</info>\n", .{ host, port });
    defer init.gpa.free(line);
    try out.writeAll(line);

    try stdout_writer.end();
}
