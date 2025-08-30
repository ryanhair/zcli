const std = @import("std");
const SemanticRole = @import("semantic.zig").SemanticRole;

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
        .success => RGB{ .r = 76, .g = 217, .b = 100 },    // Bright green - universally recognized for success
        .err => RGB{ .r = 255, .g = 105, .b = 97 },        // Bright coral red - stands out for errors
        .warning => RGB{ .r = 255, .g = 206, .b = 84 },    // Bright amber - perfect for warnings
        .info => RGB{ .r = 116, .g = 169, .b = 250 },      // Light blue - calm and informative
        .muted => RGB{ .r = 156, .g = 163, .b = 175 },     // Subtle gray - for less important text
        
        // CLI-specific roles
        .command => RGB{ .r = 64, .g = 224, .b = 208 },    // Turquoise - distinctive for commands
        .flag => RGB{ .r = 218, .g = 112, .b = 214 },      // Orchid - stands out for flags
        .path => RGB{ .r = 100, .g = 221, .b = 221 },      // Light cyan - classic for file paths
        .value => RGB{ .r = 124, .g = 252, .b = 0 },       // Lawn green - emphasizes values
        .header => RGB{ .r = 255, .g = 255, .b = 255 },    // White - clean headers
        .link => RGB{ .r = 135, .g = 206, .b = 250 },      // Light sky blue - traditional link color
        
        // Hierarchy
        .primary => RGB{ .r = 255, .g = 255, .b = 255 },   // White - primary content
        .secondary => RGB{ .r = 189, .g = 189, .b = 189 }, // Light gray - secondary content
        .accent => RGB{ .r = 0, .g = 255, .b = 255 },      // Cyan - brand/accent color
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