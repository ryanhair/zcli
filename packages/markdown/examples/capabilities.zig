//! `capabilities` — the same markdown rendered for each of the four terminal
//! capability levels. The formatter pre-compiles ALL four variants of every
//! format string at comptime and picks one at runtime based on the capability
//! you pass, so downgrading to a dumber terminal (or honoring `NO_COLOR`) still
//! costs nothing at run time.
//!
//!   .no_color   → plain text, zero ANSI escapes (also what NO_COLOR selects)
//!   .ansi_16    → the classic 8/16-color SGR codes
//!   .ansi_256   → the 256-color palette (38;5;N)
//!   .true_color → 24-bit RGB (38;2;R;G;B)
//!
//! Run:  zig build run-capabilities
//! Tip:  pipe through `cat -v` to SEE the raw escape codes, e.g.
//!       `zig build run-capabilities | cat -v`

const std = @import("std");
const md = @import("markdown");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    // The one source string we'll render four different ways. It mixes a
    // semantic role, inline markdown, and a runtime specifier.
    const source =
        \\<success>Build **passed**</success> in *{d:.1}s* — see `zig-out/`.
        \\
    ;
    const seconds: f64 = 4.2;

    const levels = [_]struct { name: []const u8, cap: md.TerminalCapability }{
        .{ .name = "no_color", .cap = .no_color },
        .{ .name = "ansi_16", .cap = .ansi_16 },
        .{ .name = "ansi_256", .cap = .ansi_256 },
        .{ .name = "true_color", .cap = .true_color },
    };

    // Because `write` switches on `self.capability` at runtime, one formatter
    // could handle all four — but we make four to label each clearly.
    inline for (levels) |lvl| {
        try out.print("\n--- {s} ---\n", .{lvl.name});
        var fmt = md.formatter(out, lvl.cap);
        try fmt.write(source, .{seconds});
    }

    // To actually see the difference in escape codes without a hex viewer, dump
    // the true_color vs no_color bytes side by side using the allocating
    // `print` method.
    try out.writeAll("\n--- raw bytes (no_color vs true_color) ---\n\n");
    var nc = md.formatter(out, .no_color);
    var tc = md.formatter(out, .true_color);
    const nc_bytes = try nc.print(init.gpa, "<success>ok</success>", .{});
    defer init.gpa.free(nc_bytes);
    const tc_bytes = try tc.print(init.gpa, "<success>ok</success>", .{});
    defer init.gpa.free(tc_bytes);
    // `{f}` runs the value through std.fmt's escaping via the slice; we use
    // `{any}` on the bytes to reveal the escape sequences literally.
    try out.print("no_color  : {any}\n", .{nc_bytes});
    try out.print("true_color: {any}\n", .{tc_bytes});

    try stdout_writer.end();
}
