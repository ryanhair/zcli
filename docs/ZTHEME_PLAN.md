# ZTheme: A Powerful Zig CLI Theming System

## Executive Summary

ZTheme is a standalone, zero-cost theming system for Zig CLI applications that leverages compile-time computation, type safety, and intelligent capability detection. It provides developers with an intuitive API while generating optimized ANSI sequences at compile-time and gracefully degrading across terminal capabilities.

## Core Design Principles

### 1. Zero-Cost Abstractions Through Comptime
- All style definitions and escape sequences generated at compile-time
- No runtime overhead for style creation or validation
- Compile-time string interning for identical sequences
- Automatic dead code elimination for unused styles

### 2. Progressive Enhancement
- Graceful degradation from true color → 256-color → 16-color → no color
- Runtime capability detection with compile-time optimization preparation
- Automatic fallback sequences generated for each capability level

### 3. Developer-First API Design
- Fluent chaining for programmatic use: `text.red().bold().underline()`
- Markup strings for configuration: `"[red bold]Error:[/] Invalid input"`
- Type-safe style definitions with compile-time validation

### 4. Security by Design
- Automatic sanitization of user input
- Compile-time validation prevents malicious escape sequences
- Safe defaults with explicit opt-in for advanced features

## API Architecture

### Core Style Types

```zig
// Compile-time style definition
pub const Style = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    dim: bool = false,
    
    // Generate escape sequence at compile-time
    pub fn sequence(comptime self: @This()) []const u8 {
        return comptime buildEscapeSequence(self);
    }
    
    // Create new style with modifications
    pub fn with(comptime self: @This(), comptime modifications: anytype) Style {
        return comptime applyModifications(self, modifications);
    }
};

// Color system supporting all capability levels
pub const Color = union(enum) {
    // Basic 16 colors with named variants
    black, red, green, yellow, blue, magenta, cyan, white,
    bright_black, bright_red, bright_green, bright_yellow,
    bright_blue, bright_magenta, bright_cyan, bright_white,
    
    // 256-color palette index
    indexed: u8,
    
    // True color RGB
    rgb: struct { r: u8, g: u8, b: u8 },
    
    // Hex color (converted to RGB at compile-time)
    hex: []const u8,
    
    // Generate appropriate sequence for capability level
    pub fn sequence(self: Color, capability: TerminalCapability, foreground: bool) []const u8 {
        return switch (capability) {
            .no_color => "",
            .ansi_16 => self.toAnsi16Sequence(foreground),
            .ansi_256 => self.toAnsi256Sequence(foreground),
            .true_color => self.toTrueColorSequence(foreground),
        };
    }
    
    // Compile-time color space conversion
    pub fn toAnsi256(comptime self: Color) u8 {
        return switch (self) {
            .rgb => |rgb| comptime quantizeRgbTo256(rgb.r, rgb.g, rgb.b),
            .hex => |hex| comptime quantizeHexTo256(hex),
            .indexed => |idx| idx,
            else => comptime namedColorToIndex(self),
        };
    }
};
```

### Fluent API System

```zig
// Core theming interface that wraps any content type
pub fn Themed(comptime T: type) type {
    return struct {
        const Self = @This();
        content: T,
        style: Style = .{},
        
        // Color methods
        pub fn red(self: Self) Self {
            return self.withColor(.red);
        }
        
        pub fn green(self: Self) Self {
            return self.withColor(.green);
        }
        
        pub fn rgb(self: Self, r: u8, g: u8, b: u8) Self {
            return self.withColor(.{ .rgb = .{ .r = r, .g = g, .b = b } });
        }
        
        pub fn hex(comptime self: Self, comptime color: []const u8) Self {
            return self.withColor(.{ .hex = color });
        }
        
        // Style methods
        pub fn bold(self: Self) Self {
            return self.withStyle(.{ .bold = true });
        }
        
        pub fn italic(self: Self) Self {
            return self.withStyle(.{ .italic = true });
        }
        
        pub fn underline(self: Self) Self {
            return self.withStyle(.{ .underline = true });
        }
        
        // Background methods
        pub fn onRed(self: Self) Self {
            return self.withBgColor(.red);
        }
        
        pub fn onRgb(self: Self, r: u8, g: u8, b: u8) Self {
            return self.withBgColor(.{ .rgb = .{ .r = r, .g = g, .b = b } });
        }
        
        // Internal style application
        fn withColor(self: Self, color: Color) Self {
            var new_style = self.style;
            new_style.fg = color;
            return .{ .content = self.content, .style = new_style };
        }
        
        fn withBgColor(self: Self, color: Color) Self {
            var new_style = self.style;
            new_style.bg = color;
            return .{ .content = self.content, .style = new_style };
        }
        
        fn withStyle(self: Self, style_mods: anytype) Self {
            return .{
                .content = self.content,
                .style = self.style.with(style_mods),
            };
        }
        
        // Render to writer with capability detection
        pub fn render(self: Self, writer: anytype, theme: *const Theme) !void {
            const capability = theme.getCapability();
            const start_seq = self.style.sequenceForCapability(capability);
            const reset_seq = comptime "\x1B[0m";
            
            if (start_seq.len > 0) {
                try writer.writeAll(start_seq);
            }
            
            switch (@TypeOf(self.content)) {
                []const u8 => try writer.writeAll(self.content),
                else => try writer.print("{}", .{self.content}),
            }
            
            if (start_seq.len > 0) {
                try writer.writeAll(reset_seq);
            }
        }
    };
}

// Convenience function to create themed content
pub fn theme(content: anytype) Themed(@TypeOf(content)) {
    return .{ .content = content };
}
```

### Markup String System

```zig
// Parse markup strings at compile-time
pub fn parseMarkup(comptime markup: []const u8) MarkupTemplate {
    return comptime parseMarkupImpl(markup);
}

const MarkupTemplate = struct {
    segments: []const MarkupSegment,
    
    pub fn render(comptime self: @This(), args: anytype, writer: anytype, theme_ctx: *const Theme) !void {
        inline for (self.segments) |segment| {
            switch (segment.type) {
                .text => try writer.writeAll(segment.content),
                .styled => {
                    const start_seq = segment.style.sequenceForCapability(theme_ctx.getCapability());
                    if (start_seq.len > 0) try writer.writeAll(start_seq);
                    try writer.writeAll(segment.content);
                    if (start_seq.len > 0) try writer.writeAll("\x1B[0m");
                },
                .placeholder => {
                    const value = @field(args, segment.content);
                    try writer.print("{}", .{value});
                },
            }
        }
    }
};

// Usage example:
// const template = comptime parseMarkup("[red bold]Error:[/] {message} in [blue]{file}[/]");
// try template.render(.{ .message = "Invalid syntax", .file = "config.zig" }, writer, &theme);
```

## Terminal Capability Detection

### Runtime Detection System

```zig
pub const TerminalCapability = enum {
    no_color,
    ansi_16,
    ansi_256,
    true_color,
    
    pub fn detect() TerminalCapability {
        // Priority: FORCE_COLOR > NO_COLOR > COLORTERM > TERM > TTY detection
        if (std.process.getEnvVarOwned(allocator, "NO_COLOR")) |_| {
            return .no_color;
        }
        
        if (std.process.getEnvVarOwned(allocator, "FORCE_COLOR")) |force| {
            return switch (force[0]) {
                '0' => .no_color,
                '1' => .ansi_16,
                '2' => .ansi_256,
                '3' => .true_color,
                else => .ansi_16,
            };
        }
        
        if (std.process.getEnvVarOwned(allocator, "COLORTERM")) |colorterm| {
            if (std.mem.eql(u8, colorterm, "truecolor") or 
                std.mem.eql(u8, colorterm, "24bit")) {
                return .true_color;
            }
        }
        
        // Platform-specific detection
        return detectPlatformCapabilities();
    }
};

pub const Theme = struct {
    capability: TerminalCapability,
    is_tty: bool,
    color_enabled: bool,
    
    pub fn init() Theme {
        const capability = TerminalCapability.detect();
        const is_tty = std.io.getStdOut().isTty();
        
        return .{
            .capability = capability,
            .is_tty = is_tty,
            .color_enabled = capability != .no_color and is_tty,
        };
    }
    
    pub fn getCapability(self: *const Theme) TerminalCapability {
        return if (self.color_enabled) self.capability else .no_color;
    }
};
```

### Platform-Specific Handling

```zig
fn detectPlatformCapabilities() TerminalCapability {
    if (builtin.os.tag == .windows) {
        return detectWindowsCapabilities();
    } else {
        return detectUnixCapabilities();
    }
}

fn detectWindowsCapabilities() TerminalCapability {
    // Check for Windows Terminal
    if (std.process.getEnvVarOwned(allocator, "WT_SESSION")) |_| {
        return .true_color;
    }
    
    // Check for ConPTY support
    if (enableVirtualTerminalProcessing()) {
        return .ansi_256;
    }
    
    return .no_color;
}

fn detectUnixCapabilities() TerminalCapability {
    if (std.process.getEnvVarOwned(allocator, "TERM")) |term| {
        if (std.mem.indexOf(u8, term, "256color")) |_| {
            return .ansi_256;
        }
        if (std.mem.indexOf(u8, term, "color")) |_| {
            return .ansi_16;
        }
    }
    
    return .ansi_16; // Conservative default for Unix
}
```

## Advanced Features

### Predefined Semantic Styles

```zig
// Semantic styles with automatic theme inheritance
pub const SemanticStyles = struct {
    pub const error_style = Style{
        .fg = .red,
        .bold = true,
    };
    
    pub const warning_style = Style{
        .fg = .yellow,
        .bold = true,
    };
    
    pub const success_style = Style{
        .fg = .green,
        .bold = true,
    };
    
    pub const info_style = Style{
        .fg = .blue,
    };
    
    pub const code_style = Style{
        .fg = .{ .rgb = .{ .r = 100, .g = 149, .b = 237 } },
        .bg = .{ .rgb = .{ .r = 40, .g = 44, .b = 52 } },
    };
    
    pub const highlight_style = Style{
        .bg = .yellow,
        .fg = .black,
    };
};

// Convenience functions
pub fn error_text(text: []const u8) Themed([]const u8) {
    return theme(text).red().bold();
}

pub fn success_text(text: []const u8) Themed([]const u8) {
    return theme(text).green().bold();
}

pub fn code_text(text: []const u8) Themed([]const u8) {
    return theme(text).rgb(100, 149, 237).onRgb(40, 44, 52);
}
```

### Progress and Animation Support

```zig
pub const ProgressBar = struct {
    width: u32,
    filled_style: Style,
    empty_style: Style,
    
    pub fn render(self: ProgressBar, progress: f32, writer: anytype, theme_ctx: *const Theme) !void {
        const filled_chars = @as(u32, @intFromFloat(progress * @as(f32, @floatFromInt(self.width))));
        const empty_chars = self.width - filled_chars;
        
        // Render filled portion
        if (filled_chars > 0) {
            const filled_seq = self.filled_style.sequenceForCapability(theme_ctx.getCapability());
            if (filled_seq.len > 0) try writer.writeAll(filled_seq);
            
            var i: u32 = 0;
            while (i < filled_chars) : (i += 1) {
                try writer.writeAll("█");
            }
            
            if (filled_seq.len > 0) try writer.writeAll("\x1B[0m");
        }
        
        // Render empty portion
        if (empty_chars > 0) {
            const empty_seq = self.empty_style.sequenceForCapability(theme_ctx.getCapability());
            if (empty_seq.len > 0) try writer.writeAll(empty_seq);
            
            var i: u32 = 0;
            while (i < empty_chars) : (i += 1) {
                try writer.writeAll("░");
            }
            
            if (empty_seq.len > 0) try writer.writeAll("\x1B[0m");
        }
    }
};
```

### Configuration System

```zig
// TOML-based theme configuration with compile-time parsing
const ThemeConfig = struct {
    colors: struct {
        primary: []const u8 = "#007acc",
        secondary: []const u8 = "#f0f0f0",
        error: []const u8 = "#e74c3c",
        warning: []const u8 = "#f39c12",
        success: []const u8 = "#27ae60",
    } = .{},
    
    styles: struct {
        bold_errors: bool = true,
        underline_links: bool = true,
        italic_emphasis: bool = false,
    } = .{},
    
    pub fn fromToml(comptime toml_content: []const u8) ThemeConfig {
        return comptime parseTomlConfig(toml_content);
    }
    
    pub fn createSemanticStyles(comptime self: @This()) type {
        return struct {
            pub const primary = Style{
                .fg = Color{ .hex = self.colors.primary },
            };
            
            pub const error_style = Style{
                .fg = Color{ .hex = self.colors.error },
                .bold = self.styles.bold_errors,
            };
            
            pub const warning = Style{
                .fg = Color{ .hex = self.colors.warning },
            };
            
            pub const success = Style{
                .fg = Color{ .hex = self.colors.success },
            };
        };
    }
};
```

## Implementation Plan

### Phase 1: Core Foundation (Week 1-2)
1. **Color System Implementation**
   - Basic Color enum with all variants
   - Compile-time color conversion functions
   - ANSI sequence generation for each capability level

2. **Style System**
   - Core Style struct with all properties
   - Compile-time sequence building
   - Style composition and modification functions

3. **Basic Theming Interface**
   - Simple theme() function
   - Basic color and style methods
   - Writer integration

### Phase 2: Capability Detection (Week 2-3)
1. **Terminal Detection**
   - Environment variable parsing
   - Platform-specific capability detection
   - TTY detection integration

2. **Runtime Theme Context**
   - Theme struct with capability management
   - Dynamic sequence selection
   - Performance optimization for disabled color output

### Phase 3: Advanced API (Week 3-4)
1. **Fluent Chaining System**
   - Complete Themed(T) implementation
   - All color and style methods
   - Generic content type support

2. **Markup String Parser**
   - Compile-time markup parsing
   - Template rendering system
   - Placeholder interpolation

### Phase 4: Extended Features (Week 4-5)
1. **Semantic Styles**
   - Predefined style library
   - Convenience functions
   - Theme inheritance system

2. **Configuration System**
   - TOML parsing integration
   - Custom theme creation
   - Validation and error handling

3. **Advanced Components**
   - Progress bar implementation
   - Animation support utilities
   - Layout helpers

### Phase 5: Integration & Polish (Week 5-6)
1. **ZCli Integration**
   - Plugin system integration
   - Help system theming
   - Error message styling

2. **Documentation & Examples**
   - API documentation
   - Usage examples
   - Migration guides

3. **Testing & Validation**
   - Cross-platform testing
   - Performance benchmarks
   - Security validation

## File Structure

```
src/ztheme/
├── core/
│   ├── color.zig          # Color types and conversions
│   ├── style.zig          # Style definitions and building
│   └── sequences.zig      # ANSI sequence generation
├── detection/
│   ├── capability.zig     # Terminal capability detection
│   ├── platform.zig       # Platform-specific detection
│   └── environment.zig    # Environment variable parsing
├── api/
│   ├── fluent.zig         # Fluent chaining interface
│   ├── markup.zig         # Markup string parsing
│   └── semantic.zig       # Semantic style definitions
├── config/
│   ├── parser.zig         # TOML configuration parsing
│   ├── validation.zig     # Theme validation
│   └── themes.zig         # Built-in theme definitions
├── components/
│   ├── progress.zig       # Progress bars and indicators
│   ├── tables.zig         # Table formatting
│   └── layout.zig         # Layout utilities
├── integration/
│   ├── zcli.zig          # ZCli-specific integration
│   └── plugin.zig        # Plugin system support
└── ztheme.zig            # Main public API
```

## Security Considerations

### Input Sanitization
- All user-provided content automatically sanitized
- Escape sequence validation at compile-time and runtime
- Safe defaults for all configuration options

### Memory Safety
- No dynamic allocations in hot paths
- Compile-time string interning
- Bounds checking for all array operations

### Attack Surface Minimization
- Minimal dependencies
- Conservative capability detection
- Explicit opt-in for advanced features

## Performance Characteristics

### Compile-Time Benefits
- Zero runtime cost for style definition
- Optimal escape sequence generation
- Dead code elimination for unused styles
- String literal interning

### Runtime Optimization
- Single write call per styled segment
- Capability-aware sequence selection
- Minimal branching in hot paths
- Buffer reuse strategies

## Integration with ZCli

ZTheme integrates seamlessly with ZCli through:

1. **Plugin System**: Automatic theming of help output, error messages, and command responses
2. **Configuration**: Theme selection through CLI options or config files
3. **Context Integration**: Theme context passed through ZCli's execution context
4. **Zero Integration Cost**: Optional dependency that adds no overhead when unused

## Conclusion

ZTheme provides a powerful, performant, and safe theming system for Zig CLI applications. By leveraging Zig's unique compile-time capabilities, it delivers zero-cost abstractions while maintaining excellent developer ergonomics. The progressive enhancement approach ensures compatibility across all terminal environments while providing rich styling for capable terminals.

The system's modular design allows for gradual adoption - developers can start with simple color functions and progressively adopt more advanced features as needed. The integration with ZCli provides a complete CLI development experience with beautiful, accessible output by default.