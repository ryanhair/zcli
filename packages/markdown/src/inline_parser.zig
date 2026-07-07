//! Inline markdown parser
//! Handles: bold, italic, dim, inline code, links, strikethrough, escape sequences
//! Preserves format specifiers like {s}, {d} for runtime interpolation

const std = @import("std");
const semantic = @import("semantic.zig");

/// Re-apply formatting after reset codes to maintain outer formatting in nested contexts
pub fn reapplyAfterResets(comptime content: []const u8, comptime format_code: []const u8, comptime ansi_reset: []const u8) []const u8 {
    comptime {
        if (ansi_reset.len == 0) return content;

        var result: []const u8 = "";
        var i: usize = 0;

        while (i < content.len) {
            // Look for ANSI_RESET
            if (i + ansi_reset.len <= content.len and std.mem.eql(u8, content[i .. i + ansi_reset.len], ansi_reset)) {
                // Found a reset - add it and then re-apply our format
                result = result ++ ansi_reset;

                // Check if there's more content after reset (don't re-apply if at end)
                if (i + ansi_reset.len < content.len) {
                    result = result ++ format_code;
                }

                i += ansi_reset.len;
            } else {
                result = result ++ &[_]u8{content[i]};
                i += 1;
            }
        }

        return result;
    }
}

/// Parse inline markdown within a block of text
/// Returns ANSI-formatted string with format specifiers preserved
pub fn parseInline(comptime markdown: []const u8, comptime palette: semantic.SemanticPalette, comptime capability: semantic.TerminalCapability) []const u8 {
    comptime {
        const bold = if (capability == .no_color) "" else "\x1b[1m";
        const italic = if (capability == .no_color) "" else "\x1b[3m";
        const dim = if (capability == .no_color) "" else "\x1b[2m";
        const strikethrough = if (capability == .no_color) "" else "\x1b[9m";
        const reset = if (capability == .no_color) "" else "\x1b[0m";

        var result: []const u8 = "";
        var i: usize = 0;

        while (i < markdown.len) {
            // Check for escape sequence
            if (markdown[i] == '\\' and i + 1 < markdown.len) {
                // Check for escaped double-char markers (** or ~~)
                if (i + 2 < markdown.len and
                    ((markdown[i + 1] == '*' and markdown[i + 2] == '*') or
                        (markdown[i + 1] == '~' and markdown[i + 2] == '~')))
                {
                    result = result ++ &[_]u8{ markdown[i + 1], markdown[i + 2] };
                    i += 3;
                    continue;
                }
                // Escape next character
                result = result ++ &[_]u8{markdown[i + 1]};
                i += 2;
                continue;
            }

            // Check for format specifiers - preserve them exactly
            if (markdown[i] == '{' and i + 2 < markdown.len and markdown[i + 2] == '}') {
                result = result ++ markdown[i .. i + 3];
                i += 3;
                continue;
            }

            // Check for inline code (`code`)
            if (markdown[i] == '`') {
                const start = i + 1;
                i = start;

                var found_close = false;
                while (i < markdown.len) {
                    if (markdown[i] == '`') {
                        const content = markdown[start..i];
                        const code_color = palette.code;
                        const code_ansi = code_color.toAnsi(capability);

                        // Escape braces in code content to prevent them being treated as format specifiers
                        var escaped_content: []const u8 = "";
                        for (content) |c| {
                            if (c == '{' or c == '}') {
                                escaped_content = escaped_content ++ &[_]u8{ c, c }; // {{ or }}
                            } else {
                                escaped_content = escaped_content ++ &[_]u8{c};
                            }
                        }

                        result = result ++ code_ansi ++ escaped_content ++ reset;
                        i += 1;
                        found_close = true;
                        break;
                    }
                    i += 1;
                }

                if (!found_close) {
                    result = result ++ "`" ++ markdown[start..];
                    break;
                }
                continue;
            }

            // Check for strikethrough (~~text~~)
            if (i + 1 < markdown.len and markdown[i] == '~' and markdown[i + 1] == '~') {
                const start = i + 2;
                i = start;

                var found_close = false;
                while (i + 1 < markdown.len) {
                    if (markdown[i] == '~' and markdown[i + 1] == '~') {
                        const content = markdown[start..i];
                        // Recursively parse content inside strikethrough for nested formatting
                        const parsed_content = parseInline(content, palette, capability);
                        const fixed_content = reapplyAfterResets(parsed_content, strikethrough, reset);
                        result = result ++ strikethrough ++ fixed_content ++ reset;
                        i += 2;
                        found_close = true;
                        break;
                    }
                    i += 1;
                }

                if (!found_close) {
                    result = result ++ "~~" ++ markdown[start..];
                    break;
                }
                continue;
            }

            // Check for links ([text](url))
            if (markdown[i] == '[') {
                if (parseLink(markdown[i..])) |link_info| {
                    // Parse markdown in link text (e.g., [**bold**](url))
                    const parsed_text = parseInline(link_info.text, palette, capability);

                    if (capability == .no_color) {
                        // No OSC 8 in no_color mode
                        result = result ++ parsed_text;
                    } else {
                        // OSC 8 hyperlink: \x1b]8;;URL\x1b\\TEXT\x1b]8;;\x1b\\
                        result = result ++ "\x1b]8;;" ++ link_info.url ++ "\x1b\\" ++ parsed_text ++ "\x1b]8;;\x1b\\";
                    }
                    i += link_info.consumed;
                    continue;
                }
            }

            // Check for bold (**text**)
            if (i + 1 < markdown.len and markdown[i] == '*' and markdown[i + 1] == '*') {
                const start = i + 2;
                i = start;

                var found_close = false;
                while (i + 1 < markdown.len) {
                    if (markdown[i] == '*' and markdown[i + 1] == '*') {
                        const content = markdown[start..i];
                        // Recursively parse content inside bold for nested formatting
                        const parsed_content = parseInline(content, palette, capability);

                        // If nested content contains resets, we need to re-apply bold after each reset
                        const fixed_content = reapplyAfterResets(parsed_content, bold, reset);

                        result = result ++ bold ++ fixed_content ++ reset;
                        i += 2;
                        found_close = true;
                        break;
                    }
                    i += 1;
                }

                if (!found_close) {
                    result = result ++ "**" ++ markdown[start..];
                    break;
                }
                continue;
            }

            // Check for italic (*text*)
            if (markdown[i] == '*') {
                const start = i + 1;
                i = start;

                var found_close = false;
                while (i < markdown.len) {
                    if (markdown[i] == '*') {
                        const content = markdown[start..i];
                        // Recursively parse content inside italic for nested formatting
                        const parsed_content = parseInline(content, palette, capability);
                        const fixed_content = reapplyAfterResets(parsed_content, italic, reset);
                        result = result ++ italic ++ fixed_content ++ reset;
                        i += 1;
                        found_close = true;
                        break;
                    }
                    i += 1;
                }

                if (!found_close) {
                    result = result ++ "*" ++ markdown[start..];
                    break;
                }
                continue;
            }

            // Check for dim (~text~) - only single tilde (not ~~)
            if (markdown[i] == '~' and (i + 1 >= markdown.len or markdown[i + 1] != '~')) {
                const start = i + 1;
                i = start;

                var found_close = false;
                while (i < markdown.len) {
                    if (markdown[i] == '~' and (i + 1 >= markdown.len or markdown[i + 1] != '~')) {
                        const content = markdown[start..i];
                        // Recursively parse content inside dim for nested formatting
                        const parsed_content = parseInline(content, palette, capability);
                        const fixed_content = reapplyAfterResets(parsed_content, dim, reset);
                        result = result ++ dim ++ fixed_content ++ reset;
                        i += 1;
                        found_close = true;
                        break;
                    }
                    i += 1;
                }

                if (!found_close) {
                    result = result ++ "~" ++ markdown[start..];
                    break;
                }
                continue;
            }

            // Regular character
            result = result ++ &[_]u8{markdown[i]};
            i += 1;
        }

        return result;
    }
}

/// Parse a markdown link [text](url)
/// Returns link info or null if not a valid link
fn parseLink(comptime markdown: []const u8) ?struct { text: []const u8, url: []const u8, consumed: usize } {
    comptime {
        if (markdown.len == 0 or markdown[0] != '[') return null;

        // Find closing ]
        var i: usize = 1;
        while (i < markdown.len and markdown[i] != ']') {
            i += 1;
        }

        if (i >= markdown.len) return null;
        const text = markdown[1..i];
        i += 1; // Skip ]

        // Check for (
        if (i >= markdown.len or markdown[i] != '(') return null;
        i += 1;

        // Find closing )
        const url_start = i;
        while (i < markdown.len and markdown[i] != ')') {
            i += 1;
        }

        if (i >= markdown.len) return null;
        const url = markdown[url_start..i];
        i += 1; // Skip )

        return .{ .text = text, .url = url, .consumed = i };
    }
}

// Tests
const ANSI_BOLD = "\x1b[1m";
const ANSI_ITALIC = "\x1b[3m";
const ANSI_DIM = "\x1b[2m";
const ANSI_STRIKETHROUGH = "\x1b[9m";
const ANSI_RESET = "\x1b[0m";

test "parse plain text" {
    const palette = semantic.SemanticPalette{};
    const result = comptime parseInline("hello world", palette, .true_color);
    try std.testing.expectEqualStrings("hello world", result);
}

test "parse bold" {
    const palette = semantic.SemanticPalette{};
    const result = comptime parseInline("**bold**", palette, .true_color);
    try std.testing.expectEqualStrings(ANSI_BOLD ++ "bold" ++ ANSI_RESET, result);
}

test "parse italic" {
    const palette = semantic.SemanticPalette{};
    const result = comptime parseInline("*italic*", palette, .true_color);
    try std.testing.expectEqualStrings(ANSI_ITALIC ++ "italic" ++ ANSI_RESET, result);
}

test "parse dim" {
    const palette = semantic.SemanticPalette{};
    const result = comptime parseInline("~dim~", palette, .true_color);
    try std.testing.expectEqualStrings(ANSI_DIM ++ "dim" ++ ANSI_RESET, result);
}

test "parse inline code" {
    const palette = semantic.SemanticPalette{};
    const result = comptime parseInline("`code`", palette, .true_color);
    const expected = comptime palette.code.toAnsi(.true_color) ++ "code" ++ ANSI_RESET;
    try std.testing.expectEqualStrings(expected, result);
}

test "parse strikethrough" {
    const palette = semantic.SemanticPalette{};
    const result = comptime parseInline("~~strike~~", palette, .true_color);
    try std.testing.expectEqualStrings(ANSI_STRIKETHROUGH ++ "strike" ++ ANSI_RESET, result);
}

test "parse link" {
    const palette = semantic.SemanticPalette{};
    const result = comptime parseInline("[text](https://example.com)", palette, .true_color);
    const expected = "\x1b]8;;https://example.com\x1b\\text\x1b]8;;\x1b\\";
    try std.testing.expectEqualStrings(expected, result);
}

test "parse escape sequences" {
    const palette = semantic.SemanticPalette{};
    const result = comptime parseInline("\\*not bold\\*", palette, .true_color);
    try std.testing.expectEqualStrings("*not bold*", result);
}

test "preserve format specifiers" {
    const palette = semantic.SemanticPalette{};
    const result = comptime parseInline("Value: **{s}**", palette, .true_color);
    const expected = "Value: " ++ ANSI_BOLD ++ "{s}" ++ ANSI_RESET;
    try std.testing.expectEqualStrings(expected, result);
}

test "mixed formatting" {
    const palette = semantic.SemanticPalette{};
    const result = comptime parseInline("**bold** and *italic* and `code`", palette, .true_color);
    // Should contain all three ANSI codes
    try std.testing.expect(std.mem.indexOf(u8, result, ANSI_BOLD) != null);
    try std.testing.expect(std.mem.indexOf(u8, result, ANSI_ITALIC) != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[38;2;") != null); // Code color
}

test "no color mode strips all ANSI" {
    const palette = semantic.SemanticPalette{};
    const result = comptime parseInline("**bold** and `code`", palette, .no_color);
    try std.testing.expectEqualStrings("bold and code", result);
}

test {
    std.testing.refAllDecls(@This());
}
