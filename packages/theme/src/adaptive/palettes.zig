const std = @import("std");
const SemanticRole = @import("semantic.zig").SemanticRole;
const TerminalCapability = @import("../detection/capability.zig").TerminalCapability;

// Import Color from parent module
const Color = @import("../core/color.zig").Color;

/// RGB color for precise color definitions
pub const RGB = struct {
    r: u8,
    g: u8,
    b: u8,

    /// Convert to Color enum for use in styling
    pub fn toColor(self: RGB) Color {
        return .{ .rgb = .{ .r = self.r, .g = self.g, .b = self.b } };
    }

    /// Convert to ANSI escape code for the given terminal capability (comptime)
    pub fn toAnsi(comptime self: RGB, comptime capability: TerminalCapability) []const u8 {
        return switch (capability) {
            .no_color => "",
            .ansi_16 => self.toAnsi16(),
            .ansi_256 => self.toAnsi256(),
            .true_color => self.toTrueColor(),
        };
    }

    /// Convert to basic 16-color ANSI code (approximated)
    fn toAnsi16(comptime self: RGB) []const u8 {
        const ansi_code = comptime approximateRgbToAnsi16(self.r, self.g, self.b);
        return comptime std.fmt.comptimePrint("\x1b[{d}m", .{30 + (ansi_code % 8)});
    }

    /// Convert to 256-color ANSI code (approximated)
    fn toAnsi256(comptime self: RGB) []const u8 {
        const color_idx = comptime approximateRgbToAnsi256(self.r, self.g, self.b);
        return comptime std.fmt.comptimePrint("\x1b[38;5;{d}m", .{color_idx});
    }

    /// Convert to true color (24-bit RGB) ANSI code
    fn toTrueColor(comptime self: RGB) []const u8 {
        return comptime std.fmt.comptimePrint("\x1b[38;2;{d};{d};{d}m", .{ self.r, self.g, self.b });
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

/// Semantic color palette with comptime-compatible defaults
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
    header: RGB = RGB{ .r = 255, .g = 255, .b = 255 },
    link: RGB = RGB{ .r = 135, .g = 206, .b = 250 },
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
            .header => self.header,
            .link => self.link,
            .primary => self.primary,
            .secondary => self.secondary,
            .accent => self.accent,
        };
    }
};

/// Get the color for a semantic role using our carefully designed palette
pub fn getSemanticColor(role: SemanticRole) Color {
    const rgb = getSemanticRGB(role);
    return rgb.toColor();
}

/// Get the RGB color for a semantic role using our carefully designed palette
pub fn getSemanticRGB(role: SemanticRole) RGB {
    return getPaletteColor(role);
}

/// Our carefully designed semantic color palette
/// These colors are chosen to be vibrant, distinctive, and accessible
fn getPaletteColor(role: SemanticRole) RGB {
    return switch (role) {
        // Core 5 - High contrast, WCAG AA compliant colors
        .success => RGB{ .r = 76, .g = 217, .b = 100 }, // Bright green - universally recognized for success
        .err => RGB{ .r = 255, .g = 105, .b = 97 }, // Bright coral red - stands out for errors
        .warning => RGB{ .r = 255, .g = 206, .b = 84 }, // Bright amber - perfect for warnings
        .info => RGB{ .r = 116, .g = 169, .b = 250 }, // Light blue - calm and informative
        .muted => RGB{ .r = 156, .g = 163, .b = 175 }, // Subtle gray - for less important text

        // CLI-specific roles
        .command => RGB{ .r = 64, .g = 224, .b = 208 }, // Turquoise - distinctive for commands
        .flag => RGB{ .r = 218, .g = 112, .b = 214 }, // Orchid - stands out for flags
        .path => RGB{ .r = 100, .g = 221, .b = 221 }, // Light cyan - classic for file paths
        .value => RGB{ .r = 124, .g = 252, .b = 0 }, // Lawn green - emphasizes values
        .code => RGB{ .r = 168, .g = 136, .b = 248 }, // Purple - inline code snippets
        .header => RGB{ .r = 255, .g = 255, .b = 255 }, // White - clean headers
        .link => RGB{ .r = 135, .g = 206, .b = 250 }, // Light sky blue - traditional link color

        // Hierarchy
        .primary => RGB{ .r = 255, .g = 255, .b = 255 }, // White - primary content
        .secondary => RGB{ .r = 189, .g = 189, .b = 189 }, // Light gray - secondary content
        .accent => RGB{ .r = 0, .g = 255, .b = 255 }, // Cyan - brand/accent color
    };
}

const testing = std.testing;

test "semantic color palette" {
    // Test semantic colors
    const success = getSemanticRGB(.success);
    try testing.expect(success.r == 76);
    try testing.expect(success.g == 217);
    try testing.expect(success.b == 100);

    const err = getSemanticRGB(.err);
    try testing.expect(err.r == 255);
    try testing.expect(err.g == 105);
    try testing.expect(err.b == 97);

    // Test color conversion
    const success_color = getSemanticColor(.success);
    try testing.expect(success_color == .rgb);
}
