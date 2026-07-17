//! theme - a CLI design system for Zig
//!
//! A `Theme` is defined once per CLI: a palette maps semantic roles to
//! styles, and component tokens (prompts, progress) reference those roles.
//! Render paths consume a `ThemeContext`, which pairs the theme with the
//! detected terminal capabilities and degrades output gracefully
//! (true color -> 256 -> 16 -> plain).
//!
//! Basic usage:
//! ```zig
//! const theme = @import("theme");
//!
//! // Semantic styling - resolved through the active palette at render time
//! try theme.styled("Build passed").success().render(writer, &ctx);
//!
//! // Direct styling
//! try theme.styled("Custom").rgb(255, 100, 50).bold().render(writer, &ctx);
//! ```

const std = @import("std");

// Core styling types
pub const Color = @import("core/color.zig").Color;
pub const Style = @import("core/style.zig").Style;

// Theme definition: roles, palette, component tokens
pub const SemanticRole = @import("definition.zig").SemanticRole;
pub const Palette = @import("definition.zig").Palette;
pub const StyleRef = @import("definition.zig").StyleRef;
pub const PromptTheme = @import("definition.zig").PromptTheme;
pub const ProgressTheme = @import("definition.zig").ProgressTheme;
pub const SurfaceTheme = @import("definition.zig").SurfaceTheme;
pub const Glyph = @import("definition.zig").Glyph;
pub const Glyphs = @import("definition.zig").Glyphs;
pub const Theme = @import("definition.zig").Theme;
pub const default_theme = @import("definition.zig").default_theme;
pub const appTheme = @import("definition.zig").appTheme;
pub const ThemeContext = @import("definition.zig").ThemeContext;

// Terminal detection and capability management
pub const TerminalCapability = @import("detection/capability.zig").TerminalCapability;
pub const Capabilities = @import("detection/capability.zig").Capabilities;

// Main API
pub const Styled = @import("api/fluent.zig").Styled;
pub const styled = @import("api/fluent.zig").styled;

// Import all submodule tests to run them together
test {
    std.testing.refAllDecls(@import("core/color.zig"));
    std.testing.refAllDecls(@import("core/style.zig"));
    std.testing.refAllDecls(@import("detection/capability.zig"));
    std.testing.refAllDecls(@import("definition.zig"));
    std.testing.refAllDecls(@import("api/fluent.zig"));
    std.testing.refAllDecls(@import("integration_test.zig"));
}
