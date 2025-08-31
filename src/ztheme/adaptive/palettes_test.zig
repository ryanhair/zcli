const std = @import("std");
const testing = std.testing;
const SemanticRole = @import("semantic.zig").SemanticRole;
const BackgroundType = @import("semantic.zig").BackgroundType;
const palettes = @import("palettes.zig");
const RGB = palettes.RGB;

// Test that we can get colors for different backgrounds
test "adaptive palettes return different colors for different backgrounds" {
    const dark_success = palettes.getAdaptiveColor(.success, .dark);
    const light_success = palettes.getAdaptiveColor(.success, .light);
    const unknown_success = palettes.getAdaptiveColor(.success, .unknown);

    // Colors should be different for different backgrounds
    // (We can't test exact values yet, but they should exist)
    _ = dark_success;
    _ = light_success;
    _ = unknown_success;
}

// Test that all semantic roles have colors for all backgrounds
test "all semantic roles have adaptive colors" {
    const roles = [_]SemanticRole{
        .success, .err,  .warning, .info,      .muted,
        .command, .flag, .path,    .code,      .value,
        .header,  .link, .primary, .secondary, .accent,
    };

    const backgrounds = [_]BackgroundType{ .dark, .light, .unknown };

    for (roles) |role| {
        for (backgrounds) |bg| {
            const color = palettes.getAdaptiveColor(role, bg);
            _ = color; // Should not crash
        }
    }
}

// Test contrast ratios for accessibility
test "adaptive colors meet minimum contrast requirements" {
    // Dark background - test against black
    {
        const bg_color = RGB{ .r = 0, .g = 0, .b = 0 }; // Black background

        const success_color = palettes.getAdaptiveRGB(.success, .dark);
        const contrast = calculateContrast(success_color, bg_color);
        try testing.expect(contrast >= 4.5); // WCAG AA minimum

        const muted_color = palettes.getAdaptiveRGB(.muted, .dark);
        const muted_contrast = calculateContrast(muted_color, bg_color);
        try testing.expect(muted_contrast >= 2.5); // Lower for secondary content
    }

    // Light background - test against white
    {
        const bg_color = RGB{ .r = 255, .g = 255, .b = 255 }; // White background

        const success_color = palettes.getAdaptiveRGB(.success, .light);
        const contrast = calculateContrast(success_color, bg_color);
        try testing.expect(contrast >= 4.5); // WCAG AA minimum

        const err_color = palettes.getAdaptiveRGB(.err, .light);
        const err_contrast = calculateContrast(err_color, bg_color);
        try testing.expect(err_contrast >= 4.5);
    }
}

// Test that semantic roles maintain their meaning across backgrounds
test "semantic colors maintain recognizable hues" {
    // Success should be greenish regardless of background
    {
        const dark_success = palettes.getAdaptiveRGB(.success, .dark);
        const light_success = palettes.getAdaptiveRGB(.success, .light);

        // Green component should be prominent
        try testing.expect(dark_success.g > dark_success.r);
        try testing.expect(dark_success.g > dark_success.b);
        try testing.expect(light_success.g > light_success.r);
        try testing.expect(light_success.g > light_success.b);
    }

    // Error should be reddish
    {
        const dark_err = palettes.getAdaptiveRGB(.err, .dark);
        const light_err = palettes.getAdaptiveRGB(.err, .light);

        // Red component should be prominent
        try testing.expect(dark_err.r > dark_err.g);
        try testing.expect(dark_err.r > dark_err.b);
        try testing.expect(light_err.r > light_err.g);
        try testing.expect(light_err.r > light_err.b);
    }

    // Warning should be yellowish/orangeish
    {
        const dark_warning = palettes.getAdaptiveRGB(.warning, .dark);
        const light_warning = palettes.getAdaptiveRGB(.warning, .light);

        // Red and green should be high (making yellow)
        try testing.expect(dark_warning.r > dark_warning.b);
        try testing.expect(dark_warning.g > dark_warning.b);
        try testing.expect(light_warning.r > light_warning.b);
        try testing.expect(light_warning.g > light_warning.b);
    }
}

// Test safe fallback colors for unknown backgrounds
test "unknown background uses safe middle-ground colors" {
    const unknown_success = palettes.getAdaptiveRGB(.success, .unknown);
    const unknown_err = palettes.getAdaptiveRGB(.err, .unknown);

    // Should use colors that work on both dark and light
    // Generally means medium brightness colors
    const success_brightness = getBrightness(unknown_success);
    const err_brightness = getBrightness(unknown_err);

    // Not too dark, not too bright
    try testing.expect(success_brightness > 60);
    try testing.expect(success_brightness < 200);
    try testing.expect(err_brightness > 60);
    try testing.expect(err_brightness < 200);
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
