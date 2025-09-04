# ZTheme Demo CLI

A comprehensive demonstration of the ZTheme terminal styling library for Zig.

## Features Showcased

This demo application demonstrates all major ZTheme capabilities:

- **Terminal Capability Detection**: Automatic detection of color support levels
- **Basic ANSI Colors**: Standard 16-color palette (black, red, green, etc.)
- **Bright Colors**: Extended 16-color palette with bright variants
- **Advanced Colors**: RGB, hex, and 256-color palette support
- **Text Styling**: Bold, italic, underline, dim, strikethrough
- **Background Colors**: Background color styling with foreground combinations
- **Complex Styling**: Chained style combinations for rich formatting
- **Practical Examples**: Real-world CLI patterns like progress bars and syntax highlighting
- **Graceful Degradation**: Automatic fallback for limited terminals

## Usage

```bash
# Build the demo
zig build

# Run with auto-detection
./zig-out/bin/ztheme-demo

# Force color output (useful for piping or CI)
./zig-out/bin/ztheme-demo --force-color

# Test specific capability levels
./zig-out/bin/ztheme-demo --ansi-16      # 16-color mode
./zig-out/bin/ztheme-demo --ansi-256     # 256-color mode  
./zig-out/bin/ztheme-demo --true-color   # 24-bit RGB mode
./zig-out/bin/ztheme-demo --no-color     # No color mode

# Show help
./zig-out/bin/ztheme-demo --help
```

## Output Examples

### Auto-Detection (No TTY)
When run in a non-TTY environment (like CI or piped output), ZTheme automatically detects this and disables color output for maximum compatibility.

### Forced Color Mode
Use `--force-color` to override TTY detection and see the full color output:

```bash
./zig-out/bin/ztheme-demo --force-color | less -R
```

### Capability Testing
Different `--ansi-*` flags let you test how your styling looks across different terminal capability levels, ensuring your application works everywhere from basic terminals to modern RGB-capable ones.

## ZTheme Library Features Demonstrated

- **Zero-Cost Abstractions**: All styling compiled at compile-time
- **Type Safety**: Generic `Themed(T)` interface works with any content type
- **Fluent API**: Intuitive chaining like `.red().bold().underline()`
- **Platform Detection**: Windows/Unix/macOS terminal capability detection
- **Memory Safety**: No allocations in hot paths, optional allocator for convenience methods
- **Comprehensive Testing**: 33 tests covering all functionality

## Integration Example

The demo shows how easy it is to integrate ZTheme into any CLI application:

```zig
const ztheme = @import("ztheme");

pub fn main() !void {
    const theme_ctx = ztheme.Theme.init();
    
    // Simple styling
    try ztheme.theme("Error:").red().bold().render(stdout, &theme_ctx);
    
    // Complex combinations
    try ztheme.theme("SUCCESS").brightGreen().onBlack().bold().render(stdout, &theme_ctx);
    
    // RGB colors
    try ztheme.theme("Custom").rgb(255, 100, 50).render(stdout, &theme_ctx);
}
```

This demonstrates the power and ease of use of the ZTheme library for creating beautiful, accessible CLI applications in Zig.