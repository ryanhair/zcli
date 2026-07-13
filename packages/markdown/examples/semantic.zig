//! `semantic` — the 13 built-in semantic roles. Instead of hard-coding a color,
//! you tag text by *meaning* (`<error>`, `<path>`, ...) and the active palette
//! decides how it looks. This keeps a CLI's coloring consistent and themeable.
//!
//! Semantic tags are inline-only: they compose with inline markdown
//! (**bold**, *italic*, `code`) and with runtime format specifiers, but not with
//! block elements like headers or lists.
//!
//! Run:  zig build run-semantic

const std = @import("std");
const md = @import("markdown");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var fmt = md.formatter(out, .true_color);

    // --- Core status roles: the five most common CLI outcomes. ---------------
    try out.writeAll("\n--- Core roles ---\n\n");
    try fmt.write(
        \\<success>Build succeeded</success>
        \\<error>Build failed</error>
        \\<warning>3 deprecation warnings</warning>
        \\<info>Using cache at ~/.cache</info>
        \\<muted>(this line is de-emphasized)</muted>
        \\
    , .{});

    // --- CLI element roles: for rendering commands, flags, paths, etc. --------
    try out.writeAll("\n--- CLI element roles ---\n\n");
    try fmt.write(
        \\Run <command>zig build test</command> to run the suite.
        \\Pass the <flag>--verbose</flag> flag for details.
        \\Config lives at <path>~/.config/app/config.toml</path>.
        \\The current value is <value>enabled</value>.
        \\Inline snippet: <code>const x = 42;</code>.
        \\
    , .{});

    // --- Structure roles: header, link, accent. ------------------------------
    try out.writeAll("\n--- Structure roles ---\n\n");
    try fmt.write(
        \\<header>SECTION TITLE</header>
        \\See the <link>documentation</link> for more.
        \\<accent>Highlighted brand text</accent>
        \\
    , .{});

    // --- Composing tags with inline markdown AND runtime values. -------------
    // The role color is re-applied after each inline reset, so **bold** inside
    // <error> stays the error color and bold at once. `{s}`/`{d}` are preserved
    // through the comptime parse and filled in here at runtime.
    try out.writeAll("\n--- Composing roles with markdown + runtime values ---\n\n");
    const filename = "config.toml";
    const line: u32 = 42;
    const count: u32 = 128;
    try fmt.write(
        \\<error>**Fatal:**</error> could not parse <path>{s}</path> at line ~{d}~.
        \\<success>Processed **{d}** records</success> with *no* errors.
        \\
    , .{ filename, line, count });

    try stdout_writer.end();
}
