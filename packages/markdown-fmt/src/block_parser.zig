//! Block-level markdown parser
//! Identifies blocks: headers, code blocks, lists, blockquotes, horizontal rules, paragraphs

const std = @import("std");

/// Block types in markdown
pub const BlockType = enum {
    paragraph,
    heading,
    code_block,
    unordered_list_item,
    ordered_list_item,
    blockquote,
    horizontal_rule,
    blank_line,
};

/// A markdown block
pub const Block = struct {
    type: BlockType,
    content: []const u8,
    level: usize = 0, // For headings (1-6), list nesting (0-5), etc.
    language: []const u8 = "", // For code blocks
    ordered_number: usize = 0, // For ordered lists
};

/// Parse markdown into blocks at comptime
pub fn parseBlocks(comptime markdown: []const u8) []const Block {
    comptime {
        var blocks: []const Block = &[_]Block{};
        var i: usize = 0;

        while (i < markdown.len) {
            const line_start = i;

            // Find end of line
            var line_end = i;
            while (line_end < markdown.len and markdown[line_end] != '\n') {
                line_end += 1;
            }

            const line = markdown[line_start..line_end];

            // Skip to next line
            i = if (line_end < markdown.len) line_end + 1 else markdown.len;

            // Check for blank line
            if (isBlank(line)) {
                blocks = blocks ++ &[_]Block{.{
                    .type = .blank_line,
                    .content = "",
                }};
                continue;
            }

            // Check for horizontal rule (---, ***, ___)
            if (isHorizontalRule(line)) {
                blocks = blocks ++ &[_]Block{.{
                    .type = .horizontal_rule,
                    .content = line,
                }};
                continue;
            }

            // Check for heading (# through ######)
            if (detectHeading(line)) |heading_level| {
                const content = std.mem.trimLeft(u8, line[heading_level..], " ");
                blocks = blocks ++ &[_]Block{.{
                    .type = .heading,
                    .content = content,
                    .level = heading_level,
                }};
                continue;
            }

            // Check for code block start (```)
            if (std.mem.startsWith(u8, line, "```")) {
                const lang = std.mem.trim(u8, line[3..], " ");
                var code_content: []const u8 = "";
                var found_end = false;

                // Collect code block content
                while (i < markdown.len) {
                    const code_line_start = i;
                    var code_line_end = i;
                    while (code_line_end < markdown.len and markdown[code_line_end] != '\n') {
                        code_line_end += 1;
                    }

                    const code_line = markdown[code_line_start..code_line_end];
                    i = if (code_line_end < markdown.len) code_line_end + 1 else markdown.len;

                    // Check for closing ```
                    if (std.mem.startsWith(u8, code_line, "```")) {
                        found_end = true;
                        break;
                    }

                    // Add line to code content
                    if (code_content.len > 0) {
                        code_content = code_content ++ "\n" ++ code_line;
                    } else {
                        code_content = code_line;
                    }
                }

                blocks = blocks ++ &[_]Block{.{
                    .type = .code_block,
                    .content = code_content,
                    .language = lang,
                }};
                continue;
            }

            // Check for blockquote (> text)
            if (std.mem.startsWith(u8, line, ">")) {
                const content = std.mem.trimLeft(u8, line[1..], " ");
                blocks = blocks ++ &[_]Block{.{
                    .type = .blockquote,
                    .content = content,
                }};
                continue;
            }

            // Check for unordered list (-, *, +)
            if (line.len >= 2 and (line[0] == '-' or line[0] == '*' or line[0] == '+') and line[1] == ' ') {
                const nesting = countLeadingSpaces(line) / 2;
                const content = std.mem.trimLeft(u8, line[2..], " ");
                blocks = blocks ++ &[_]Block{.{
                    .type = .unordered_list_item,
                    .content = content,
                    .level = nesting,
                }};
                continue;
            }

            // Check for ordered list (1., 2., etc.)
            if (detectOrderedList(line)) |info| {
                const nesting = countLeadingSpaces(line) / 2;
                blocks = blocks ++ &[_]Block{.{
                    .type = .ordered_list_item,
                    .content = info.content,
                    .level = nesting,
                    .ordered_number = info.number,
                }};
                continue;
            }

            // Default: paragraph
            blocks = blocks ++ &[_]Block{.{
                .type = .paragraph,
                .content = line,
            }};
        }

        return blocks;
    }
}

/// Check if a line is blank (empty or only whitespace)
fn isBlank(comptime line: []const u8) bool {
    comptime {
        for (line) |c| {
            if (c != ' ' and c != '\t') return false;
        }
        return true;
    }
}

/// Check if a line is a horizontal rule
fn isHorizontalRule(comptime line: []const u8) bool {
    comptime {
        const trimmed = std.mem.trim(u8, line, " ");
        if (trimmed.len < 3) return false;

        const char = trimmed[0];
        if (char != '-' and char != '*' and char != '_') return false;

        for (trimmed) |c| {
            if (c != char and c != ' ') return false;
        }

        return true;
    }
}

/// Detect heading level (returns 1-6 for # through ######, null otherwise)
fn detectHeading(comptime line: []const u8) ?usize {
    comptime {
        if (line.len == 0 or line[0] != '#') return null;

        var level: usize = 0;
        for (line) |c| {
            if (c == '#') {
                level += 1;
                if (level > 6) return null;
            } else if (c == ' ') {
                break;
            } else {
                return null;
            }
        }

        return if (level > 0 and level <= 6) level else null;
    }
}

/// Count leading spaces in a line
fn countLeadingSpaces(comptime line: []const u8) usize {
    comptime {
        var count: usize = 0;
        for (line) |c| {
            if (c == ' ') {
                count += 1;
            } else {
                break;
            }
        }
        return count;
    }
}

/// Detect ordered list and extract number and content
fn detectOrderedList(comptime line: []const u8) ?struct { number: usize, content: []const u8 } {
    comptime {
        var i: usize = 0;

        // Skip leading spaces
        while (i < line.len and line[i] == ' ') {
            i += 1;
        }

        // Must have at least one digit
        if (i >= line.len or line[i] < '0' or line[i] > '9') return null;

        // Collect digits
        var number: usize = 0;
        while (i < line.len and line[i] >= '0' and line[i] <= '9') {
            number = number * 10 + (line[i] - '0');
            i += 1;
        }

        // Must have . followed by space
        if (i + 1 >= line.len or line[i] != '.' or line[i + 1] != ' ') return null;

        i += 2; // Skip '. '
        const content = line[i..];

        return .{ .number = number, .content = content };
    }
}

// Tests
test "parse empty markdown" {
    const blocks = comptime parseBlocks("");
    try std.testing.expectEqual(@as(usize, 0), blocks.len);
}

test "parse blank lines" {
    const blocks = comptime parseBlocks("   \n\n\t\n");
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqual(BlockType.blank_line, blocks[0].type);
}

test "parse heading" {
    const blocks = comptime parseBlocks("# Heading 1\n## Heading 2\n");
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqual(BlockType.heading, blocks[0].type);
    try std.testing.expectEqual(@as(usize, 1), blocks[0].level);
    try std.testing.expectEqualStrings("Heading 1", blocks[0].content);
    try std.testing.expectEqual(@as(usize, 2), blocks[1].level);
}

test "parse horizontal rule" {
    const blocks = comptime parseBlocks("---\n***\n___\n");
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqual(BlockType.horizontal_rule, blocks[0].type);
}

test "parse code block" {
    const blocks = comptime parseBlocks("```zig\nconst x = 42;\n```\n");
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(BlockType.code_block, blocks[0].type);
    try std.testing.expectEqualStrings("zig", blocks[0].language);
    try std.testing.expectEqualStrings("const x = 42;", blocks[0].content);
}

test "parse blockquote" {
    const blocks = comptime parseBlocks("> Quote text\n");
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(BlockType.blockquote, blocks[0].type);
    try std.testing.expectEqualStrings("Quote text", blocks[0].content);
}

test "parse unordered list" {
    const blocks = comptime parseBlocks("- Item 1\n- Item 2\n");
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqual(BlockType.unordered_list_item, blocks[0].type);
    try std.testing.expectEqualStrings("Item 1", blocks[0].content);
}

test "parse ordered list" {
    const blocks = comptime parseBlocks("1. First\n2. Second\n");
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqual(BlockType.ordered_list_item, blocks[0].type);
    try std.testing.expectEqual(@as(usize, 1), blocks[0].ordered_number);
    try std.testing.expectEqualStrings("First", blocks[0].content);
}

test "parse paragraph" {
    const blocks = comptime parseBlocks("This is a paragraph.\n");
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(BlockType.paragraph, blocks[0].type);
    try std.testing.expectEqualStrings("This is a paragraph.", blocks[0].content);
}

test {
    std.testing.refAllDecls(@This());
}
