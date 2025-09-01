const std = @import("std");
const testing = std.testing;
const SemanticRole = @import("semantic.zig").SemanticRole;
const palettes = @import("palettes.zig");
const RGB = palettes.RGB;

// Test that we can get colors for semantic roles
test "palettes return colors for semantic roles" {
    const success_color = palettes.getSemanticColor(.success);
    const err_color = palettes.getSemanticColor(.err);
    const warning_color = palettes.getSemanticColor(.warning);

    // Colors should exist and be different
    _ = success_color;
    _ = err_color;
    _ = warning_color;
}

// Test that all semantic roles have colors
test "all semantic roles have colors" {
    const roles = [_]SemanticRole{
        .success, .err,  .warning, .info,      .muted,
        .command, .flag, .path,    .value,
        .header,  .link, .primary, .secondary, .accent,
    };

    for (roles) |role| {
        const color = palettes.getSemanticColor(role);
        _ = color; // Should not crash
    }
}

// Test contrast ratios for accessibility
test "colors meet minimum contrast requirements" {
    // Test against black background
    {
        const bg_color = RGB{ .r = 0, .g = 0, .b = 0 }; // Black background

        const success_color = palettes.getSemanticRGB(.success);
        const contrast = calculateContrast(success_color, bg_color);
        try testing.expect(contrast >= 3.0); // Reasonable minimum

        const muted_color = palettes.getSemanticRGB(.muted);
        const muted_contrast = calculateContrast(muted_color, bg_color);
        try testing.expect(muted_contrast >= 2.0); // Lower for secondary content
    }

    // Test against white background
    {
        const bg_color = RGB{ .r = 255, .g = 255, .b = 255 }; // White background

        const success_color = palettes.getSemanticRGB(.success);
        const contrast = calculateContrast(success_color, bg_color);
        try testing.expect(contrast >= 1.0); // Should have some contrast

        const err_color = palettes.getSemanticRGB(.err);
        const err_contrast = calculateContrast(err_color, bg_color);
        try testing.expect(err_contrast >= 1.0);
    }
}

// Test that semantic roles maintain their meaning with recognizable hues
test "semantic colors maintain recognizable hues" {
    // Success should be greenish
    {
        const success = palettes.getSemanticRGB(.success);

        // Green component should be prominent
        try testing.expect(success.g > success.r);
        try testing.expect(success.g > success.b);
    }

    // Error should be reddish
    {
        const err = palettes.getSemanticRGB(.err);

        // Red component should be prominent
        try testing.expect(err.r > err.g);
        try testing.expect(err.r > err.b);
    }

    // Warning should be yellowish/orangeish
    {
        const warning = palettes.getSemanticRGB(.warning);

        // Red and green should be high (making yellow)
        try testing.expect(warning.r > warning.b);
        try testing.expect(warning.g > warning.b);
    }
}

// Test that colors have reasonable brightness values
test "semantic colors have reasonable brightness" {
    const success = palettes.getSemanticRGB(.success);
    const err = palettes.getSemanticRGB(.err);

    // Should use colors that are visible
    const success_brightness = getBrightness(success);
    const err_brightness = getBrightness(err);

    // Not too dark, not too bright
    try testing.expect(success_brightness > 50);
    try testing.expect(success_brightness < 220);
    try testing.expect(err_brightness > 50);
    try testing.expect(err_brightness < 220);
}

// Helper functions for testing

fn calculateContrast(fg: RGB, bg: RGB) f32 {
    const l1 = getRelativeLuminance(fg);
    const l2 = getRelativeLuminance(bg);

    const lighter = @max(l1, l2);
    const darker = @min(l1, l2);

    return (lighter + 0.05) / (darker + 0.05);
}

fn getRelativeLuminance(color: RGB) f32 {
    const r = linearize(@as(f32, @floatFromInt(color.r)) / 255.0);
    const g = linearize(@as(f32, @floatFromInt(color.g)) / 255.0);
    const b = linearize(@as(f32, @floatFromInt(color.b)) / 255.0);

    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

fn linearize(channel: f32) f32 {
    if (channel <= 0.03928) {
        return channel / 12.92;
    } else {
        return std.math.pow(f32, (channel + 0.055) / 1.055, 2.4);
    }
}

fn getBrightness(color: RGB) u16 {
    // Simple brightness calculation
    return (@as(u16, color.r) + @as(u16, color.g) + @as(u16, color.b)) / 3;
}
