//! The theme definition: semantic roles, the palette, component tokens, and
//! the app-level Theme aggregate.
//!
//! A `Theme` is defined once per CLI and describes how the app looks
//! everywhere: the palette maps semantic roles to styles, and component
//! tokens (prompts, progress) reference those roles by default so a palette
//! change flows through the whole app.

const std = @import("std");
const Style = @import("core/style.zig").Style;
const Capabilities = @import("detection/capability.zig").Capabilities;
const TerminalCapability = @import("detection/capability.zig").TerminalCapability;

/// Semantic roles for theming — style output by meaning, not by color.
pub const SemanticRole = enum {
    // Core 5 - most common CLI use cases
    success, // Operations that succeeded
    err, // Critical failures - 'error' is reserved
    warning, // Caution, deprecation
    info, // General information
    muted, // Less important text

    // CLI-specific roles
    command, // Commands being executed (e.g., "git commit")
    flag, // Command flags and options (e.g., "--verbose")
    path, // File paths and directories
    value, // User input, config values
    code, // Inline code snippets
    header, // Section headers, titles
    link, // URLs, clickable items

    // Brand highlight — the role component tokens reference by default
    accent,
};

/// Maps every semantic role to a complete Style (color and attributes).
/// The field defaults are the single source of truth for the default look.
pub const Palette = struct {
    success: Style = .{ .foreground = .{ .rgb = .{ .r = 76, .g = 217, .b = 100 } }, .bold = true },
    err: Style = .{ .foreground = .{ .rgb = .{ .r = 255, .g = 105, .b = 97 } }, .bold = true },
    warning: Style = .{ .foreground = .{ .rgb = .{ .r = 255, .g = 206, .b = 84 } }, .bold = true },
    info: Style = .{ .foreground = .{ .rgb = .{ .r = 116, .g = 169, .b = 250 } }, .bold = true },
    muted: Style = .{ .foreground = .{ .rgb = .{ .r = 156, .g = 163, .b = 175 } }, .dim = true },
    command: Style = .{ .foreground = .{ .rgb = .{ .r = 64, .g = 224, .b = 208 } } },
    flag: Style = .{ .foreground = .{ .rgb = .{ .r = 218, .g = 112, .b = 214 } } },
    path: Style = .{ .foreground = .{ .rgb = .{ .r = 100, .g = 221, .b = 221 } } },
    value: Style = .{ .foreground = .{ .rgb = .{ .r = 124, .g = 252, .b = 0 } } },
    code: Style = .{ .foreground = .{ .rgb = .{ .r = 168, .g = 136, .b = 248 } } },
    header: Style = .{ .foreground = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } }, .bold = true },
    link: Style = .{ .foreground = .{ .rgb = .{ .r = 135, .g = 206, .b = 250 } }, .italic = true },
    accent: Style = .{ .foreground = .{ .rgb = .{ .r = 0, .g = 255, .b = 255 } } },

    pub fn get(self: Palette, role: SemanticRole) Style {
        return switch (role) {
            inline else => |r| @field(self, @tagName(r)),
        };
    }
};

/// Reference to a style: either a semantic role resolved through the palette,
/// or a literal style.
pub const StyleRef = union(enum) {
    role: SemanticRole,
    style: Style,

    pub fn resolve(self: StyleRef, palette: Palette) Style {
        return switch (self) {
            .role => |r| palette.get(r),
            .style => |s| s,
        };
    }
};

/// Component tokens for interactive prompts (consumed by the prompts package).
pub const PromptTheme = struct {
    /// The selection cursor glyph
    cursor: StyleRef = .{ .role = .accent },
    /// The currently selected item
    selected: StyleRef = .{ .role = .accent },
    /// The checked marker in multi-select
    marker: StyleRef = .{ .role = .success },
    /// Placeholder and hint text ("type to filter", "no matches", ...)
    hint: StyleRef = .{ .role = .muted },
};

/// Component tokens for spinners and progress bars (consumed by the progress package).
pub const ProgressTheme = struct {
    /// The animated spinner frame
    spinner: StyleRef = .{ .role = .accent },
    /// The filled portion of a progress bar
    bar_fill: StyleRef = .{ .role = .accent },
    /// The unfilled portion of a progress bar
    bar_empty: StyleRef = .{ .role = .muted },
};

/// A complete CLI theme: one place to define how an app looks everywhere.
pub const Theme = struct {
    palette: Palette = .{},
    prompts: PromptTheme = .{},
    progress: ProgressTheme = .{},
};

pub const default_theme: Theme = .{};

/// Runtime handle pairing a Theme with detected terminal capabilities.
/// This is what render paths consume: it answers both "what does this role
/// look like" and "what can this terminal display".
pub const ThemeContext = struct {
    theme: *const Theme = &default_theme,
    caps: Capabilities,

    /// Resolve a semantic role to its style in the active palette
    pub fn resolve(self: ThemeContext, role: SemanticRole) Style {
        return self.theme.palette.get(role);
    }

    /// The effective terminal capability (no_color when color is disabled)
    pub fn capability(self: ThemeContext) TerminalCapability {
        return self.caps.getCapability();
    }
};

const testing = std.testing;

test "palette get returns the field for every role" {
    const palette = Palette{};
    inline for (@typeInfo(SemanticRole).@"enum".fields) |field| {
        const role = @field(SemanticRole, field.name);
        const style = palette.get(role);
        try testing.expect(std.meta.eql(style, @field(palette, field.name)));
        try testing.expect(style.foreground != null);
    }
}

test "custom palette overrides resolve through StyleRef and ThemeContext" {
    const custom = Theme{
        .palette = .{ .accent = .{ .foreground = .{ .rgb = .{ .r = 250, .g = 100, .b = 0 } } } },
    };

    // StyleRef role resolution follows the palette
    const ref = StyleRef{ .role = .accent };
    const resolved = ref.resolve(custom.palette);
    try testing.expect(std.meta.eql(resolved, custom.palette.accent));

    // Literal StyleRef ignores the palette
    const literal = StyleRef{ .style = .{ .bold = true } };
    try testing.expect(literal.resolve(custom.palette).bold);

    // ThemeContext resolves through its theme
    const ctx = ThemeContext{
        .theme = &custom,
        .caps = .{ .capability = .true_color, .is_tty = true, .color_enabled = true },
    };
    try testing.expect(std.meta.eql(ctx.resolve(.accent), custom.palette.accent));
}

test "component tokens default to role references" {
    const theme = Theme{};
    const spinner = theme.progress.spinner.resolve(theme.palette);
    try testing.expect(std.meta.eql(spinner, theme.palette.accent));
    const marker = theme.prompts.marker.resolve(theme.palette);
    try testing.expect(std.meta.eql(marker, theme.palette.success));
}

test "ThemeContext capability honors color_enabled" {
    const ctx = ThemeContext{
        .caps = .{ .capability = .true_color, .is_tty = false, .color_enabled = false },
    };
    try testing.expect(ctx.capability() == .no_color);
}
