//! Inline markdown parser
//! Handles: bold, italic, dim, inline code, links, strikethrough, escape sequences
//! Preserves format specifiers like {s}, {d} for runtime interpolation

const std = @import("std");
const semantic = @import("semantic.zig");

/// Comptime string builder. Appending with `result = result ++ piece` reallocates
/// and copies the whole accumulated string per append, making a build over an
/// N-byte doc O(N²). Instead we collect the output pieces into a fixed-capacity
/// list (piece count is bounded by the input length) and concatenate them once.
fn Builder(comptime cap: usize) type {
    return struct {
        pieces: [cap][]const u8 = undefined,
        len: usize = 0,

        fn push(comptime self: *@This(), comptime piece: []const u8) void {
            self.pieces[self.len] = piece;
            self.len += 1;
        }

        fn build(comptime self: *const @This()) []const u8 {
            comptime {
                var total: usize = 0;
                for (self.pieces[0..self.len]) |p| total += p.len;

                var out: [total]u8 = undefined;
                var idx: usize = 0;
                for (self.pieces[0..self.len]) |p| {
                    @memcpy(out[idx..][0..p.len], p);
                    idx += p.len;
                }
                const final = out;
                return &final;
            }
        }
    };
}

/// Re-apply formatting after reset codes to maintain outer formatting in nested contexts
pub fn reapplyAfterResets(comptime content: []const u8, comptime format_code: []const u8, comptime ansi_reset: []const u8) []const u8 {
    comptime {
        if (ansi_reset.len == 0) return content;

        // At most two pieces (reset + format) per input byte.
        var result = Builder(content.len * 2 + 2){};
        var i: usize = 0;

        while (i < content.len) {
            // Look for ANSI_RESET
            if (i + ansi_reset.len <= content.len and std.mem.eql(u8, content[i .. i + ansi_reset.len], ansi_reset)) {
                // Found a reset - add it and then re-apply our format
                result.push(ansi_reset);

                // Check if there's more content after reset (don't re-apply if at end)
                if (i + ansi_reset.len < content.len) {
                    result.push(format_code);
                }

                i += ansi_reset.len;
            } else {
                result.push(content[i .. i + 1]);
                i += 1;
            }
        }

        return result.build();
    }
}

/// Parse inline markdown within a block of text
/// Returns ANSI-formatted string with format specifiers preserved
pub fn parseInline(comptime markdown: []const u8, comptime palette: semantic.Palette, comptime capability: semantic.TerminalCapability) []const u8 {
    comptime {
        const bold = if (capability == .no_color) "" else "\x1b[1m";
        const italic = if (capability == .no_color) "" else "\x1b[3m";
        const dim = if (capability == .no_color) "" else "\x1b[2m";
        const strikethrough = if (capability == .no_color) "" else "\x1b[9m";
        const reset = if (capability == .no_color) "" else "\x1b[0m";

        // Piece count is bounded by input length; collect pieces and join once
        // instead of reallocating the whole result per append (which was O(n²)).
        var result = Builder(markdown.len * 2 + 16){};
        var i: usize = 0;

        while (i < markdown.len) {
            // Check for escape sequence
            if (markdown[i] == '\\' and i + 1 < markdown.len) {
                // Check for escaped double-char markers (** or ~~)
                if (i + 2 < markdown.len and
                    ((markdown[i + 1] == '*' and markdown[i + 2] == '*') or
                        (markdown[i + 1] == '~' and markdown[i + 2] == '~')))
                {
                    result.push(markdown[i + 1 .. i + 3]);
                    i += 3;
                    continue;
                }
                // Escape next character
                result.push(markdown[i + 1 .. i + 2]);
                i += 2;
                continue;
            }

            // Check for format specifiers - preserve them exactly for runtime
            // interpolation. Recognized as either a single-character
            // specifier ({s}, {d}, {}...) or one carrying fill/alignment/
            // width/precision directives, which always contain a ':' (e.g.
            // {s:<16}). Anything else between literal braces (e.g.
            // "{threshold}" in prose) is ordinary text, not a specifier, and
            // falls through to be brace-escaped below.
            if (markdown[i] == '{') {
                var j = i + 1;
                var has_colon = false;
                const search_limit = @min(markdown.len, i + 1 + 32);
                while (j < search_limit and markdown[j] != '}' and markdown[j] != '{') : (j += 1) {
                    if (markdown[j] == ':') has_colon = true;
                }
                if (j < search_limit and markdown[j] == '}' and (j <= i + 2 or has_colon)) {
                    result.push(markdown[i .. j + 1]);
                    i = j + 1;
                    continue;
                }
            }

            // Check for inline code (`code`)
            if (markdown[i] == '`') {
                const start = i + 1;
                i = start;

                var found_close = false;
                while (i < markdown.len) {
                    if (markdown[i] == '`') {
                        const content = markdown[start..i];
                        const code_ansi = palette.code.sequenceComptime(capability);

                        result.push(code_ansi);
                        // Escape braces in code content to prevent them being treated as format specifiers
                        for (content, 0..) |c, ci| {
                            if (c == '{' or c == '}') {
                                result.push(&[_]u8{ c, c }); // {{ or }}
                            } else {
                                result.push(content[ci .. ci + 1]);
                            }
                        }
                        result.push(reset);

                        i += 1;
                        found_close = true;
                        break;
                    }
                    i += 1;
                }

                if (!found_close) {
                    result.push("`");
                    result.push(markdown[start..]);
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
                        result.push(strikethrough);
                        result.push(fixed_content);
                        result.push(reset);
                        i += 2;
                        found_close = true;
                        break;
                    }
                    i += 1;
                }

                if (!found_close) {
                    result.push("~~");
                    result.push(markdown[start..]);
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
                        result.push(parsed_text);
                    } else {
                        // OSC 8 hyperlink: \x1b]8;;URL\x1b\\TEXT\x1b]8;;\x1b\\
                        result.push("\x1b]8;;");
                        result.push(link_info.url);
                        result.push("\x1b\\");
                        result.push(parsed_text);
                        result.push("\x1b]8;;\x1b\\");
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

                        result.push(bold);
                        result.push(fixed_content);
                        result.push(reset);
                        i += 2;
                        found_close = true;
                        break;
                    }
                    i += 1;
                }

                if (!found_close) {
                    result.push("**");
                    result.push(markdown[start..]);
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
                        result.push(italic);
                        result.push(fixed_content);
                        result.push(reset);
                        i += 1;
                        found_close = true;
                        break;
                    }
                    i += 1;
                }

                if (!found_close) {
                    result.push("*");
                    result.push(markdown[start..]);
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
                        result.push(dim);
                        result.push(fixed_content);
                        result.push(reset);
                        i += 1;
                        found_close = true;
                        break;
                    }
                    i += 1;
                }

                if (!found_close) {
                    result.push("~");
                    result.push(markdown[start..]);
                    break;
                }
                continue;
            }

            // Regular character. Literal braces that aren't a recognized
            // format specifier (handled above) must be escaped, since the
            // final rendered string is used as a std.fmt format string by
            // callers of `Formatter.print` (see main.zig).
            if (markdown[i] == '{' or markdown[i] == '}') {
                result.push(&[_]u8{ markdown[i], markdown[i] });
            } else {
                result.push(markdown[i .. i + 1]);
            }
            i += 1;
        }

        return result.build();
    }
}

/// Display width of already-parsed, ANSI-free plain text (e.g. the output of
/// `parseInline(content, palette, .no_color)`). UTF-8 codepoint aware, and
/// treats common East Asian wide ranges as occupying two terminal columns so
/// headings underline to the correct visible width instead of the raw byte
/// count.
pub fn visibleWidth(comptime text: []const u8) usize {
    comptime {
        var width: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            const len = @min(seq_len, text.len - i);
            const codepoint: u21 = if (len > 1)
                std.unicode.utf8Decode(text[i .. i + len]) catch 0
            else
                text[i];
            width += if (isWideCodepoint(codepoint)) 2 else 1;
            i += len;
        }
        return width;
    }
}

/// Best-effort East Asian Wide/Fullwidth check (not a full Unicode Annex #11
/// table, but covers the common CJK/Hangul/fullwidth ranges).
fn isWideCodepoint(cp: u21) bool {
    return switch (cp) {
        0x1100...0x115F, // Hangul Jamo
        0x2E80...0x303E, // CJK Radicals Supplement .. CJK Symbols/Punctuation
        0x3041...0x33FF, // Hiragana .. CJK Compatibility
        0x3400...0x4DBF, // CJK Unified Ideographs Extension A
        0x4E00...0x9FFF, // CJK Unified Ideographs
        0xA000...0xA4CF, // Yi Syllables/Radicals
        0xAC00...0xD7A3, // Hangul Syllables
        0xF900...0xFAFF, // CJK Compatibility Ideographs
        0xFF00...0xFF60, // Fullwidth Forms
        0xFFE0...0xFFE6, // Fullwidth Signs
        0x20000...0x2FFFD, // CJK Unified Ideographs Extension B+ / Compat Supplement
        0x30000...0x3FFFD, // CJK Unified Ideographs Extension G+
        => true,
        else => false,
    };
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
    const palette = semantic.Palette{};
    const result = comptime parseInline("hello world", palette, .true_color);
    try std.testing.expectEqualStrings("hello world", result);
}

test "parse bold" {
    const palette = semantic.Palette{};
    const result = comptime parseInline("**bold**", palette, .true_color);
    try std.testing.expectEqualStrings(ANSI_BOLD ++ "bold" ++ ANSI_RESET, result);
}

test "parse italic" {
    const palette = semantic.Palette{};
    const result = comptime parseInline("*italic*", palette, .true_color);
    try std.testing.expectEqualStrings(ANSI_ITALIC ++ "italic" ++ ANSI_RESET, result);
}

test "parse dim" {
    const palette = semantic.Palette{};
    const result = comptime parseInline("~dim~", palette, .true_color);
    try std.testing.expectEqualStrings(ANSI_DIM ++ "dim" ++ ANSI_RESET, result);
}

test "parse inline code" {
    const palette = semantic.Palette{};
    const result = comptime parseInline("`code`", palette, .true_color);
    const expected = comptime palette.code.sequenceComptime(.true_color) ++ "code" ++ ANSI_RESET;
    try std.testing.expectEqualStrings(expected, result);
}

test "parse strikethrough" {
    const palette = semantic.Palette{};
    const result = comptime parseInline("~~strike~~", palette, .true_color);
    try std.testing.expectEqualStrings(ANSI_STRIKETHROUGH ++ "strike" ++ ANSI_RESET, result);
}

test "parse link" {
    const palette = semantic.Palette{};
    const result = comptime parseInline("[text](https://example.com)", palette, .true_color);
    const expected = "\x1b]8;;https://example.com\x1b\\text\x1b]8;;\x1b\\";
    try std.testing.expectEqualStrings(expected, result);
}

test "parse escape sequences" {
    const palette = semantic.Palette{};
    const result = comptime parseInline("\\*not bold\\*", palette, .true_color);
    try std.testing.expectEqualStrings("*not bold*", result);
}

test "preserve format specifiers" {
    const palette = semantic.Palette{};
    const result = comptime parseInline("Value: **{s}**", palette, .true_color);
    const expected = "Value: " ++ ANSI_BOLD ++ "{s}" ++ ANSI_RESET;
    try std.testing.expectEqualStrings(expected, result);
}

test "mixed formatting" {
    const palette = semantic.Palette{};
    const result = comptime parseInline("**bold** and *italic* and `code`", palette, .true_color);
    // Should contain all three ANSI codes
    try std.testing.expect(std.mem.indexOf(u8, result, ANSI_BOLD) != null);
    try std.testing.expect(std.mem.indexOf(u8, result, ANSI_ITALIC) != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "38;2;") != null); // Code color
}

test "no color mode strips all ANSI" {
    const palette = semantic.Palette{};
    const result = comptime parseInline("**bold** and `code`", palette, .no_color);
    try std.testing.expectEqualStrings("bold and code", result);
}

test "literal braces in prose are escaped" {
    // Regression: `{threshold}` isn't a recognized single-char format
    // specifier like `{s}`/`{d}`, so it must be escaped to `{{threshold}}`
    // rather than passed through raw - otherwise the final rendered string
    // (used as a std.fmt format string by callers) fails to compile/parse.
    const palette = semantic.Palette{};
    const result = comptime parseInline("Set {threshold} high", palette, .no_color);
    try std.testing.expectEqualStrings("Set {{threshold}} high", result);

    // Actual format specifiers must still be preserved for interpolation.
    const with_spec = comptime parseInline("Value: {s}", palette, .no_color);
    try std.testing.expectEqualStrings("Value: {s}", with_spec);

    // The escaped output must itself be a valid format string (with no args).
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writer.print(result, .{});
    try std.testing.expectEqualStrings("Set {threshold} high", writer.buffered());
}

test "visibleWidth counts ASCII as one column each" {
    try std.testing.expectEqual(@as(usize, 11), comptime visibleWidth("Hello World"));
}

test "visibleWidth treats CJK codepoints as double width" {
    // "日本語" is 3 codepoints (9 UTF-8 bytes), each rendering 2 columns wide.
    try std.testing.expectEqual(@as(usize, 6), comptime visibleWidth("日本語"));
}

test {
    std.testing.refAllDecls(@This());
}
