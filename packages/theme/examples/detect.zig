//! Terminal capability detection — what can *this* terminal actually show?
//!
//! Builds a `Capabilities` from the real process environment and TTY state,
//! then reports what it found. This is the detection a zcli app does for you as
//! `context.theme`; standalone users call `Capabilities.init(environ, io)`.
//!
//!     zig build run-detect                 # detected from your terminal
//!     NO_COLOR=1 zig build run-detect      # forced to no_color
//!     COLORTERM=truecolor zig build run-detect
//!     zig build run-detect | cat           # not a TTY -> color disabled
//!
//! Detection honors NO_COLOR, COLORTERM, TERM, TTY-ness, and platform signals
//! (Windows Terminal, iTerm, Apple Terminal, VS Code).

const std = @import("std");
const theme = @import("theme");
const common = @import("common.zig");

const styled = theme.styled;

pub fn main(init: std.process.Init) !void {
    var out: common.Out = .{};
    out.init(init.io);
    defer out.flush();
    const w = out.w();

    // `Capabilities.init` needs the real environment map and an Io (to probe
    // whether stdout is a TTY). `init.environ_map` is the process environment;
    // `init.io` the default Io. This is the exact call a zcli context makes.
    const caps = theme.Capabilities.init(init.environ_map, init.io);

    // Build a context so we can also *render* through the detected caps — and
    // watch this very output degrade when you pipe it or set NO_COLOR.
    const ctx = theme.ThemeContext{ .caps = caps };

    try styled("Detected terminal capabilities").header().render(w, &ctx);
    try w.writeAll("\n\n");

    try printRow(w, &ctx, "capability", caps.capabilityString());
    try printRow(w, &ctx, "is a TTY", if (caps.is_tty) "yes" else "no");
    try printRow(w, &ctx, "color enabled", if (caps.color_enabled) "yes" else "no");
    try printRow(w, &ctx, "true color", if (caps.supportsTrueColor()) "yes" else "no");
    try printRow(w, &ctx, "256 color", if (caps.supports256Color()) "yes" else "no");

    // Show the raw signals detection looked at, so the result is explainable.
    try w.writeAll("\n");
    try styled("Signals").header().render(w, &ctx);
    try w.writeAll("\n");
    try printEnv(w, &ctx, init.environ_map, "NO_COLOR");
    try printEnv(w, &ctx, init.environ_map, "COLORTERM");
    try printEnv(w, &ctx, init.environ_map, "TERM");
    try printEnv(w, &ctx, init.environ_map, "TERM_PROGRAM");

    // Finally, prove the pipeline end-to-end: this colored line appears in a
    // color terminal and comes through plain when detection disabled color.
    try w.writeAll("\n");
    try styled("This line is styled only if color is enabled above.").accent().render(w, &ctx);
    try w.writeAll("\n");
}

fn printRow(w: *std.Io.Writer, ctx: *const theme.ThemeContext, key: []const u8, val: []const u8) !void {
    try w.writeAll("  ");
    try styled(key).muted().render(w, ctx);
    try w.splatByteAll(' ', 16 - key.len);
    try styled(val).value().render(w, ctx);
    try w.writeAll("\n");
}

fn printEnv(w: *std.Io.Writer, ctx: *const theme.ThemeContext, env: *const std.process.Environ.Map, name: []const u8) !void {
    try w.writeAll("  ");
    try styled(name).flag().render(w, ctx);
    try w.splatByteAll(' ', 16 - name.len);
    if (env.get(name)) |v| {
        try styled(v).value().render(w, ctx);
    } else {
        try styled("(unset)").muted().render(w, ctx);
    }
    try w.writeAll("\n");
}
