//! `palette` — customizing colors, plus the lower-level APIs.
//!
//! Semantic roles resolve through a `Palette`: a struct mapping each of the 13
//! roles to a `Style` (foreground/background color + bold/italic/dim/...). The
//! default palette is `md.Palette{}`; override any field to rebrand. The palette
//! is a *comptime* parameter, so role colors bake straight into the format
//! string — no runtime lookups.
//!
//! This example also shows the three lower-level entry points beneath the
//! formatter: `md.parse`, `md.writeWithPalette`, and `md.print`.
//!
//! Run:  zig build run-palette

const std = @import("std");
const md = @import("markdown");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    // --- Default palette for comparison. -------------------------------------
    try out.writeAll("\n--- Default palette ---\n\n");
    var def = md.formatter(out, .true_color);
    try def.write(
        \\<success>success</success> <error>error</error> <warning>warning</warning> <info>info</info>
        \\<command>command</command> <flag>--flag</flag> <path>/path</path> <accent>accent</accent>
        \\
    , .{});

    // --- A custom palette. Only overridden fields change; the rest keep their
    // defaults. Styles carry a color plus attributes; here we recolor a few
    // roles with 24-bit RGB and toggle attributes.
    const custom = md.Palette{
        .success = .{ .foreground = .{ .rgb = .{ .r = 0, .g = 200, .b = 120 } }, .bold = true },
        .err = .{ .foreground = .{ .rgb = .{ .r = 240, .g = 40, .b = 40 } }, .bold = true },
        .accent = .{ .foreground = .{ .rgb = .{ .r = 255, .g = 140, .b = 0 } }, .italic = true },
        .code = .{ .foreground = .{ .rgb = .{ .r = 180, .g = 180, .b = 255 } } },
    };

    try out.writeAll("\n--- Custom palette (recolored roles) ---\n\n");
    // `formatterWithPalette` binds the custom palette into a reusable formatter.
    var custom_fmt = md.formatterWithPalette(out, .true_color, custom);
    try custom_fmt.write(
        \\<success>success</success> <error>error</error> <accent>accent</accent> <code>code</code>
        \\
    , .{});

    // === Lower-level APIs ====================================================

    // 1) `md.parse(comptime markdown)` — pure comptime parse to an ANSI string
    //    (default palette, true_color). No writer, no allocator; use it when you
    //    want the styled bytes as a compile-time constant, e.g. a static banner.
    try out.writeAll("\n--- md.parse (comptime -> const string) ---\n\n");
    const banner = comptime md.parse("**Ready.** Type `help` for commands.");
    try out.writeAll(banner);
    try out.writeAll("\n");

    // 2) `md.writeWithPalette(writer, markdown, palette, args)` — one-shot write
    //    with a custom palette, no formatter needed. Good for a single call.
    try out.writeAll("\n--- md.writeWithPalette (one-shot, custom palette) ---\n\n");
    try md.writeWithPalette(out, "<accent>Themed one-shot line</accent>\n", custom, .{});

    // 3) `md.print(allocator, markdown, args)` — allocate and return the styled
    //    string (default palette). Caller frees.
    try out.writeAll("\n--- md.print (allocated string) ---\n\n");
    const msg = try md.print(init.gpa, "<info>**{d}** items queued</info>\n", .{7});
    defer init.gpa.free(msg);
    try out.writeAll(msg);

    try stdout_writer.end();
}
