//! Style showcase — the whole design system on one screen.
//!
//! Prints every semantic role in the default palette, then the fluent
//! styling API (direct colors, RGB, attributes, backgrounds). Run it in a
//! true-color terminal to see the real palette:
//!
//!     zig build run-showcase
//!
//! Pipe it and the same code renders plain text (detection kicks in):
//!
//!     zig build run-showcase | cat
//!
//! This example forces true-color so the palette always shows regardless of
//! how you run it — see `detect.zig` for real capability detection and
//! `degradation.zig` for the same content at every capability level.

const std = @import("std");
const theme = @import("theme");
const common = @import("common.zig");

const styled = theme.styled;

pub fn main(init: std.process.Init) !void {
    var out: common.Out = .{};
    out.init(init.io);
    defer out.flush();
    const w = out.w();

    // A ThemeContext pairs a Theme (here the default) with terminal
    // capabilities. Render paths consume this. We pin true_color so the demo
    // is deterministic; a real app builds caps from the environment.
    const ctx = theme.ThemeContext{
        .caps = .{ .capability = .true_color, .is_tty = true, .color_enabled = true },
    };

    try styled("theme — a CLI design system").header().render(w, &ctx);
    try w.writeAll("\n\n");

    // --- Semantic roles ------------------------------------------------------
    // Style by meaning, not by color. The active palette decides the look, so
    // this same call restyles automatically when an app overrides the palette.
    try styled("Semantic roles").header().render(w, &ctx);
    try w.writeAll("\n");

    const RoleDemo = struct { call: *const fn (theme.Styled([]const u8)) theme.Styled([]const u8), name: []const u8, sample: []const u8 };
    const roles = [_]RoleDemo{
        .{ .call = theme.Styled([]const u8).success, .name = "success", .sample = "Build passed" },
        .{ .call = theme.Styled([]const u8).err, .name = "err", .sample = "compilation failed" },
        .{ .call = theme.Styled([]const u8).warning, .name = "warning", .sample = "deprecated flag" },
        .{ .call = theme.Styled([]const u8).info, .name = "info", .sample = "3 files changed" },
        .{ .call = theme.Styled([]const u8).muted, .name = "muted", .sample = "(press q to quit)" },
        .{ .call = theme.Styled([]const u8).command, .name = "command", .sample = "git commit" },
        .{ .call = theme.Styled([]const u8).flag, .name = "flag", .sample = "--verbose" },
        .{ .call = theme.Styled([]const u8).path, .name = "path", .sample = "src/main.zig" },
        .{ .call = theme.Styled([]const u8).value, .name = "value", .sample = "42" },
        .{ .call = theme.Styled([]const u8).code, .name = "code", .sample = "std.debug.print" },
        .{ .call = theme.Styled([]const u8).header, .name = "header", .sample = "Options" },
        .{ .call = theme.Styled([]const u8).link, .name = "link", .sample = "https://ziglang.org" },
        .{ .call = theme.Styled([]const u8).accent, .name = "accent", .sample = "brand highlight" },
    };
    inline for (roles) |r| {
        // Left column: the role name, muted. Right column: the role applied.
        try styled("  .").muted().render(w, &ctx);
        try styled(r.name).muted().render(w, &ctx);
        try w.splatByteAll(' ', 12 - r.name.len);
        try r.call(styled(r.sample)).render(w, &ctx);
        try w.writeAll("\n");
    }
    try w.writeAll("\n");

    // --- Fluent styling ------------------------------------------------------
    // Direct colors and attributes, chainable in any order.
    try styled("Fluent styling").header().render(w, &ctx);
    try w.writeAll("\n");

    try w.writeAll("  ");
    try styled("red").red().render(w, &ctx);
    try w.writeAll(" ");
    try styled("green").green().render(w, &ctx);
    try w.writeAll(" ");
    try styled("blue").blue().render(w, &ctx);
    try w.writeAll(" ");
    try styled("bold").bold().render(w, &ctx);
    try w.writeAll(" ");
    try styled("italic").italic().render(w, &ctx);
    try w.writeAll(" ");
    try styled("underline").underline().render(w, &ctx);
    try w.writeAll(" ");
    try styled("dim").dim().render(w, &ctx);
    try w.writeAll(" ");
    try styled("strikethrough").strikethrough().render(w, &ctx);
    try w.writeAll("\n");

    // 24-bit RGB, an arbitrary hex, and a background+foreground pair.
    try w.writeAll("  ");
    try styled("rgb(255,105,97)").rgb(255, 105, 97).render(w, &ctx);
    try w.writeAll(" ");
    try (comptime styled("hex #40E0D0").hex("#40E0D0")).render(w, &ctx);
    try w.writeAll(" ");
    try styled(" on yellow ").onYellow().black().render(w, &ctx);
    try w.writeAll("\n\n");

    // --- Composition ---------------------------------------------------------
    // A role tags meaning; explicit fluent settings override it. Here the
    // error role keeps its bold, but the explicit underline is added on top.
    try styled("Roles + explicit settings compose (explicit wins)").header().render(w, &ctx);
    try w.writeAll("\n  ");
    try styled("critical").err().underline().render(w, &ctx);
    try w.writeAll("  (err role's bold kept, underline added)\n\n");

    // --- Any content type ----------------------------------------------------
    // styled() wraps any type, not just strings.
    try styled("Any content type").header().render(w, &ctx);
    try w.writeAll("\n  exit code ");
    try styled(@as(u32, 0)).value().render(w, &ctx);
    try w.writeAll(", retries ");
    try styled(@as(u8, 3)).warning().render(w, &ctx);
    try w.writeAll("\n");
}
