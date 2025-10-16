//! Semantic color support for markdown_fmt
//!
//! Extends markdown parsing to support semantic tags like <error>, <success>, etc.
//! Can integrate with external theme systems like ztheme for color palettes.

const std = @import("std");

/// Terminal capability levels for color output
pub const TerminalCapability = enum {
    no_color, // No ANSI codes at all
    ansi_16, // Basic 16 ANSI colors
    ansi_256, // 256-color palette
    true_color, // 24-bit RGB
};

/// Semantic roles that can be used in markdown
pub const SemanticRole = enum {
    success,
    err, // 'error' is reserved
    warning,
    info,
    muted,
    command,
    flag,
    path,
    value,
    code,
    primary,
    secondary,
    accent,
};

/// RGB color for semantic roles
pub const RGB = struct {
    r: u8,
    g: u8,
    b: u8,

    /// Convert to ANSI escape code for the given terminal capability
    pub fn toAnsi(self: RGB, comptime capability: TerminalCapability) []const u8 {
        return switch (capability) {
            .no_color => "",
            .ansi_16 => self.toAnsi16(),
            .ansi_256 => self.toAnsi256(),
            .true_color => self.toTrueColor(),
        };
    }

    /// Convert to basic 16-color ANSI code (approximated)
    fn toAnsi16(self: RGB) []const u8 {
        comptime {
            const ansi_code = approximateRgbToAnsi16(self.r, self.g, self.b);
            return std.fmt.comptimePrint("\x1b[{d}m", .{30 + (ansi_code % 8)});
        }
    }

    /// Convert to 256-color ANSI code (approximated)
    fn toAnsi256(self: RGB) []const u8 {
        comptime {
            const color_idx = approximateRgbToAnsi256(self.r, self.g, self.b);
            return std.fmt.comptimePrint("\x1b[38;5;{d}m", .{color_idx});
        }
    }

    /// Convert to true color (24-bit RGB) ANSI code
    fn toTrueColor(self: RGB) []const u8 {
        comptime {
            return std.fmt.comptimePrint("\x1b[38;2;{d};{d};{d}m", .{ self.r, self.g, self.b });
        }
    }
};

/// Approximate RGB color to nearest 16-color ANSI code
fn approximateRgbToAnsi16(r: u8, g: u8, b: u8) u8 {
    // Use simple brightness-based approximation
    const brightness = (@as(u32, r) + @as(u32, g) + @as(u32, b)) / 3;
    const is_bright = brightness > 128;

    // Determine dominant color
    const max_component = @max(@max(r, g), b);
    const threshold: u8 = @intCast((@as(u16, max_component) * 60) / 100); // 60% of max

    var color_idx: u8 = 0;
    if (r >= threshold) color_idx |= 1; // Red bit
    if (g >= threshold) color_idx |= 2; // Green bit
    if (b >= threshold) color_idx |= 4; // Blue bit

    // If grayscale, use black or white
    const is_grayscale = (@max(@max(r, g), b) - @min(@min(r, g), b)) < 30;
    if (is_grayscale) {
        return if (brightness < 64) 0 else if (brightness > 192) 7 else 8;
    }

    return if (is_bright) color_idx + 8 else color_idx;
}

/// Approximate RGB color to nearest 256-color palette index
fn approximateRgbToAnsi256(r: u8, g: u8, b: u8) u8 {
    // Check if it's a grayscale color (r, g, b are similar)
    const max_diff = @max(@max(r, g), b) - @min(@min(r, g), b);
    if (max_diff < 8) {
        // Grayscale ramp: colors 232-255
        const gray_value = (@as(u16, r) + @as(u16, g) + @as(u16, b)) / 3;
        if (gray_value < 8) return 16; // Black
        if (gray_value > 247) return 231; // White
        return 232 + @as(u8, @intCast((gray_value - 8) / 10));
    }

    // Map to 6x6x6 RGB cube (colors 16-231)
    const r_idx = (@as(u16, r) * 5 + 127) / 255;
    const g_idx = (@as(u16, g) * 5 + 127) / 255;
    const b_idx = (@as(u16, b) * 5 + 127) / 255;

    return 16 + (r_idx * 36) + (g_idx * 6) + b_idx;
}

/// Semantic color palette
pub const SemanticPalette = struct {
    success: RGB = RGB{ .r = 76, .g = 217, .b = 100 },
    err: RGB = RGB{ .r = 255, .g = 105, .b = 97 },
    warning: RGB = RGB{ .r = 255, .g = 206, .b = 84 },
    info: RGB = RGB{ .r = 116, .g = 169, .b = 250 },
    muted: RGB = RGB{ .r = 156, .g = 163, .b = 175 },
    command: RGB = RGB{ .r = 64, .g = 224, .b = 208 },
    flag: RGB = RGB{ .r = 218, .g = 112, .b = 214 },
    path: RGB = RGB{ .r = 100, .g = 221, .b = 221 },
    value: RGB = RGB{ .r = 124, .g = 252, .b = 0 },
    code: RGB = RGB{ .r = 168, .g = 136, .b = 248 },
    primary: RGB = RGB{ .r = 255, .g = 255, .b = 255 },
    secondary: RGB = RGB{ .r = 189, .g = 189, .b = 189 },
    accent: RGB = RGB{ .r = 0, .g = 255, .b = 255 },

    pub fn getColor(self: SemanticPalette, role: SemanticRole) RGB {
        return switch (role) {
            .success => self.success,
            .err => self.err,
            .warning => self.warning,
            .info => self.info,
            .muted => self.muted,
            .command => self.command,
            .flag => self.flag,
            .path => self.path,
            .value => self.value,
            .code => self.code,
            .primary => self.primary,
            .secondary => self.secondary,
            .accent => self.accent,
        };
    }
};

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

                            // Parse markdown inside the semantic tag
                            const parsed_content = parseMarkdownOnly(content, capability);
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
