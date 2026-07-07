/// Semantic roles for theming
pub const SemanticRole = enum {
    // Core 5 - Most common CLI use cases
    success, // Operations that succeeded (green-ish)
    err, // Critical failures (red-ish) - 'error' is reserved
    warning, // Caution, deprecation (yellow-ish)
    info, // General information (blue-ish)
    muted, // Less important text (dimmed)

    // Extended CLI-specific roles
    command, // Commands being executed (e.g., "git commit")
    flag, // Command flags and options (e.g., "--verbose")
    path, // File paths and directories
    value, // User input, config values
    code, // Inline code snippets
    header, // Section headers, titles
    link, // URLs, clickable items

    // Additional roles for comprehensive coverage
    primary, // Main content, most important
    secondary, // Supporting text, descriptions
    accent, // Brand highlights, emphasis

    /// Get the style attributes for this semantic role
    /// Some roles may want bold, italic, etc. by default
    pub fn getDefaultStyle(self: SemanticRole) struct { bold: bool = false, italic: bool = false, dim: bool = false } {
        return switch (self) {
            .success, .err => .{ .bold = true },
            .warning => .{ .bold = true },
            .info => .{ .bold = true },
            .header => .{ .bold = true },
            .muted => .{ .dim = true },
            .link => .{ .italic = true },
            else => .{},
        };
    }
};
