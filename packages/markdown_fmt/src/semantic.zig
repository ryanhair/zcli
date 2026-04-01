//! Semantic color support for markdown_fmt
//!
//! Types are imported from ztheme (the canonical source for semantic colors).
//! This module provides markdown-specific parsing and multi-version compilation.

const std = @import("std");
const ztheme = @import("ztheme");

// Re-export canonical types from ztheme
pub const TerminalCapability = ztheme.TerminalCapability;
pub const SemanticRole = ztheme.SemanticRole;
pub const RGB = ztheme.RGB;
pub const SemanticPalette = ztheme.SemanticPalette;

/// Parse markdown with semantic color support for a specific terminal capability
/// Supports: <error>text</error>, <success>text</success>, etc.
/// Also parses markdown inside semantic tags (e.g., <error>**bold**</error>)
pub fn parseWithSemantics(comptime markdown: []const u8, comptime palette: SemanticPalette, comptime capability: TerminalCapability) []const u8 {
    comptime {
        const ANSI_RESET = if (capability == .no_color) "" else "\x1b[0m";
        var result: []const u8 = "";
        var i: usize = 0;

        while (i < markdown.len) {
            // Check for semantic tags: <role>text</role>
            if (markdown[i] == '<' and i + 1 < markdown.len and markdown[i + 1] != '/') {
                // Find closing >
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
                    const role = parseSemanticRole(tag_name);

                    if (role) |r| {
                        // Find closing tag
                        const content_start = end + 1;
                        const closing_tag = "</" ++ tag_name ++ ">";
                        const content_end = std.mem.indexOf(u8, markdown[content_start..], closing_tag);

                        if (content_end) |ce| {
                            const content = markdown[content_start .. content_start + ce];
                            const color = palette.getColor(r);
                            const ansi_code = color.toAnsi(capability);

                            // Parse markdown inside the semantic tag, then
                            // re-apply semantic color after any inline resets
                            const raw_parsed = parseMarkdownOnly(content, capability);
                            const parsed_content = reapplyAfterResets(raw_parsed, ansi_code, ANSI_RESET);
                            result = result ++ ansi_code ++ parsed_content ++ ANSI_RESET;
                            i = content_start + ce + closing_tag.len;
                            continue;
                        }
                    }
                }
            }

            // Regular character
            result = result ++ &[_]u8{markdown[i]};
            i += 1;
        }

        return result;
    }
}

/// Re-apply formatting after reset codes to maintain outer formatting in nested contexts
fn reapplyAfterResets(comptime content: []const u8, comptime format_code: []const u8, comptime ansi_reset: []const u8) []const u8 {
    comptime {
        if (ansi_reset.len == 0) return content;

        var result: []const u8 = "";
        var i: usize = 0;

        while (i < content.len) {
            if (i + ansi_reset.len <= content.len and std.mem.eql(u8, content[i .. i + ansi_reset.len], ansi_reset)) {
                result = result ++ ansi_reset;
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

/// Parse only markdown (bold, italic, dim) without semantic tags
/// This is used for parsing markdown inside semantic tags
fn parseMarkdownOnly(comptime markdown: []const u8, comptime capability: TerminalCapability) []const u8 {
    comptime {
        const ANSI_BOLD = if (capability == .no_color) "" else "\x1b[1m";
        const ANSI_ITALIC = if (capability == .no_color) "" else "\x1b[3m";
        const ANSI_DIM = if (capability == .no_color) "" else "\x1b[2m";
        const ANSI_RESET = if (capability == .no_color) "" else "\x1b[0m";

        var result: []const u8 = "";
        var i: usize = 0;

        while (i < markdown.len) {
            // Check for format specifiers - preserve them exactly
            if (markdown[i] == '{' and i + 2 < markdown.len and markdown[i + 2] == '}') {
                result = result ++ markdown[i .. i + 3];
                i += 3;
                continue;
            }

            // Check for bold (**text**)
            if (i + 1 < markdown.len and markdown[i] == '*' and markdown[i + 1] == '*') {
                const start = i + 2;
                i = start;

                var found_close = false;
                while (i + 1 < markdown.len) {
                    if (markdown[i] == '*' and markdown[i + 1] == '*') {
                        const content = markdown[start..i];
                        result = result ++ ANSI_BOLD ++ content ++ ANSI_RESET;
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
                        result = result ++ ANSI_ITALIC ++ content ++ ANSI_RESET;
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

            // Check for dim (~text~)
            if (markdown[i] == '~') {
                const start = i + 1;
                i = start;

                var found_close = false;
                while (i < markdown.len) {
                    if (markdown[i] == '~') {
                        const content = markdown[start..i];
                        result = result ++ ANSI_DIM ++ content ++ ANSI_RESET;
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

/// Multi-version compiled help text
/// Contains 4 versions of the same markdown, compiled for different terminal capabilities
pub const ComptimeHelp = struct {
    no_color: []const u8,
    ansi_16: []const u8,
    ansi_256: []const u8,
    true_color: []const u8,

    /// Select the appropriate version based on terminal capability
    pub fn select(self: @This(), capability: TerminalCapability) []const u8 {
        return switch (capability) {
            .no_color => self.no_color,
            .ansi_16 => self.ansi_16,
            .ansi_256 => self.ansi_256,
            .true_color => self.true_color,
        };
    }
};

/// Parse markdown and generate all 4 terminal capability versions at comptime
/// This is the main entry point for generating help text with semantic colors
pub fn parse(comptime markdown: []const u8, comptime palette: SemanticPalette) ComptimeHelp {
    return .{
        .no_color = parseWithSemantics(markdown, palette, .no_color),
        .ansi_16 = parseWithSemantics(markdown, palette, .ansi_16),
        .ansi_256 = parseWithSemantics(markdown, palette, .ansi_256),
        .true_color = parseWithSemantics(markdown, palette, .true_color),
    };
}

pub fn parseSemanticRole(comptime tag: []const u8) ?SemanticRole {
    return if (std.mem.eql(u8, tag, "success"))
        .success
    else if (std.mem.eql(u8, tag, "error"))
        .err
    else if (std.mem.eql(u8, tag, "warning"))
        .warning
    else if (std.mem.eql(u8, tag, "info"))
        .info
    else if (std.mem.eql(u8, tag, "muted"))
        .muted
    else if (std.mem.eql(u8, tag, "command"))
        .command
    else if (std.mem.eql(u8, tag, "flag"))
        .flag
    else if (std.mem.eql(u8, tag, "path"))
        .path
    else if (std.mem.eql(u8, tag, "value"))
        .value
    else if (std.mem.eql(u8, tag, "code"))
        .code
    else if (std.mem.eql(u8, tag, "header"))
        .header
    else if (std.mem.eql(u8, tag, "link"))
        .link
    else if (std.mem.eql(u8, tag, "primary"))
        .primary
    else if (std.mem.eql(u8, tag, "secondary"))
        .secondary
    else if (std.mem.eql(u8, tag, "accent"))
        .accent
    else
        null;
}

// Tests
test "semantic role parsing" {
    const role = parseSemanticRole("success");
    try std.testing.expect(role == .success);

    const error_role = parseSemanticRole("error");
    try std.testing.expect(error_role == .err);

    const header_role = parseSemanticRole("header");
    try std.testing.expect(header_role == .header);

    const link_role = parseSemanticRole("link");
    try std.testing.expect(link_role == .link);

    const invalid = parseSemanticRole("invalid");
    try std.testing.expect(invalid == null);
}

test "parse with semantics - true color" {
    const palette = SemanticPalette{};
    const result = comptime parseWithSemantics("<success>passed</success>", palette, .true_color);

    // Should contain RGB color code and text
    try std.testing.expect(std.mem.indexOf(u8, result, "passed") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[38;2;") != null);
}

test "parse with semantics - no color" {
    const palette = SemanticPalette{};
    const result = comptime parseWithSemantics("<success>passed</success>", palette, .no_color);

    // Should contain only plain text, no ANSI codes
    try std.testing.expectEqualStrings("passed", result);
}

test "parse with semantics - 16 color" {
    const palette = SemanticPalette{};
    const result = comptime parseWithSemantics("<success>passed</success>", palette, .ansi_16);

    // Should contain basic ANSI color code and text
    try std.testing.expect(std.mem.indexOf(u8, result, "passed") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[38;2;") == null); // Should NOT be RGB
}

test "multi-version parse" {
    const palette = SemanticPalette{};
    const help = comptime parse("<command>myapp</command> <flag>--help</flag>", palette);

    // No color version should have no ANSI codes
    try std.testing.expect(std.mem.indexOf(u8, help.no_color, "\x1b[") == null);
    try std.testing.expect(std.mem.indexOf(u8, help.no_color, "myapp") != null);

    // True color version should have RGB codes
    try std.testing.expect(std.mem.indexOf(u8, help.true_color, "\x1b[38;2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.true_color, "myapp") != null);

    // Test select method
    const selected_no_color = help.select(.no_color);
    try std.testing.expectEqualStrings(help.no_color, selected_no_color);
}

test "parse mixed markdown and semantics" {
    const palette = SemanticPalette{};
    const result = comptime parseWithSemantics("Build <success>succeeded</success> with <warning>warnings</warning>", palette, .true_color);

    try std.testing.expect(std.mem.indexOf(u8, result, "Build") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "succeeded") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "warnings") != null);
}

test "parse markdown inside semantic tags" {
    const palette = SemanticPalette{};
    const result = comptime parseWithSemantics("<error>**Fatal error:**</error>", palette, .true_color);

    // Should contain both RGB color code AND bold ANSI code
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[38;2;") != null); // RGB color
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[1m") != null); // Bold
    try std.testing.expect(std.mem.indexOf(u8, result, "Fatal error:") != null);
}

test "parse format specifiers inside semantic tags" {
    const palette = SemanticPalette{};
    const result = comptime parseWithSemantics("<success>Processed **{d}** items</success>", palette, .true_color);

    // Should preserve {d} for runtime interpolation
    try std.testing.expect(std.mem.indexOf(u8, result, "{d}") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[1m") != null); // Bold for **{d}**
}

test {
    std.testing.refAllDecls(@This());
}
