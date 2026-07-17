//! Style definitions and ANSI escape sequence generation
//!
//! Combines colors and text decorations into complete styles that can
//! generate escape sequences at runtime or compile-time.

const std = @import("std");
const Color = @import("color.zig").Color;
const toAnsi16 = @import("color.zig").toAnsi16;
const toAnsi256 = @import("color.zig").toAnsi256;
const parseHex = @import("color.zig").parseHex;
const approximateRgbToAnsi16 = @import("color.zig").approximateRgbToAnsi16;
const approximateToAnsi16 = @import("color.zig").approximateToAnsi16;
const TerminalCapability = @import("../detection/capability.zig").TerminalCapability;

// Runtime version of toAnsi16 (color.zig's version requires comptime for hex parsing)
fn toAnsi16Runtime(color: Color) u8 {
    return switch (color) {
        .black => 0,
        .red => 1,
        .green => 2,
        .yellow => 3,
        .blue => 4,
        .magenta => 5,
        .cyan => 6,
        .white => 7,
        .bright_black => 8,
        .bright_red => 9,
        .bright_green => 10,
        .bright_yellow => 11,
        .bright_blue => 12,
        .bright_magenta => 13,
        .bright_cyan => 14,
        .bright_white => 15,
        .indexed => |idx| approximateToAnsi16(idx),
        .rgb => |rgb| approximateRgbToAnsi16(rgb.r, rgb.g, rgb.b),
        .hex => |hex_str| {
            const rgb = parseHex(hex_str);
            return approximateRgbToAnsi16(rgb.r, rgb.g, rgb.b);
        },
    };
}

/// Complete text styling information
pub const Style = struct {
    // Core styling
    foreground: ?Color = null,
    background: ?Color = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    dim: bool = false,
    reverse: bool = false,

    /// Apply `override` on top of this style: explicit colors in the override
    /// win, boolean attributes are additive.
    pub fn merge(self: @This(), override: Style) Style {
        return .{
            .foreground = override.foreground orelse self.foreground,
            .background = override.background orelse self.background,
            .bold = self.bold or override.bold,
            .dim = self.dim or override.dim,
            .italic = self.italic or override.italic,
            .underline = self.underline or override.underline,
            .strikethrough = self.strikethrough or override.strikethrough,
            .reverse = self.reverse or override.reverse,
        };
    }

    /// Create a new style with the given modifications
    pub fn with(self: @This(), modifications: anytype) Style {
        var result = self;

        const ModType = @TypeOf(modifications);
        const mod_info = @typeInfo(ModType);

        if (mod_info == .@"struct") {
            inline for (mod_info.@"struct".fields) |field| {
                if (@hasField(@This(), field.name)) {
                    @field(result, field.name) = @field(modifications, field.name);
                }
            }
        }

        return result;
    }

    /// Whether this style emits any escape codes at the given capability
    pub fn isVisible(self: @This(), capability: TerminalCapability) bool {
        if (capability == .no_color) return false;
        return self.bold or self.dim or self.italic or self.underline or
            self.strikethrough or self.reverse or
            self.foreground != null or self.background != null;
    }

    /// Write the ANSI escape sequence for this style to `writer`.
    /// Returns true if a sequence was written, so callers know whether a
    /// reset is needed after the styled content.
    pub fn writeSequence(self: @This(), writer: anytype, capability: TerminalCapability) !bool {
        if (!self.isVisible(capability)) return false;

        try writer.writeAll("\x1B[");
        var first = true;

        const decorations = [_]struct { enabled: bool, code: []const u8 }{
            .{ .enabled = self.bold, .code = "1" },
            .{ .enabled = self.dim, .code = "2" },
            .{ .enabled = self.italic, .code = "3" },
            .{ .enabled = self.underline, .code = "4" },
            .{ .enabled = self.strikethrough, .code = "9" },
            .{ .enabled = self.reverse, .code = "7" },
        };
        for (decorations) |decoration| {
            if (!decoration.enabled) continue;
            if (!first) try writer.writeAll(";");
            try writer.writeAll(decoration.code);
            first = false;
        }

        if (self.foreground) |color| {
            if (!first) try writer.writeAll(";");
            try writeColorCode(writer, color, capability, true);
            first = false;
        }
        if (self.background) |color| {
            if (!first) try writer.writeAll(";");
            try writeColorCode(writer, color, capability, false);
        }

        try writer.writeAll("m");
        return true;
    }

    /// Generate compile-time optimized sequence (when style is known at compile-time)
    pub fn sequenceComptime(comptime self: @This(), comptime capability: TerminalCapability) []const u8 {
        if (capability == .no_color) {
            return ""; // No color support
        }

        comptime {
            // Build sequence components at compile-time
            var seq_parts: [8][]const u8 = undefined;
            var part_count: usize = 0;

            // Add style codes
            if (self.bold) {
                seq_parts[part_count] = "1";
                part_count += 1;
            }
            if (self.dim) {
                seq_parts[part_count] = "2";
                part_count += 1;
            }
            if (self.italic) {
                seq_parts[part_count] = "3";
                part_count += 1;
            }
            if (self.underline) {
                seq_parts[part_count] = "4";
                part_count += 1;
            }
            if (self.strikethrough) {
                seq_parts[part_count] = "9";
                part_count += 1;
            }
            if (self.reverse) {
                seq_parts[part_count] = "7";
                part_count += 1;
            }

            // Add foreground color
            if (self.foreground) |fg_color| {
                seq_parts[part_count] = generateColorCodeComptime(fg_color, capability, true);
                part_count += 1;
            }

            // Add background color
            if (self.background) |bg_color| {
                seq_parts[part_count] = generateColorCodeComptime(bg_color, capability, false);
                part_count += 1;
            }

            if (part_count == 0) {
                return "";
            }

            return buildEscapeSequenceComptime(seq_parts[0..part_count]);
        }
    }
};

/// Write the ANSI color code (without the CSI prefix or trailing 'm') for `color`
fn writeColorCode(writer: anytype, color: Color, capability: TerminalCapability, is_foreground: bool) !void {
    switch (capability) {
        .no_color => {},
        .ansi_16 => {
            const idx = toAnsi16Runtime(color);
            if (idx < 8) {
                const base: u8 = if (is_foreground) 30 else 40;
                try writer.print("{d}", .{base + idx});
            } else {
                // Bright colors use different codes
                const base: u8 = if (is_foreground) 90 else 100;
                try writer.print("{d}", .{base + (idx - 8)});
            }
        },
        .ansi_256 => {
            const selector: u8 = if (is_foreground) 38 else 48;
            try writer.print("{d};5;{d}", .{ selector, toAnsi256(color) });
        },
        .true_color => {
            const selector: u8 = if (is_foreground) 38 else 48;
            switch (color) {
                .rgb => |rgb| try writer.print("{d};2;{d};{d};{d}", .{ selector, rgb.r, rgb.g, rgb.b }),
                .hex => |hex_str| {
                    const rgb = parseHex(hex_str);
                    try writer.print("{d};2;{d};{d};{d}", .{ selector, rgb.r, rgb.g, rgb.b });
                },
                // Fall back to 256-color for palette-based colors
                else => try writer.print("{d};5;{d}", .{ selector, toAnsi256(color) }),
            }
        },
    }
}

/// Generate ANSI color code at compile-time
fn generateColorCodeComptime(comptime color: Color, comptime capability: TerminalCapability, comptime is_foreground: bool) []const u8 {
    comptime {
        const base_offset: u8 = if (is_foreground) 30 else 40;

        switch (capability) {
            .no_color => return "",
            .ansi_16 => {
                const color_idx = toAnsi16(color);
                if (color_idx < 8) {
                    return std.fmt.comptimePrint("{d}", .{base_offset + color_idx});
                } else {
                    // Bright colors use different codes
                    const bright_offset: u8 = if (is_foreground) 90 else 100;
                    return std.fmt.comptimePrint("{d}", .{bright_offset + (color_idx - 8)});
                }
            },
            .ansi_256 => {
                const color_idx = toAnsi256(color);
                const color_type: u8 = if (is_foreground) 38 else 48;
                return std.fmt.comptimePrint("{d};5;{d}", .{ color_type, color_idx });
            },
            .true_color => {
                const color_type: u8 = if (is_foreground) 38 else 48;
                switch (color) {
                    .rgb => |rgb| return std.fmt.comptimePrint("{d};2;{d};{d};{d}", .{ color_type, rgb.r, rgb.g, rgb.b }),
                    .hex => |hex_str| {
                        const rgb = parseHex(hex_str);
                        return std.fmt.comptimePrint("{d};2;{d};{d};{d}", .{ color_type, rgb.r, rgb.g, rgb.b });
                    },
                    // Fall back to 256-color for palette-based colors
                    else => {
                        const color_idx = toAnsi256(color);
                        return std.fmt.comptimePrint("{d};5;{d}", .{ color_type, color_idx });
                    },
                }
            },
        }
    }
}

/// Build complete escape sequence from parts at compile-time
fn buildEscapeSequenceComptime(comptime parts: []const []const u8) []const u8 {
    comptime {
        if (parts.len == 0) return "";

        var seq: []const u8 = "\x1B[" ++ parts[0];
        for (parts[1..]) |part| {
            seq = seq ++ ";" ++ part;
        }
        return seq ++ "m";
    }
}

fn sequenceToBuf(style: Style, capability: TerminalCapability, buf: []u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    _ = try style.writeSequence(&writer, capability);
    return writer.buffered();
}

test "style creation and modification" {
    const testing = std.testing;

    // Test basic style
    const basic_style = Style{};
    try testing.expect(!basic_style.bold);
    try testing.expect(basic_style.foreground == null);

    // Test style modification
    const bold_style = basic_style.with(.{ .bold = true });
    try testing.expect(bold_style.bold);

    // Test color style
    const red_style = Style{ .foreground = Color.red };
    try testing.expect(red_style.foreground != null);
    try testing.expect(red_style.foreground.? == Color.red);
}

test "ANSI sequence generation for different capabilities" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;

    // Test basic bold style
    const bold_style = Style{ .bold = true };
    try testing.expectEqualStrings("\x1B[1m", try sequenceToBuf(bold_style, .ansi_16, &buf));
    try testing.expectEqualStrings("", try sequenceToBuf(bold_style, .no_color, &buf));

    // Test red foreground
    const red_style = Style{ .foreground = Color.red };
    try testing.expectEqualStrings("\x1B[31m", try sequenceToBuf(red_style, .ansi_16, &buf));

    // Test bright red (should use 90+ codes)
    const bright_red_style = Style{ .foreground = Color.bright_red };
    try testing.expectEqualStrings("\x1B[91m", try sequenceToBuf(bright_red_style, .ansi_16, &buf));

    // Test background color
    const bg_blue_style = Style{ .background = Color.blue };
    try testing.expectEqualStrings("\x1B[44m", try sequenceToBuf(bg_blue_style, .ansi_16, &buf));

    // Test combined styles
    const complex_style = Style{ .foreground = Color.red, .bold = true, .underline = true };
    try testing.expectEqualStrings("\x1B[1;4;31m", try sequenceToBuf(complex_style, .ansi_16, &buf));
}

test "writeSequence returns whether anything was written" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;

    const styled = Style{ .foreground = Color.red };
    const plain = Style{};

    var writer: std.Io.Writer = .fixed(&buf);
    try testing.expect(try styled.writeSequence(&writer, .ansi_16));
    try testing.expect(!try styled.writeSequence(&writer, .no_color));
    try testing.expect(!try plain.writeSequence(&writer, .ansi_16));
}

test "sequential writes do not clobber each other" {
    const testing = std.testing;

    // Regression test: the old implementation returned slices of a shared
    // threadlocal buffer, so a second call invalidated the first result.
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    const first = Style{ .foreground = Color{ .rgb = .{ .r = 1, .g = 2, .b = 3 } } };
    const second = Style{ .foreground = Color{ .rgb = .{ .r = 4, .g = 5, .b = 6 } } };
    _ = try first.writeSequence(&writer, .true_color);
    _ = try second.writeSequence(&writer, .true_color);

    try testing.expectEqualStrings("\x1B[38;2;1;2;3m\x1B[38;2;4;5;6m", writer.buffered());
}

test "compile-time sequence generation" {
    const testing = std.testing;

    // Test compile-time generation
    const red_bold = Style{ .foreground = Color.red, .bold = true };
    const comptime_seq = comptime red_bold.sequenceComptime(.ansi_16);
    try testing.expectEqualStrings("\x1B[1;31m", comptime_seq);
}

test "compile-time sequence includes more than three parts" {
    const testing = std.testing;

    // Regression test: the old implementation silently dropped everything
    // past the third part, losing e.g. the background color here.
    const style = Style{ .foreground = Color.red, .background = Color.blue, .bold = true, .underline = true };
    const seq = comptime style.sequenceComptime(.ansi_16);
    try testing.expectEqualStrings("\x1B[1;4;31;44m", seq);
}

test "RGB and 256-color sequence generation" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;

    // Test RGB color in true color mode
    const rgb_style = Style{ .foreground = Color{ .rgb = .{ .r = 255, .g = 128, .b = 64 } } };
    try testing.expectEqualStrings("\x1B[38;2;255;128;64m", try sequenceToBuf(rgb_style, .true_color, &buf));

    // Test 256-color mode
    const indexed_style = Style{ .foreground = Color{ .indexed = 196 } };
    try testing.expectEqualStrings("\x1B[38;5;196m", try sequenceToBuf(indexed_style, .ansi_256, &buf));

    // Regression test: the old implementation only knew a hardcoded subset of
    // indices and silently rendered everything else as bright white.
    const arbitrary_indexed = Style{ .foreground = Color{ .indexed = 123 } };
    try testing.expectEqualStrings("\x1B[38;5;123m", try sequenceToBuf(arbitrary_indexed, .ansi_256, &buf));
    const arbitrary_indexed_bg = Style{ .background = Color{ .indexed = 201 } };
    try testing.expectEqualStrings("\x1B[48;5;201m", try sequenceToBuf(arbitrary_indexed_bg, .ansi_256, &buf));
}

test "hex colors render as exact RGB in true color mode" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;

    const hex_style = Style{ .foreground = Color{ .hex = "#FF8040" } };
    try testing.expectEqualStrings("\x1B[38;2;255;128;64m", try sequenceToBuf(hex_style, .true_color, &buf));

    const comptime_seq = comptime (Style{ .foreground = Color{ .hex = "#FF8040" } }).sequenceComptime(.true_color);
    try testing.expectEqualStrings("\x1B[38;2;255;128;64m", comptime_seq);
}

test "runtime indexed→ansi16 downconversion picks nearest color" {
    const testing = std.testing;

    // First 16 palette entries pass straight through.
    try testing.expectEqual(@as(u8, 9), toAnsi16Runtime(Color{ .indexed = 9 }));

    // 216-color cube entries map to the nearest ANSI-16 color instead of
    // collapsing to white (7). Regression: idx 196 is pure red, not white.
    try testing.expectEqual(@as(u8, 9), toAnsi16Runtime(Color{ .indexed = 196 })); // bright red
    try testing.expectEqual(@as(u8, 1), toAnsi16Runtime(Color{ .indexed = 88 })); // dim red
    try testing.expectEqual(@as(u8, 12), toAnsi16Runtime(Color{ .indexed = 21 })); // bright blue
    try testing.expectEqual(@as(u8, 13), toAnsi16Runtime(Color{ .indexed = 201 })); // bright magenta
    try testing.expectEqual(@as(u8, 14), toAnsi16Runtime(Color{ .indexed = 123 })); // bright cyan

    // Grayscale ramp (232-255) spans black → gray → bright white.
    try testing.expectEqual(@as(u8, 0), toAnsi16Runtime(Color{ .indexed = 232 })); // black
    try testing.expectEqual(@as(u8, 8), toAnsi16Runtime(Color{ .indexed = 244 })); // gray
    try testing.expectEqual(@as(u8, 15), toAnsi16Runtime(Color{ .indexed = 255 })); // bright white
}

test "indexed colors render as nearest ANSI-16 sequence" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;

    // Regression test: the runtime fallback used to emit bright white (97) for
    // every index ≥ 16, so pure-red 196 rendered white on a 16-color terminal.
    const red_style = Style{ .foreground = Color{ .indexed = 196 } };
    try testing.expectEqualStrings("\x1B[91m", try sequenceToBuf(red_style, .ansi_16, &buf));

    const blue_bg = Style{ .background = Color{ .indexed = 21 } };
    try testing.expectEqualStrings("\x1B[104m", try sequenceToBuf(blue_bg, .ansi_16, &buf));

    const gray_style = Style{ .foreground = Color{ .indexed = 244 } };
    try testing.expectEqualStrings("\x1B[90m", try sequenceToBuf(gray_style, .ansi_16, &buf));
}

test "multiple text decorations" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;

    // Test all decorations together
    const decorated_style = Style{
        .bold = true,
        .italic = true,
        .underline = true,
        .strikethrough = true,
        .dim = true,
    };
    try testing.expectEqualStrings("\x1B[1;2;3;4;9m", try sequenceToBuf(decorated_style, .ansi_16, &buf));
}
