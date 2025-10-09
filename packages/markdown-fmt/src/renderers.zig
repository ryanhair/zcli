//! Renderers for block-level markdown elements

const std = @import("std");
const semantic = @import("semantic.zig");
const inline_parser = @import("inline_parser.zig");

const ANSI_BOLD = "\x1b[1m";
const ANSI_RESET = "\x1b[0m";

/// Render a header (# through ######)
pub fn renderHeader(comptime level: usize, comptime content: []const u8, comptime palette: semantic.SemanticPalette) []const u8 {
    comptime {
        if (level < 1 or level > 6) @compileError("Header level must be 1-6");

        // Parse inline markdown in header content
        const parsed_content = inline_parser.parseInline(content, palette);

        // Header color
        const header_color = palette.primary;
        const color_code = std.fmt.comptimePrint("\x1b[38;2;{d};{d};{d}m", .{ header_color.r, header_color.g, header_color.b });

        // Different styling for different header levels
        switch (level) {
            1 => {
                // H1: Bold + underline with ═
                const header_line = color_code ++ ANSI_BOLD ++ parsed_content ++ ANSI_RESET;

                // Calculate visible width (approximate - count non-ANSI characters)
                var visible_width: usize = 0;
                for (content) |c| {
                    if (c != '\x1b') visible_width += 1;
                }

                // Create underline
                var underline: []const u8 = "\n" ++ color_code;
                var i: usize = 0;
                while (i < visible_width) : (i += 1) {
                    underline = underline ++ "═";
                }
                underline = underline ++ ANSI_RESET ++ "\n";

                return "\n" ++ header_line ++ underline;
            },
            2 => {
                // H2: Bold + underline with ─
                const header_line = color_code ++ ANSI_BOLD ++ parsed_content ++ ANSI_RESET;

                var visible_width: usize = 0;
                for (content) |c| {
                    if (c != '\x1b') visible_width += 1;
                }

                var underline: []const u8 = "\n" ++ color_code;
                var i: usize = 0;
                while (i < visible_width) : (i += 1) {
                    underline = underline ++ "─";
                }
                underline = underline ++ ANSI_RESET ++ "\n";

                return "\n" ++ header_line ++ underline;
            },
            3 => {
                // H3: Bold with ▸ prefix
                return "\n" ++ color_code ++ "▸ " ++ ANSI_BOLD ++ parsed_content ++ ANSI_RESET ++ "\n";
            },
            else => {
                // H4-H6: Just bold and colored
                return "\n" ++ color_code ++ ANSI_BOLD ++ parsed_content ++ ANSI_RESET ++ "\n";
            },
        }
    }
}

/// Render a code block with border
pub fn renderCodeBlock(comptime language: []const u8, comptime content: []const u8, comptime palette: semantic.SemanticPalette) []const u8 {
    comptime {
        const code_color = palette.code;
        const color_code = std.fmt.comptimePrint("\x1b[38;2;{d};{d};{d}m", .{ code_color.r, code_color.g, code_color.b });

        // Escape braces in content to prevent them being treated as format specifiers
        var escaped_content: []const u8 = "";
        for (content) |c| {
            if (c == '{' or c == '}') {
                escaped_content = escaped_content ++ &[_]u8{c, c}; // {{ or }}
            } else {
                escaped_content = escaped_content ++ &[_]u8{c};
            }
        }

        // Split escaped content into lines
        var lines: []const []const u8 = &[_][]const u8{};
        if (escaped_content.len > 0) {
            var i: usize = 0;
            var line_start: usize = 0;

            while (i < escaped_content.len) {
                if (escaped_content[i] == '\n') {
                    const line = escaped_content[line_start..i];
                    lines = lines ++ &[_][]const u8{line};
                    line_start = i + 1;
                }
                i += 1;
            }

            // Add last line if there is remaining content
            if (line_start < escaped_content.len) {
                const line = escaped_content[line_start..];
                lines = lines ++ &[_][]const u8{line};
            }
        }

        // Calculate box width based on VISIBLE characters (escaped content)
        // Account for the fact that {{ and }} are 2 chars but represent 1 visible char
        var max_len: usize = 0;
        for (lines) |line| {
            var visible_len: usize = 0;
            var i: usize = 0;
            while (i < line.len) {
                if (i + 1 < line.len and line[i] == '{' and line[i + 1] == '{') {
                    visible_len += 1; // {{ counts as 1 visible character
                    i += 2;
                } else if (i + 1 < line.len and line[i] == '}' and line[i + 1] == '}') {
                    visible_len += 1; // }} counts as 1 visible character
                    i += 2;
                } else {
                    visible_len += 1;
                    i += 1;
                }
            }
            if (visible_len > max_len) max_len = visible_len;
        }
        const box_width = @max(max_len + 2, 20); // Minimum width 20

        // Build top border
        var result: []const u8 = "\n" ++ color_code;
        result = result ++ "┌";
        if (language.len > 0) {
            result = result ++ "─ " ++ language ++ " ";
            const remaining = box_width - language.len - 3;
            var j: usize = 0;
            while (j < remaining) : (j += 1) {
                result = result ++ "─";
            }
        } else {
            var j: usize = 0;
            while (j < box_width) : (j += 1) {
                result = result ++ "─";
            }
        }
        result = result ++ "┐" ++ ANSI_RESET ++ "\n";

        // Add content lines
        for (lines) |line| {
            result = result ++ color_code ++ "│" ++ ANSI_RESET ++ " " ++ line;

            // Calculate visible length for padding
            var visible_len: usize = 0;
            var i: usize = 0;
            while (i < line.len) {
                if (i + 1 < line.len and line[i] == '{' and line[i + 1] == '{') {
                    visible_len += 1;
                    i += 2;
                } else if (i + 1 < line.len and line[i] == '}' and line[i + 1] == '}') {
                    visible_len += 1;
                    i += 2;
                } else {
                    visible_len += 1;
                    i += 1;
                }
            }

            // Pad to box width based on visible length
            // Account for the leading space we already added
            const padding = box_width - visible_len - 1;
            var j: usize = 0;
            while (j < padding) : (j += 1) {
                result = result ++ " ";
            }
            result = result ++ color_code ++ "│" ++ ANSI_RESET ++ "\n";
        }

        // Build bottom border
        result = result ++ color_code ++ "└";
        var j: usize = 0;
        while (j < box_width) : (j += 1) {
            result = result ++ "─";
        }
        result = result ++ "┘" ++ ANSI_RESET ++ "\n";

        return result;
    }
}

/// Render a horizontal rule
pub fn renderHorizontalRule(comptime width: usize) []const u8 {
    comptime {
        const actual_width = @min(width, 80); // Cap at 80
        var result: []const u8 = "\n";
        var i: usize = 0;
        while (i < actual_width) : (i += 1) {
            result = result ++ "─";
        }
        return result ++ "\n";
    }
}

/// Render an unordered list item
pub fn renderUnorderedListItem(comptime level: usize, comptime content: []const u8, comptime palette: semantic.SemanticPalette) []const u8 {
    comptime {
        const indent_size = level * 2;
        var indent: []const u8 = "";
        var i: usize = 0;
        while (i < indent_size) : (i += 1) {
            indent = indent ++ " ";
        }

        const parsed_content = inline_parser.parseInline(content, palette);
        return indent ++ "• " ++ parsed_content ++ "\n";
    }
}

/// Render an ordered list item
pub fn renderOrderedListItem(comptime level: usize, comptime number: usize, comptime content: []const u8, comptime palette: semantic.SemanticPalette) []const u8 {
    comptime {
        const indent_size = level * 2;
        var indent: []const u8 = "";
        var i: usize = 0;
        while (i < indent_size) : (i += 1) {
            indent = indent ++ " ";
        }

        const parsed_content = inline_parser.parseInline(content, palette);
        const num_str = std.fmt.comptimePrint("{d}", .{number});
        return indent ++ num_str ++ ". " ++ parsed_content ++ "\n";
    }
}

/// Render a blockquote
pub fn renderBlockquote(comptime content: []const u8, comptime palette: semantic.SemanticPalette) []const u8 {
    comptime {
        const code_color = palette.code;
        const color_code = std.fmt.comptimePrint("\x1b[38;2;{d};{d};{d}m", .{ code_color.r, code_color.g, code_color.b });

        const parsed_content = inline_parser.parseInline(content, palette);
        return color_code ++ ">" ++ ANSI_RESET ++ " " ++ parsed_content ++ "\n";
    }
}

/// Render a paragraph
pub fn renderParagraph(comptime content: []const u8, comptime palette: semantic.SemanticPalette) []const u8 {
    comptime {
        const parsed_content = inline_parser.parseInline(content, palette);
        return parsed_content ++ "\n";
    }
}

// Tests
test "render header" {
    const palette = semantic.SemanticPalette{};
    const result = comptime renderHeader(1, "Hello", palette);
    try std.testing.expect(std.mem.indexOf(u8, result, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, ANSI_BOLD) != null);
}

test "render code block" {
    const palette = semantic.SemanticPalette{};
    const result = comptime renderCodeBlock("zig", "const x = 42;", palette);
    try std.testing.expect(std.mem.indexOf(u8, result, "zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "const x = 42;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "└") != null);
}

test "render horizontal rule" {
    const result = comptime renderHorizontalRule(80);
    try std.testing.expect(std.mem.indexOf(u8, result, "─") != null);
}

test "render unordered list item" {
    const palette = semantic.SemanticPalette{};
    const result = comptime renderUnorderedListItem(0, "Item", palette);
    try std.testing.expect(std.mem.indexOf(u8, result, "• Item") != null);
}

test "render ordered list item" {
    const palette = semantic.SemanticPalette{};
    const result = comptime renderOrderedListItem(0, 1, "First", palette);
    try std.testing.expect(std.mem.indexOf(u8, result, "1. First") != null);
}

test "render blockquote" {
    const palette = semantic.SemanticPalette{};
    const result = comptime renderBlockquote("Quote", palette);
    try std.testing.expect(std.mem.indexOf(u8, result, ">") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Quote") != null);
}

test "render paragraph" {
    const palette = semantic.SemanticPalette{};
    const result = comptime renderParagraph("Text", palette);
    try std.testing.expectEqualStrings("Text\n", result);
}

test {
    std.testing.refAllDecls(@This());
}
