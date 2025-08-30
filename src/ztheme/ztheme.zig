//! ZTheme - A powerful, zero-cost CLI theming system for Zig
//!
//! ZTheme provides compile-time style generation, runtime terminal capability
//! detection, and an intuitive fluent API for creating beautiful CLI output.
//!
//! Basic usage:
//! ```zig
//! const ztheme = @import("ztheme");
//! 
//! // Simple coloring
//! try ztheme.theme("Error").red().bold().render(writer, &theme_ctx);
//!
//! // RGB colors
//! try ztheme.theme("Custom").rgb(255, 100, 50).render(writer, &theme_ctx);
//!
//! // Background colors
//! try ztheme.theme("Highlighted").onYellow().black().render(writer, &theme_ctx);
//! ```

const std = @import("std");

// Core theming types
pub const Color = @import("core/color.zig").Color;
pub const Style = @import("core/style.zig").Style;

// Terminal detection and capability management
pub const TerminalCapability = @import("detection/capability.zig").TerminalCapability;
pub const Theme = @import("detection/capability.zig").Theme;

// Main API
pub const Themed = @import("api/fluent.zig").Themed;
pub const theme = @import("api/fluent.zig").theme;

// Markdown DSL API
pub const md = @import("dsl/markdown.zig").md;

// Test API - simple function to verify structure
pub fn version() []const u8 {
    return "0.1.0";
}

test "ztheme module imports" {
    // Basic smoke test to ensure all imports work
    const testing = std.testing;
    try testing.expect(version().len > 0);
}

// Import all submodule tests to run them together
test {
    std.testing.refAllDecls(@import("core/color.zig"));
    std.testing.refAllDecls(@import("core/style.zig"));
    std.testing.refAllDecls(@import("detection/capability.zig"));
    std.testing.refAllDecls(@import("api/fluent.zig"));
    std.testing.refAllDecls(@import("tests/integration_test.zig"));
    std.testing.refAllDecls(@import("adaptive/semantic.zig"));
    std.testing.refAllDecls(@import("adaptive/semantic_test.zig"));
    std.testing.refAllDecls(@import("adaptive/palettes.zig"));
    std.testing.refAllDecls(@import("adaptive/palettes_test.zig"));
    
    // DSL tests
    std.testing.refAllDecls(@import("dsl/ast.zig"));
    std.testing.refAllDecls(@import("dsl/tokenizer.zig"));
    std.testing.refAllDecls(@import("dsl/parser.zig"));
    std.testing.refAllDecls(@import("dsl/markdown.zig"));
}