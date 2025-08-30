const Color = @import("../core/color.zig").Color;

/// Semantic roles for theming
pub const SemanticRole = enum {
    // Core 5 - Most common CLI use cases
    success,    // Operations that succeeded (green-ish)
    err,        // Critical failures (red-ish) - 'error' is reserved
    warning,    // Caution, deprecation (yellow-ish)
    info,       // General information (blue-ish)
    muted,      // Less important text (dimmed)
    
    // Extended CLI-specific roles
    command,    // Commands being executed (e.g., "git commit")
    flag,       // Command flags and options (e.g., "--verbose")
    path,       // File paths and directories
    value,      // User input, config values
    header,     // Section headers, titles
    link,       // URLs, clickable items
    
    // Additional roles for comprehensive coverage
    primary,    // Main content, most important
    secondary,  // Supporting text, descriptions
    accent,     // Brand highlights, emphasis
    
    /// Get the default color for this semantic role
    /// This is a simple mapping for now, will become adaptive later
    pub fn getDefaultColor(self: SemanticRole) Color {
        return switch (self) {
            .success => .green,
            .err => .red,
            .warning => .yellow,
            .info => .blue,
            .muted => .bright_black,  // Gray
            
            .command => .bright_cyan,
            .flag => .bright_magenta,
            .path => .cyan,
            .value => .bright_green,
            .header => .bright_white,
            .link => .bright_blue,
            
            .primary => .white,
            .secondary => .bright_white,
            .accent => .bright_cyan,
        };
    }
    
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

