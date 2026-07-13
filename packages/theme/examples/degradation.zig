//! Capability degradation — one palette, four terminals.
//!
//! Renders the same styled content four times, once per terminal capability,
//! by pinning the `ThemeContext` capability. This is the heart of the design
//! system: write styling once, and it degrades true color -> 256 -> 16 -> plain
//! automatically. No `if (supportsColor)` branches in your code.
//!
//!     zig build run-degradation
//!
//! In a true-color terminal you can see each block get coarser: the RGB brand
//! color snaps to the nearest 256-palette index, then to the nearest of the 16
//! ANSI colors, then vanishes entirely (plain text) at no_color.

const std = @import("std");
const theme = @import("theme");
const common = @import("common.zig");

const styled = theme.styled;

pub fn main(init: std.process.Init) !void {
    var out: common.Out = .{};
    out.init(init.io);
    defer out.flush();
    const w = out.w();

    const levels = [_]struct { cap: theme.TerminalCapability, label: []const u8 }{
        .{ .cap = .true_color, .label = "true_color  (24-bit RGB, exact)" },
        .{ .cap = .ansi_256, .label = "ansi_256    (nearest of 256)" },
        .{ .cap = .ansi_16, .label = "ansi_16     (nearest of 16)" },
        .{ .cap = .no_color, .label = "no_color    (plain text)" },
    };

    try styled("The same output at every terminal capability").header().render(w, &(pinned(.true_color)));
    try w.writeAll("\n\n");

    for (levels) |level| {
        // A ThemeContext with a pinned capability. `color_enabled` is off only
        // for no_color, which is exactly what real detection produces too.
        const ctx = pinned(level.cap);

        // Header line for this capability, drawn with a color so you can see
        // the header itself degrade alongside the sample content.
        try styled("── ").accent().render(w, &ctx);
        try styled(level.label).header().render(w, &ctx);
        try w.writeAll("\n  ");

        // A representative slice of the palette + a raw RGB brand color.
        try styled("success").success().render(w, &ctx);
        try w.writeAll("  ");
        try styled("error").err().render(w, &ctx);
        try w.writeAll("  ");
        try styled("command").command().render(w, &ctx);
        try w.writeAll("  ");
        try styled("path").path().render(w, &ctx);
        try w.writeAll("  ");
        try styled("rgb(255,105,97)").rgb(255, 105, 97).render(w, &ctx);
        try w.writeAll("\n\n");
    }

    try styled("Note").warning().render(w, &(pinned(.true_color)));
    try w.writeAll(" your terminal only shows each block accurately if it\n");
    try w.writeAll("actually supports that level — the escape codes are correct regardless.\n");
}

/// A ThemeContext (default theme) with an explicitly pinned capability.
fn pinned(cap: theme.TerminalCapability) theme.ThemeContext {
    return .{
        .caps = .{
            .capability = cap,
            .is_tty = true,
            .color_enabled = cap != .no_color,
        },
    };
}
