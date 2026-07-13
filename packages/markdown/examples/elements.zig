//! `elements` — every block-level and inline markdown element the parser
//! understands, rendered to ANSI. This is the "what does the syntax look like"
//! reference. All parsing happens at comptime; `fmt.write` only fills in the
//! (here empty) argument tuple at runtime.
//!
//! Run:  zig build run-elements

const std = @import("std");
const md = @import("markdown");

pub fn main(init: std.process.Init) !void {
    // A buffered stdout writer. In Zig 0.16 writers are buffered, so we MUST
    // flush before exiting or output is lost — `stdout_writer.end()` at the
    // bottom does the final flush.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    // A formatter bundles a writer with a terminal capability. `.true_color`
    // asks for 24-bit RGB output; in a real CLI you'd pass the detected
    // capability (or use `context.markdown()` inside a zcli command).
    var fmt = md.formatter(out, .true_color);

    // --- Headers: `#` through `######` map to H1–H6 (colored + bold). ---------
    try out.writeAll("\n--- Headers (H1-H6) ---\n\n");
    try fmt.write(
        \\# Header 1
        \\## Header 2
        \\### Header 3
        \\#### Header 4
        \\##### Header 5
        \\###### Header 6 with **bold** and *italic* inline
        \\
    , .{});

    // --- Inline formatting: bold / italic / dim / code / strikethrough. -------
    // Markers can be combined and nested; `\` escapes a marker so it renders
    // literally.
    try out.writeAll("\n--- Inline formatting ---\n\n");
    try fmt.write(
        \\**Bold**, *italic*, ~dim~, `inline code`, and ~~strikethrough~~.
        \\
        \\Nested: **bold with *italic* inside** and `code with **bold**`.
        \\
        \\Escaped: \*literal asterisks\*, \`literal backticks\`, \~literal tilde\~.
        \\
    , .{});

    // --- Unordered lists, including nesting by indentation. -------------------
    try out.writeAll("\n--- Unordered lists (nested) ---\n\n");
    try fmt.write(
        \\- Top-level item
        \\- Item with **bold** and `code`
        \\  - Nested one level (two-space indent)
        \\  - Sibling nested item
        \\    - Nested two levels
        \\- Back to the top level
        \\
    , .{});

    // --- Ordered lists, including nested numbering. ---------------------------
    try out.writeAll("\n--- Ordered lists (nested) ---\n\n");
    try fmt.write(
        \\1. First step
        \\2. Second step with *emphasis*
        \\   1. Sub-step A
        \\   2. Sub-step B
        \\3. Third step
        \\
    , .{});

    // --- Code blocks: fenced with an optional language label, drawn in a box.
    // Braces inside code blocks are auto-escaped, so `{}` won't be treated as a
    // format specifier.
    try out.writeAll("\n--- Code blocks (with language label) ---\n\n");
    try fmt.write(
        \\```zig
        \\pub fn main() void {
        \\    std.debug.print("Hello, {s}!\n", .{"world"});
        \\}
        \\```
        \\
        \\```bash
        \\$ zig build test
        \\```
        \\
    , .{});

    // --- Blockquotes: `>` prefix, inline formatting still applies. ------------
    try out.writeAll("\n--- Blockquotes ---\n\n");
    try fmt.write(
        \\> A blockquote with **bold**, *italic*, and `code`.
        \\> It can span multiple lines.
        \\
    , .{});

    // --- Horizontal rules: `---`, `***`, or `___` become a drawn line. --------
    try out.writeAll("\n--- Horizontal rules ---\n\n");
    try fmt.write(
        \\Above the rule
        \\
        \\---
        \\
        \\Below the rule
        \\
    , .{});

    // --- Links: `[text](url)` becomes an OSC 8 hyperlink (clickable in modern
    // terminals). The link text itself can carry inline formatting.
    try out.writeAll("\n--- Links (OSC 8 hyperlinks) ---\n\n");
    try fmt.write(
        \\Plain link: [Zig homepage](https://ziglang.org).
        \\Formatted link text: [**the docs**](https://ziglang.org/documentation).
        \\
    , .{});

    // Final flush (see note at top).
    try stdout_writer.end();
}
