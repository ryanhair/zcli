//! Color definitions and ANSI sequence generation
//!
//! Supports the full spectrum of terminal colors from basic 16-color ANSI
//! to 24-bit true color, with automatic capability-based fallbacks.

const std = @import("std");

/// Terminal color representation supporting all capability levels
pub const Color = union(enum) {
    // Basic 16 ANSI colors
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,

    // 256-color palette index (0-255)
    indexed: u8,

    // True color RGB values
    rgb: struct {
        r: u8,
        g: u8,
        b: u8,
    },

    // Hex color string (converted to RGB at compile-time)
    hex: []const u8,
};

/// Convert any color to its basic ANSI equivalent (0-15)
pub fn toAnsi16(comptime color: Color) u8 {
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
        .indexed => |idx| if (idx < 16) idx else approximateToAnsi16(idx),
        .rgb => |rgb| approximateRgbToAnsi16(rgb.r, rgb.g, rgb.b),
        .hex => |hex| approximateHexToAnsi16(hex),
    };
}

/// Convert any color to 256-color palette index
pub fn toAnsi256(color: Color) u8 {
    return switch (color) {
        // Basic 16 colors map directly
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
        .indexed => |idx| idx, // Already in 256-color format
        .rgb => |rgb| rgbToAnsi256(rgb.r, rgb.g, rgb.b),
        .hex => |hex| {
            // For runtime hex conversion, we need a runtime version
            const rgb = parseHex(hex);
            return rgbToAnsi256(rgb.r, rgb.g, rgb.b);
        },
    };
}

/// Convert RGB to closest 256-color palette index
fn rgbToAnsi256(r: u8, g: u8, b: u8) u8 {
    // Check if it's close to a grayscale value
    const avg = (@as(u16, r) + @as(u16, g) + @as(u16, b)) / 3;
    const r_diff = if (r > avg) r - @as(u8, @intCast(avg)) else @as(u8, @intCast(avg)) - r;
    const g_diff = if (g > avg) g - @as(u8, @intCast(avg)) else @as(u8, @intCast(avg)) - g;
    const b_diff = if (b > avg) b - @as(u8, @intCast(avg)) else @as(u8, @intCast(avg)) - b;

    // If close to grayscale, use grayscale ramp (232-255)
    if (r_diff < 15 and g_diff < 15 and b_diff < 15) {
        const gray_idx = @as(u8, @intCast(avg)) / 11; // 0-23 range
        return @as(u8, 232) + @min(gray_idx, @as(u8, 23));
    }

    // Use 216-color cube (16-231)
    const r_idx = @as(u8, @intCast((@as(u16, r) * 5) / 255));
    const g_idx = @as(u8, @intCast((@as(u16, g) * 5) / 255));
    const b_idx = @as(u8, @intCast((@as(u16, b) * 5) / 255));

    return 16 + (r_idx * 36) + (g_idx * 6) + b_idx;
}

/// Convert 256-color palette index to closest 16-color ANSI equivalent
fn approximateToAnsi16(idx: u8) u8 {
    // First 16 colors map directly
    if (idx < 16) return idx;

    // 216 color cube (16-231): convert to RGB then approximate
    if (idx < 232) {
        const cube_idx = idx - 16;
        const r = (cube_idx / 36) * 51; // 0-5 → 0-255 in steps of 51
        const g = ((cube_idx % 36) / 6) * 51;
        const b = (cube_idx % 6) * 51;
        return approximateRgbToAnsi16(@as(u8, @intCast(r)), @as(u8, @intCast(g)), @as(u8, @intCast(b)));
    }

    // Grayscale ramp (232-255): 24 shades from dark to light
    const gray_level = (idx - 232) * 10 + 8; // Maps to 8-238 range
    return approximateRgbToAnsi16(@as(u8, @intCast(gray_level)), @as(u8, @intCast(gray_level)), @as(u8, @intCast(gray_level)));
}

/// Convert RGB values to closest 16-color ANSI equivalent using smart color categorization
pub fn approximateRgbToAnsi16(r: u8, g: u8, b: u8) u8 {
    // First, try semantic color matching for better results
    // This helps colors like coral red map to red, light blue map to cyan, etc.
    
    // Find the dominant color component
    const max_component = @max(@max(r, g), b);
    const min_component = @min(@min(r, g), b);
    const brightness = (@as(u16, r) + @as(u16, g) + @as(u16, b)) / 3;
    
    // Check for grayscale
    const color_range = max_component - min_component;
    if (color_range < 30) {
        // It's grayscale
        if (brightness < 64) return 0;        // black
        if (brightness <= 128) return 8;     // bright black (gray) - include 128
        if (brightness < 192) return 7;      // white
        return 15;                           // bright white
    }
    
    // Determine if it's a bright color - consider both overall brightness and individual component intensity
    // Pure colors like (255,0,0) should be bright even if overall brightness is low
    const is_bright = brightness > 140 or max_component > 200;
    
    // Categorize by dominant hue using improved logic
    const r_dominance = @as(i16, r) - @divTrunc((@as(i16, g) + @as(i16, b)), 2);
    const g_dominance = @as(i16, g) - @divTrunc((@as(i16, r) + @as(i16, b)), 2);
    const b_dominance = @as(i16, b) - @divTrunc((@as(i16, r) + @as(i16, g)), 2);
    
    // Yellow-ish (high red and green, lower blue) - check first before red/green
    if (r > 150 and g > 150 and b < (@as(u16, r) + @as(u16, g)) / 2) {
        return if (is_bright) 11 else 3; // bright yellow or yellow
    }
    
    // Red-ish (including coral red)
    if (r_dominance > 20 and r > g and r > b) {
        return if (is_bright) 9 else 1; // bright red or red
    }
    
    // Green-ish
    if (g_dominance > 20 and g > r and g > b) {
        return if (is_bright) 10 else 2; // bright green or green
    }
    
    // Blue-ish (including light blue)
    if (b_dominance > 20 and b > r and b > g) {
        return if (is_bright) 12 else 4; // bright blue or blue
    }
    
    // Cyan-ish (high green and blue, low red) - this handles light blue → cyan mapping
    if (g > 100 and b > 100 and r < g - 30 and r < b - 30) {
        return if (is_bright) 14 else 6; // bright cyan or cyan
    }
    
    // Magenta-ish (high red and blue, low green)
    if (r > 100 and b > 100 and g < r - 50 and g < b - 50) {
        return if (is_bright) 13 else 5; // bright magenta or magenta
    }
    
    // Fallback to perceptual distance if semantic matching fails
    const ansi_colors = [_][3]u8{
        .{ 0, 0, 0 }, .{ 128, 0, 0 }, .{ 0, 128, 0 }, .{ 128, 128, 0 },
        .{ 0, 0, 128 }, .{ 128, 0, 128 }, .{ 0, 128, 128 }, .{ 192, 192, 192 },
        .{ 128, 128, 128 }, .{ 255, 0, 0 }, .{ 0, 255, 0 }, .{ 255, 255, 0 },
        .{ 0, 0, 255 }, .{ 255, 0, 255 }, .{ 0, 255, 255 }, .{ 255, 255, 255 },
    };

    var best_idx: u8 = 7; // default to white
    var best_distance: u32 = std.math.maxInt(u32);

    for (ansi_colors, 0..) |ansi_rgb, idx| {
        const dr = @as(i32, r) - @as(i32, ansi_rgb[0]);
        const dg = @as(i32, g) - @as(i32, ansi_rgb[1]);
        const db = @as(i32, b) - @as(i32, ansi_rgb[2]);
        const distance = @as(u32, @intCast(dr * dr + dg * dg + db * db));
        
        if (distance < best_distance) {
            best_distance = distance;
            best_idx = @as(u8, @intCast(idx));
        }
    }

    return best_idx;
}

/// Convert hex color string to RGB then to ANSI-16 (compile-time only)
fn approximateHexToAnsi16(comptime hex: []const u8) u8 {
    const rgb = parseHexToRgb(hex);
    return approximateRgbToAnsi16(rgb.r, rgb.g, rgb.b);
}

/// Parse hex color string to RGB struct
pub fn parseHex(hex: []const u8) struct { r: u8, g: u8, b: u8 } {
    // Remove # if present
    const color_str = if (hex.len > 0 and hex[0] == '#') hex[1..] else hex;

    if (color_str.len == 3) {
        // Short form: #RGB -> #RRGGBB
        const r = parseHexDigitRuntime(color_str[0]) * 17;
        const g = parseHexDigitRuntime(color_str[1]) * 17;
        const b = parseHexDigitRuntime(color_str[2]) * 17;
        return .{ .r = r, .g = g, .b = b };
    } else if (color_str.len == 6) {
        // Long form: #RRGGBB
        const r = parseHexDigitRuntime(color_str[0]) * 16 + parseHexDigitRuntime(color_str[1]);
        const g = parseHexDigitRuntime(color_str[2]) * 16 + parseHexDigitRuntime(color_str[3]);
        const b = parseHexDigitRuntime(color_str[4]) * 16 + parseHexDigitRuntime(color_str[5]);
        return .{ .r = r, .g = g, .b = b };
    } else {
        // Invalid format, return white
        return .{ .r = 255, .g = 255, .b = 255 };
    }
}

/// Parse hex color string to RGB struct at compile-time
fn parseHexToRgb(comptime hex: []const u8) struct { r: u8, g: u8, b: u8 } {
    // Remove # if present
    const color_str = if (hex.len > 0 and hex[0] == '#') hex[1..] else hex;

    if (color_str.len == 3) {
        // Short form: #RGB -> #RRGGBB
        const r = parseHexDigit(color_str[0]) * 17; // F -> FF (15 * 17 = 255)
        const g = parseHexDigit(color_str[1]) * 17;
        const b = parseHexDigit(color_str[2]) * 17;
        return .{ .r = r, .g = g, .b = b };
    } else if (color_str.len == 6) {
        // Long form: #RRGGBB
        const r = parseHexDigit(color_str[0]) * 16 + parseHexDigit(color_str[1]);
        const g = parseHexDigit(color_str[2]) * 16 + parseHexDigit(color_str[3]);
        const b = parseHexDigit(color_str[4]) * 16 + parseHexDigit(color_str[5]);
        return .{ .r = r, .g = g, .b = b };
    } else {
        // Invalid format, return white
        return .{ .r = 255, .g = 255, .b = 255 };
    }
}

/// Parse a single hex digit to its numeric value (runtime version)
fn parseHexDigitRuntime(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'F' => c - 'A' + 10,
        'a'...'f' => c - 'a' + 10,
        else => 0, // Invalid digit, default to 0
    };
}

/// Parse a single hex digit to its numeric value (compile-time only)
fn parseHexDigit(comptime c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'F' => c - 'A' + 10,
        'a'...'f' => c - 'a' + 10,
        else => 0, // Invalid digit, default to 0
    };
}

test "basic color creation" {
    const testing = std.testing;

    // Test basic colors
    const red = Color.red;
    try testing.expect(comptime toAnsi16(red) == 1);

    const blue = Color.blue;
    try testing.expect(comptime toAnsi16(blue) == 4);

    // Test bright colors
    const bright_red = Color.bright_red;
    try testing.expect(comptime toAnsi16(bright_red) == 9);

    // Test RGB color approximation
    const orange_rgb = Color{ .rgb = .{ .r = 255, .g = 128, .b = 0 } };
    const orange_ansi = comptime toAnsi16(orange_rgb);
    try testing.expect(orange_ansi == 1 or orange_ansi == 3 or orange_ansi == 9 or orange_ansi == 11); // Should be red/yellow-ish
}

test "color conversion to ANSI-256" {
    const testing = std.testing;

    // Test basic colors map correctly
    try testing.expect(toAnsi256(Color.red) == 1);
    try testing.expect(toAnsi256(Color.bright_white) == 15);

    // Test indexed color passthrough
    const indexed = Color{ .indexed = 42 };
    try testing.expect(toAnsi256(indexed) == 42);

    // Test RGB to 256-color conversion
    const pure_red = Color{ .rgb = .{ .r = 255, .g = 0, .b = 0 } };
    const red_256 = toAnsi256(pure_red);
    try testing.expect(red_256 >= 16); // Should be in the color cube range

    // Test grayscale detection
    const gray = Color{ .rgb = .{ .r = 128, .g = 128, .b = 128 } };
    const gray_256 = toAnsi256(gray);
    try testing.expect(gray_256 >= 232 and gray_256 <= 255); // Should be in grayscale ramp
}

test "hex color parsing" {
    const testing = std.testing;

    // Test short hex format
    const red_short = parseHexToRgb("F00");
    try testing.expect(red_short.r == 255 and red_short.g == 0 and red_short.b == 0);

    // Test long hex format
    const blue_long = parseHexToRgb("0000FF");
    try testing.expect(blue_long.r == 0 and blue_long.g == 0 and blue_long.b == 255);

    // Test hex with # prefix
    const green_hash = parseHexToRgb("#00FF00");
    try testing.expect(green_hash.r == 0 and green_hash.g == 255 and green_hash.b == 0);

    // Test hex color to ANSI conversion
    const hex_red = Color{ .hex = "#FF0000" };
    const hex_ansi = comptime toAnsi16(hex_red);
    try testing.expect(hex_ansi == 1 or hex_ansi == 9); // Should map to red or bright red
}

test "RGB to ANSI-16 approximation accuracy" {
    const testing = std.testing;

    // Test pure colors map correctly
    try testing.expect(approximateRgbToAnsi16(255, 0, 0) == 9); // Bright red
    try testing.expect(approximateRgbToAnsi16(0, 255, 0) == 10); // Bright green
    try testing.expect(approximateRgbToAnsi16(0, 0, 255) == 12); // Bright blue
    try testing.expect(approximateRgbToAnsi16(0, 0, 0) == 0); // Black
    try testing.expect(approximateRgbToAnsi16(255, 255, 255) == 15); // Bright white

    // Test darker colors
    try testing.expect(approximateRgbToAnsi16(128, 0, 0) == 1); // Dark red
    try testing.expect(approximateRgbToAnsi16(0, 128, 0) == 2); // Dark green
    try testing.expect(approximateRgbToAnsi16(128, 128, 128) == 8); // Gray
}
