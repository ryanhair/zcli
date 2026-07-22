//! Escaping helpers for the documentation generator (`tool.zig`).
//!
//! Each output format has characters that would otherwise corrupt the document
//! or, in HTML, inject markup — so every piece of command metadata is routed
//! through one of these before it is written. This lives in its own file
//! (importing only `std`) so the rules are unit-tested by `zig build test`,
//! which cannot compile `tool.zig` itself: that file needs the generated
//! `command_registry` and `tool_config` modules that only exist inside a
//! consuming project's build.

const std = @import("std");
const Writer = std.Io.Writer;

/// Write `s` as HTML text/attribute content, escaping the five characters that
/// are significant in markup. Applied to every description, name, example, and
/// title placed into the generated HTML — without it a description like
/// `Format: <json>` produces broken markup.
pub fn html(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| {
        switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&#39;"),
            else => try w.writeByte(c),
        }
    }
}

/// Write `s` for use inside a GitHub-Flavored-Markdown table cell. A literal
/// `|` closes the cell (even inside a code span), and a newline ends the row —
/// both are neutralized so a pipe-bearing or multi-line description keeps the
/// table intact.
pub fn mdCell(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| {
        switch (c) {
            '|' => try w.writeAll("\\|"),
            '\n', '\r' => try w.writeByte(' '),
            else => try w.writeByte(c),
        }
    }
}

/// Write `s` as Markdown body prose — headings and paragraphs, not table
/// cells (use `mdCell` there). A raw `<` can be parsed as an inline-HTML tag
/// that swallows the following text, and a backtick opens a code span, so those
/// are neutralized; other markdown punctuation renders harmlessly and is left
/// intact for readability.
pub fn mdText(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| {
        switch (c) {
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '`' => try w.writeAll("\\`"),
            '\\' => try w.writeAll("\\\\"),
            else => try w.writeByte(c),
        }
    }
}

/// Write `s` as roff text for a man page. Two hazards: the backslash is roff's
/// escape character, and a line beginning with `.` or `'` is parsed as a
/// control request (silently swallowing the content). Every backslash is
/// escaped and each line is prefixed with the zero-width `\&` so a leading dot
/// is treated as literal text.
pub fn roff(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeAll("\\&"); // guard the first line against a leading . or '
    for (s) |c| {
        switch (c) {
            '\\' => try w.writeAll("\\e"),
            '\n' => try w.writeAll("\n\\&"), // guard each continuation line too
            '\r' => {},
            else => try w.writeByte(c),
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "html escapes all markup-significant characters" {
    var aw = Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try html(&aw.writer, "a <b> & \"c\" 'd'");
    try std.testing.expectEqualStrings("a &lt;b&gt; &amp; &quot;c&quot; &#39;d&#39;", aw.written());
}

test "html leaves plain text untouched" {
    var aw = Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try html(&aw.writer, "priority: low, medium, high");
    try std.testing.expectEqualStrings("priority: low, medium, high", aw.written());
}

test "mdCell escapes pipes and flattens newlines" {
    var aw = Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try mdCell(&aw.writer, "json|yaml\r\nsecond");
    try std.testing.expectEqualStrings("json\\|yaml  second", aw.written());
}

test "mdText neutralizes inline-HTML and code triggers only" {
    var aw = Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try mdText(&aw.writer, "use <stdin> or `pipe` — cost*2");
    try std.testing.expectEqualStrings("use &lt;stdin&gt; or \\`pipe\\` — cost*2", aw.written());
}

test "roff guards control lines and escapes backslashes" {
    var aw = Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    // Leading dot would be a control request; embedded backslash an escape.
    try roff(&aw.writer, ".hidden path C:\\x");
    try std.testing.expectEqualStrings("\\&.hidden path C:\\ex", aw.written());
}

test "roff guards every line of a multi-line run" {
    var aw = Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try roff(&aw.writer, "first\n.second");
    try std.testing.expectEqualStrings("\\&first\n\\&.second", aw.written());
}
