// markdown-fmt: Unified API for terminal formatting
//
// ONE function handles markdown, semantic colors, and runtime interpolation:
//   try mdfmt.write(stdout, "<error>**{s}**</error> at <path>{s}</path>", .{test, file});
//
// Features:
//   - Markdown: **bold**, *italic*, ~dim~
//   - Semantic: <success>, <error>, <warning>, <info>, <command>, <path>, etc.
//   - Runtime: {s}, {d}, {d:.1}, and all std.fmt specifiers
//   - Zero runtime overhead: all parsing at comptime
//
// Example:
//   try mdfmt.write(stdout, "<success>**{d}** tests passed</success>", .{count});

const std = @import("std");

// Semantic color support
pub const semantic = @import("semantic.zig");
pub const SemanticRole = semantic.SemanticRole;
pub const SemanticPalette = semantic.SemanticPalette;
pub const parseWithSemantics = semantic.parseWithSemantics;

// Block and inline parsers
const block_parser = @import("block_parser.zig");
const inline_parser = @import("inline_parser.zig");
const renderers = @import("renderers.zig");

// ANSI escape codes
const ANSI_BOLD = "\x1b[1m";
const ANSI_ITALIC = "\x1b[3m";
const ANSI_DIM = "\x1b[2m";
const ANSI_RESET = "\x1b[0m";

/// Parse markdown and semantic tags, convert to ANSI escape codes at comptime
/// Handles: **bold**, *italic*, ~dim~, <error>, <success>, etc.
/// Preserves format specifiers like {s}, {d} for runtime interpolation
pub fn parse(comptime markdown: []const u8) []const u8 {
    return parseWithPalette(markdown, SemanticPalette{});
}

/// Parse with custom color palette
/// New implementation using block+inline parser
pub fn parseWithPalette(comptime markdown: []const u8, comptime palette: SemanticPalette) []const u8 {
    comptime {
        @setEvalBranchQuota(10000); // Increase for complex markdown documents

        // First, check if there are semantic tags - handle those with old parser
        if (containsSemanticTags(markdown)) {
            return parseWithSemanticTags(markdown, palette);
        }

        // Check if this is simple inline text (single line, no block elements)
        if (isSimpleInline(markdown)) {
            return inline_parser.parseInline(markdown, palette);
        }

        // Otherwise, use full markdown block parser
        const blocks = block_parser.parseBlocks(markdown);
        var result: []const u8 = "";
        var prev_was_blank = true; // Track blank lines for spacing normalization

        for (blocks) |block| {
            switch (block.type) {
                .blank_line => {
                    // Only add one blank line between blocks
                    if (!prev_was_blank) {
                        result = result ++ "\n";
                        prev_was_blank = true;
                    }
                },
                .heading => {
                    result = result ++ renderers.renderHeader(block.level, block.content, palette);
                    prev_was_blank = false;
                },
                .code_block => {
                    result = result ++ renderers.renderCodeBlock(block.language, block.content, palette);
                    prev_was_blank = false;
                },
                .horizontal_rule => {
                    result = result ++ renderers.renderHorizontalRule(80);
                    prev_was_blank = false;
                },
                .unordered_list_item => {
                    result = result ++ renderers.renderUnorderedListItem(block.level, block.content, palette);
                    prev_was_blank = false;
                },
                .ordered_list_item => {
                    result = result ++ renderers.renderOrderedListItem(block.level, block.ordered_number, block.content, palette);
                    prev_was_blank = false;
                },
                .blockquote => {
                    result = result ++ renderers.renderBlockquote(block.content, palette);
                    prev_was_blank = false;
                },
                .paragraph => {
                    result = result ++ renderers.renderParagraph(block.content, palette);
                    prev_was_blank = false;
                },
            }
        }

        return result;
    }
}

/// Check if markdown is simple inline text (no block elements, single line)
fn isSimpleInline(comptime markdown: []const u8) bool {
    comptime {
        // If it contains newlines or block markers, it's not simple inline
        if (std.mem.indexOf(u8, markdown, "\n") != null) return false;
        if (std.mem.startsWith(u8, markdown, "#")) return false;
        if (std.mem.startsWith(u8, markdown, "```")) return false;
        if (std.mem.startsWith(u8, markdown, ">")) return false;
        if (std.mem.startsWith(u8, markdown, "- ")) return false;
        if (std.mem.startsWith(u8, markdown, "* ")) return false;
        if (std.mem.startsWith(u8, markdown, "+ ")) return false;
        if (std.mem.startsWith(u8, markdown, "---")) return false;
        if (std.mem.startsWith(u8, markdown, "***")) return false;
        if (std.mem.startsWith(u8, markdown, "___")) return false;

        // Check for ordered list
        var i: usize = 0;
        while (i < markdown.len and markdown[i] >= '0' and markdown[i] <= '9') {
            i += 1;
        }
        if (i > 0 and i < markdown.len and markdown[i] == '.') return false;

        return true;
    }
}

/// Check if markdown contains semantic tags
fn containsSemanticTags(comptime markdown: []const u8) bool {
    comptime {
        return std.mem.indexOf(u8, markdown, "<success>") != null or
            std.mem.indexOf(u8, markdown, "<error>") != null or
            std.mem.indexOf(u8, markdown, "<warning>") != null or
            std.mem.indexOf(u8, markdown, "<info>") != null or
            std.mem.indexOf(u8, markdown, "<muted>") != null or
            std.mem.indexOf(u8, markdown, "<command>") != null or
            std.mem.indexOf(u8, markdown, "<flag>") != null or
            std.mem.indexOf(u8, markdown, "<path>") != null or
            std.mem.indexOf(u8, markdown, "<value>") != null or
            std.mem.indexOf(u8, markdown, "<code>") != null or
            std.mem.indexOf(u8, markdown, "<primary>") != null or
            std.mem.indexOf(u8, markdown, "<secondary>") != null or
            std.mem.indexOf(u8, markdown, "<accent>") != null;
    }
}

/// Parse markdown that contains semantic tags (old parser for backward compatibility)
fn parseWithSemanticTags(comptime markdown: []const u8, comptime palette: SemanticPalette) []const u8 {
    comptime {
        var result: []const u8 = "";
        var i: usize = 0;

        while (i < markdown.len) {
            // Check for semantic tags: <role>content</role>
            if (markdown[i] == '<' and i + 1 < markdown.len and markdown[i + 1] != '/') {
                const tag_start = i + 1;
                var tag_end: ?usize = null;
                var j = tag_start;
                while (j < markdown.len) {
                    if (markdown[j] == '>') {
                        tag_end = j;
                        break;
                    }
                    j += 1;
                }

                if (tag_end) |end| {
                    const tag_name = markdown[tag_start..end];
                    const role = semantic.parseSemanticRole(tag_name);

                    if (role) |r| {
                        const content_start = end + 1;
                        const closing_tag = "</" ++ tag_name ++ ">";
                        const content_end = std.mem.indexOf(u8, markdown[content_start..], closing_tag);

                        if (content_end) |ce| {
                            const content = markdown[content_start .. content_start + ce];
                            const color = palette.getColor(r);
                            const ansi_code = std.fmt.comptimePrint("\x1b[38;2;{d};{d};{d}m", .{ color.r, color.g, color.b });

                            // Parse inline markdown inside semantic tags
                            const parsed_content = inline_parser.parseInline(content, palette);
                            result = result ++ ansi_code ++ parsed_content ++ ANSI_RESET;
                            i = content_start + ce + closing_tag.len;
                            continue;
                        }
                    }
                }
            }

            // For inline text outside semantic tags, parse with inline parser
            // Extract the character and continue
            result = result ++ &[_]u8{markdown[i]};
            i += 1;
        }

        return result;
    }
}

/// Create a formatter with default color palette
pub fn formatter(writer: anytype) Formatter(@TypeOf(writer), SemanticPalette{}) {
    return .{ .writer = writer };
}

/// Create a formatter with custom color palette
pub fn formatterWithPalette(writer: anytype, comptime palette: SemanticPalette) Formatter(@TypeOf(writer), palette) {
    return .{ .writer = writer };
}

/// Formatter with writer and compile-time color palette
/// This is the recommended API - create once, use many times
pub fn Formatter(comptime Writer: type, comptime palette: SemanticPalette) type {
    return struct {
        writer: Writer,

        const Self = @This();

        /// Write formatted markdown to the writer
        pub fn write(self: Self, comptime markdown: []const u8, args: anytype) !void {
            const fmt_string = comptime parseWithPalette(markdown, palette);
            try self.writer.print(fmt_string, args);
        }

        /// Format markdown and return allocated string
        pub fn print(_: Self, allocator: std.mem.Allocator, comptime markdown: []const u8, args: anytype) ![]const u8 {
            const fmt_string = comptime parseWithPalette(markdown, palette);
            return std.fmt.allocPrint(allocator, fmt_string, args);
        }
    };
}

// Legacy API - kept for compatibility but formatter API is preferred
/// Print markdown with ANSI formatting and runtime interpolation
/// Handles both markdown (**bold**, *italic*, ~dim~) and semantic tags (<error>, <success>, etc.)
pub fn print(allocator: std.mem.Allocator, comptime markdown: []const u8, args: anytype) ![]const u8 {
    const fmt_string = comptime parse(markdown);
    return std.fmt.allocPrint(allocator, fmt_string, args);
}

/// Print with custom color palette
pub fn printWithPalette(allocator: std.mem.Allocator, comptime markdown: []const u8, comptime palette: SemanticPalette, args: anytype) ![]const u8 {
    const fmt_string = comptime parseWithPalette(markdown, palette);
    return std.fmt.allocPrint(allocator, fmt_string, args);
}

/// Write markdown with ANSI formatting to a writer
/// Handles both markdown (**bold**, *italic*, ~dim~) and semantic tags (<error>, <success>, etc.)
pub fn write(writer: anytype, comptime markdown: []const u8, args: anytype) !void {
    const fmt_string = comptime parse(markdown);
    try writer.print(fmt_string, args);
}

/// Write with custom color palette
pub fn writeWithPalette(writer: anytype, comptime markdown: []const u8, comptime palette: SemanticPalette, args: anytype) !void {
    const fmt_string = comptime parseWithPalette(markdown, palette);
    try writer.print(fmt_string, args);
}

// Tests
test "parse plain text" {
    const result = comptime parse("hello world");
    try std.testing.expectEqualStrings("hello world", result);
}

test "parse bold text" {
    const result = comptime parse("**bold**");
    try std.testing.expectEqualStrings(ANSI_BOLD ++ "bold" ++ ANSI_RESET, result);
}

test "parse italic text" {
    const result = comptime parse("*italic*");
    try std.testing.expectEqualStrings(ANSI_ITALIC ++ "italic" ++ ANSI_RESET, result);
}

test "parse dim text" {
    const result = comptime parse("~dim~");
    try std.testing.expectEqualStrings(ANSI_DIM ++ "dim" ++ ANSI_RESET, result);
}

test "parse mixed formatting" {
    const result = comptime parse("This is **bold** and *italic* text");
    const expected = "This is " ++ ANSI_BOLD ++ "bold" ++ ANSI_RESET ++
                     " and " ++ ANSI_ITALIC ++ "italic" ++ ANSI_RESET ++ " text";
    try std.testing.expectEqualStrings(expected, result);
}

test "parse preserves format specifiers" {
    const result = comptime parse("Server **{s}** returned *{d}* results");
    const expected = "Server " ++ ANSI_BOLD ++ "{s}" ++ ANSI_RESET ++
                     " returned " ++ ANSI_ITALIC ++ "{d}" ++ ANSI_RESET ++ " results";
    try std.testing.expectEqualStrings(expected, result);
}

test "print with runtime interpolation" {
    const allocator = std.testing.allocator;
    const result = try print(allocator, "Server **{s}** returned *{d}* results", .{"localhost", 42});
    defer allocator.free(result);

    const expected = "Server " ++ ANSI_BOLD ++ "localhost" ++ ANSI_RESET ++
                     " returned " ++ ANSI_ITALIC ++ "42" ++ ANSI_RESET ++ " results";
    try std.testing.expectEqualStrings(expected, result);
}

test "parse unclosed markers treated as literal" {
    const result1 = comptime parse("**unclosed");
    try std.testing.expectEqualStrings("**unclosed", result1);

    const result2 = comptime parse("*unclosed");
    try std.testing.expectEqualStrings("*unclosed", result2);
}

test "parse with semantic tags" {
    const result = comptime parse("<success>Build succeeded</success>");
    // Should contain RGB color code
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[38;2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Build succeeded") != null);
}

test "parse markdown inside semantic tags" {
    const result = comptime parse("<error>**Fatal error:**</error>");
    // Should have both semantic color AND bold
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[38;2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[1m") != null);
}

test "write with semantic tags and runtime values" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try write(writer, "<success>Processed **{d}** items</success>", .{42});

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "42") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[38;2;") != null); // Semantic color
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[1m") != null); // Bold
}

test "formatter basic usage" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const fmt = formatter(fbs.writer());
    try fmt.write("Build **{s}** in *{d}s*", .{"completed", 12});

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "12") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[1m") != null); // Bold
}

test "formatter with semantic tags" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const fmt = formatter(fbs.writer());
    try fmt.write("<success>**{d}** tests passed</success>", .{42});

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "42") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[38;2;") != null); // Semantic color
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[1m") != null); // Bold
}

test "formatter with custom palette" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const custom_palette = SemanticPalette{
        .success = .{ .r = 255, .g = 0, .b = 0 }, // Red instead of green
    };

    const fmt = formatterWithPalette(fbs.writer(), custom_palette);
    try fmt.write("<success>Custom color</success>", .{});

    const output = fbs.getWritten();
    // Should contain custom red color (255, 0, 0)
    try std.testing.expect(std.mem.indexOf(u8, output, "255;0;0") != null);
}

test "formatter print method" {
    const allocator = std.testing.allocator;
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const fmt = formatter(fbs.writer());
    const result = try fmt.print(allocator, "<error>**{s}**</error>", .{"failed"});
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[38;2;") != null);
}

// Integration tests - complex markdown scenarios
test "full markdown document with all features" {
    const markdown =
        \\# API Documentation
        \\
        \\Welcome to our **awesome** API.
        \\
        \\## Features
        \\
        \\- Fast and *reliable*
        \\- Easy to use
        \\  - Nested support
        \\  - Multiple levels
        \\
        \\## Code Example
        \\
        \\```zig
        \\const x = 42;
        \\const y = "hello";
        \\```
        \\
        \\> **Note:** This is important!
        \\
        \\---
        \\
        \\Visit [our docs](https://example.com) for more.
    ;

    const result = comptime parse(markdown);

    // Should contain all elements
    try std.testing.expect(std.mem.indexOf(u8, result, "API Documentation") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Features") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "•") != null); // List bullets
    try std.testing.expect(std.mem.indexOf(u8, result, "const x = 42;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, ">") != null); // Blockquote
    try std.testing.expect(std.mem.indexOf(u8, result, "─") != null); // Horizontal rule
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b]8;;") != null); // Link
}

test "nested markdown in lists" {
    const markdown =
        \\- Item with **bold**
        \\- Item with *italic*
        \\- Item with `code`
        \\  - Nested with **formatting**
    ;

    const result = comptime parse(markdown);

    try std.testing.expect(std.mem.indexOf(u8, result, "•") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[1m") != null); // Bold
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[3m") != null); // Italic
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[38;2;") != null); // Code color
}

test "ordered lists with formatting" {
    const markdown =
        \\1. First **important** step
        \\2. Second step with `code`
        \\3. Third step
        \\   1. Nested step
        \\   2. Another nested
    ;

    const result = comptime parse(markdown);

    try std.testing.expect(std.mem.indexOf(u8, result, "1.") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "2.") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[1m") != null); // Bold
}

test "blockquote with nested markdown" {
    const markdown =
        \\> This is a **bold** quote with *italic* text
        \\> and `inline code` too
    ;

    const result = comptime parse(markdown);

    try std.testing.expect(std.mem.indexOf(u8, result, ">") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[1m") != null); // Bold
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[3m") != null); // Italic
}

test "headers with inline formatting" {
    const markdown =
        \\# Header with **bold**
        \\## Header with *italic*
        \\### Header with `code`
    ;

    const result = comptime parse(markdown);

    try std.testing.expect(std.mem.indexOf(u8, result, "Header with") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[1m") != null); // Bold
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[3m") != null); // Italic
}

test "code block with multiple lines" {
    const markdown =
        \\```javascript
        \\function hello() {
        \\  console.log("world");
        \\  return 42;
        \\}
        \\```
    ;

    const result = comptime parse(markdown);

    try std.testing.expect(std.mem.indexOf(u8, result, "javascript") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "function hello()") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "console.log") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "┌") != null); // Top border
    try std.testing.expect(std.mem.indexOf(u8, result, "└") != null); // Bottom border
}

test "mixed inline formatting" {
    const markdown = "**bold** and *italic* and `code` and ~~strike~~ and ~dim~";

    const result = comptime parse(markdown);

    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[1m") != null); // Bold
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[3m") != null); // Italic
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[38;2;") != null); // Code
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[9m") != null); // Strike
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[2m") != null); // Dim
}

test "escape sequences in various contexts" {
    const markdown =
        \\\*not italic\*
        \\\*\*not bold\*\*
        \\\~not dim\~
        \\\`not code\`
    ;

    const result = comptime parse(markdown);

    try std.testing.expect(std.mem.indexOf(u8, result, "*not italic*") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "**not bold**") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "~not dim~") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "`not code`") != null);
}

test "links with formatting" {
    const markdown = "Visit [**our docs**](https://example.com) for more info";

    const result = comptime parse(markdown);

    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b]8;;https://example.com\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "our docs") != null);
}

test "format specifiers in all contexts" {
    const markdown =
        \\**{s}** processed
        \\*{d}* items
        \\`{s}` command
        \\~~{d}~~ deleted
    ;

    const result = comptime parse(markdown);

    try std.testing.expect(std.mem.indexOf(u8, result, "{s}") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "{d}") != null);
}

test "deeply nested lists" {
    const markdown =
        \\- Level 0
        \\  - Level 1
        \\    - Level 2
        \\      - Level 3
    ;

    const result = comptime parse(markdown);

    try std.testing.expect(std.mem.indexOf(u8, result, "•") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Level 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Level 3") != null);
}

test "semantic tags with full markdown" {
    const markdown =
        \\<success>**{d}** tests passed</success>
        \\<error>Build failed with *{d}* errors</error>
    ;

    const result = comptime parse(markdown);

    // Should have semantic colors
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[38;2;") != null);
    // Should have bold
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[1m") != null);
    // Should preserve format specifiers
    try std.testing.expect(std.mem.indexOf(u8, result, "{d}") != null);
}

test "empty code block" {
    const markdown =
        \\```
        \\```
    ;

    const result = comptime parse(markdown);

    try std.testing.expect(std.mem.indexOf(u8, result, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "└") != null);
}

test "horizontal rules of different styles" {
    const markdown =
        \\---
        \\***
        \\___
    ;

    const result = comptime parse(markdown);

    // Should contain box drawing characters for horizontal rules
    var count: usize = 0;
    var i: usize = 0;
    while (i < result.len) : (i += 1) {
        if (std.mem.startsWith(u8, result[i..], "─")) count += 1;
    }
    try std.testing.expect(count >= 3); // At least 3 horizontal rules worth of chars
}

test "runtime interpolation in complex document" {
    const allocator = std.testing.allocator;

    const markdown =
        \\# Build Report
        \\
        \\**{d}** tests passed
        \\*{d}* tests failed
        \\
        \\## Details
        \\
        \\- Success rate: **{d:.1}%**
        \\- Duration: **{d}s**
    ;

    const result = try print(allocator, markdown, .{ 42, 3, 93.3, 12 });
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "42") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "3") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "93.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "12") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "#") == null); // Headers converted
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[1m") != null); // Bold present
}

test "formatter with complex document" {
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const fmt = formatter(fbs.writer());

    const markdown =
        \\# Status: **{s}**
        \\
        \\## Metrics
        \\
        \\- Requests: **{d}**
        \\- Errors: *{d}*
        \\
        \\```bash
        \\$ command --flag value
        \\```
    ;

    try fmt.write(markdown, .{ "OK", 1000, 5 });

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "•") != null); // Lists
    try std.testing.expect(std.mem.indexOf(u8, output, "┌") != null); // Code block
}

test {
    std.testing.refAllDecls(@This());
}
