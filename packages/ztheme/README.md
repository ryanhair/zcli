# ZTheme

A powerful, zero-cost CLI theming system for Zig. ZTheme provides compile-time style generation, runtime terminal capability detection, and an intuitive fluent API for creating beautiful CLI output.

## Features

- **Fluent API**: Intuitive method chaining like `.red().bold().underline()`
- **Zero-Cost Abstractions**: Styling computed at compile-time where possible
- **Terminal Capability Detection**: Automatic detection of color support (16-color, 256-color, true color)
- **Graceful Degradation**: Colors downgrade automatically for limited terminals
- **Semantic Theming**: Meaningful roles like `.success()`, `.error()`, `.warning()` with accessible colors
- **Type-Safe**: Generic `Themed(T)` interface works with any content type
- **Cross-Platform**: Windows, macOS, and Linux terminal detection

## Installation

Add ztheme to your `build.zig.zon`:

```zig
.dependencies = .{
    .ztheme = .{
        .path = "path/to/ztheme",
    },
},
```

In your `build.zig`:

```zig
const ztheme = b.dependency("ztheme", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("ztheme", ztheme.module("ztheme"));
```

## Quick Start

```zig
const std = @import("std");
const ztheme = @import("ztheme");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    // Initialize theme context with automatic detection
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const theme_ctx = ztheme.Theme.init(allocator);

    // Basic coloring
    try ztheme.theme("Error: ").red().bold().render(stdout, &theme_ctx);
    try stdout.print("Something went wrong\n", .{});

    // Semantic styling
    try ztheme.theme("Success!").success().render(stdout, &theme_ctx);
    try stdout.print("\n", .{});

    // RGB colors (true color terminals)
    try ztheme.theme("Custom color").rgb(255, 100, 50).render(stdout, &theme_ctx);
    try stdout.print("\n", .{});

    // Background colors
    try ztheme.theme("Highlighted").onYellow().black().render(stdout, &theme_ctx);
    try stdout.print("\n", .{});
}
```

## API Reference

### Creating Themed Content

```zig
const styled = ztheme.theme("Your text");
```

The `theme()` function accepts any content type and returns a `Themed(T)` wrapper.

### Foreground Colors

**Basic Colors (ANSI 16)**
```zig
.black()    .red()      .green()    .yellow()
.blue()     .magenta()  .cyan()     .white()
```

**Bright Colors**
```zig
.brightBlack()    .brightRed()      .brightGreen()    .brightYellow()
.brightBlue()     .brightMagenta()  .brightCyan()     .brightWhite()
```

**Convenience Aliases**
```zig
.gray()   // Same as .brightBlack()
.grey()   // Same as .brightBlack()
```

**Advanced Colors**
```zig
.rgb(255, 128, 64)    // True color RGB
.hex("#FF8040")       // Hex color (compile-time only)
.color256(196)        // 256-color palette index
```

### Background Colors

All foreground colors have background equivalents prefixed with `on`:

```zig
.onBlack()    .onRed()      .onGreen()    .onYellow()
.onBlue()     .onMagenta()  .onCyan()     .onWhite()
.onBrightBlack()  .onBrightRed()  // ... etc

.onRgb(100, 150, 200)   // RGB background
.onHex("#FF8040")       // Hex background (compile-time only)
.onColor256(42)         // 256-color background
```

### Text Styles

```zig
.bold()           // Bold text
.dim()            // Dimmed/faint text
.italic()         // Italic text
.underline()      // Underlined text
.strikethrough()  // Strikethrough text
```

### Semantic Styling

ZTheme includes carefully designed semantic colors for common CLI patterns:

**Core Roles**
```zig
.success()   // Green - successful operations
.err()       // Red - errors and failures
.warning()   // Yellow - warnings and cautions
.info()      // Blue - informational messages
.muted()     // Gray - less important text
```

**CLI-Specific Roles**
```zig
.command()   // Turquoise - command names
.flag()      // Orchid - flags and options
.path()      // Cyan - file paths
.value()     // Green - user input/values
.header()    // White - section headers
.link()      // Light blue - URLs
```

### Rendering

**Runtime Rendering**
```zig
// Render to any writer
try styled.render(writer, &theme_ctx);

// Get as allocated string
const str = try styled.toString(allocator, &theme_ctx);
defer allocator.free(str);
```

**Compile-Time Rendering**
```zig
const styled = comptime ztheme.theme("Optimized").red().bold();
try styled.renderComptime(writer, .ansi_16);
```

### Method Chaining

All methods return a new `Themed` instance, enabling fluent chaining:

```zig
const styled = ztheme.theme("Critical Error!")
    .brightRed()
    .onWhite()
    .bold()
    .underline();
```

### Utility Methods

```zig
.reset()                    // Remove all styling
.hasStyle()                 // Check if any styling is applied
.clone()                    // Clone the styled content
.withContent(new_content)   // New content with same styling
```

## Terminal Capability Detection

ZTheme automatically detects terminal capabilities:

```zig
const theme_ctx = ztheme.Theme.init(allocator);

// Check capabilities
if (theme_ctx.supportsColor()) { ... }
if (theme_ctx.supports256Color()) { ... }
if (theme_ctx.supportsTrueColor()) { ... }

// Get capability as string (for debugging)
std.debug.print("Terminal: {s}\n", .{theme_ctx.capabilityString()});
```

### Capability Levels

| Level | Description | Colors |
|-------|-------------|--------|
| `no_color` | No color support | Plain text only |
| `ansi_16` | Basic ANSI | 16 colors |
| `ansi_256` | Extended palette | 256 colors |
| `true_color` | Full RGB | 16.7 million colors |

### Manual Capability Override

```zig
// Force specific capability
const theme_ctx = ztheme.Theme.initWithCapability(.true_color);

// Force color output (override TTY detection)
const theme_ctx = ztheme.Theme.initForced(allocator, true);
```

### Environment Detection

ZTheme respects standard environment variables:

- `NO_COLOR` - Disables all color output
- `COLORTERM=truecolor` or `COLORTERM=24bit` - Enables true color
- `TERM` - Terminal type detection (xterm-256color, etc.)
- `TERM_PROGRAM` - Specific terminal detection (iTerm2, VS Code, etc.)
- `WT_SESSION` - Windows Terminal detection

## Color Conversion

ZTheme automatically converts colors for terminal capability:

- True color terminals: Full RGB values
- 256-color terminals: Nearest palette match
- 16-color terminals: Smart approximation to closest ANSI color

```zig
// This RGB color will automatically adapt:
// - True color: exact RGB(255, 100, 50)
// - 256-color: closest palette index
// - 16-color: approximated to red or yellow
try ztheme.theme("Adaptive").rgb(255, 100, 50).render(writer, &theme_ctx);
```

## Semantic Color Palette

The semantic colors use carefully designed RGB values for accessibility:

| Role | RGB | Description |
|------|-----|-------------|
| success | `76, 217, 100` | Bright green |
| err | `255, 105, 97` | Coral red |
| warning | `255, 206, 84` | Bright amber |
| info | `116, 169, 250` | Light blue |
| muted | `156, 163, 175` | Subtle gray |
| command | `64, 224, 208` | Turquoise |
| flag | `218, 112, 214` | Orchid |
| path | `100, 221, 221` | Light cyan |
| value | `124, 252, 0` | Lawn green |
| header | `255, 255, 255` | White |
| link | `135, 206, 250` | Light sky blue |

## Testing

Run the test suite:

```bash
cd packages/ztheme
zig build test
```

## Examples

See [examples/ztheme](../../examples/ztheme) for a complete demo application showcasing all ZTheme features.

## License

MIT License - See LICENSE file for details.
