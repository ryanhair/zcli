# VTerm - Virtual Terminal Emulator for Testing

A lightweight virtual terminal emulator built in Zig, designed specifically for testing CLI and TUI applications with proper terminal behavior simulation.

## What is VTerm?

VTerm provides an in-memory terminal that accurately emulates real terminal behavior, including:
- ANSI escape sequence processing (colors, cursor movement, screen clearing)
- Text attributes (bold, italic, underline)
- Cursor positioning and tracking
- Fixed screen dimensions (no scrolling yet)
- UTF-8 character support

## Why Use VTerm?

Testing CLI applications is notoriously difficult because:
- Terminal output includes invisible escape sequences
- Colors and formatting are lost when capturing raw output
- Cursor positioning affects what users actually see
- Different terminals behave differently

VTerm solves this by providing a **controlled, predictable terminal environment** where you can:
- ✅ Test exactly what users see, including colors and formatting
- ✅ Verify cursor positioning and screen layout
- ✅ Assert on specific terminal regions
- ✅ Compare terminal states before/after operations
- ✅ Search for patterns with wildcards and regex-like matching

## Quick Start

```zig
const std = @import("std");
const testing = std.testing;
const VTerm = @import("vterm").VTerm;

test "basic terminal testing" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();
    
    // Simulate CLI output with colors
    term.write("\x1b[31mError:\x1b[0m Command failed\n");
    
    // Test what users actually see
    try testing.expect(term.containsText("Error: Command failed"));
    try testing.expectEqual(VTerm.Color.red, term.getTextColor(0, 0));
    try testing.expect(term.cursorAt(0, 1)); // Next line after newline
}
```

## Key Features

### Core Testing API
- `containsText()` - Search for text anywhere in terminal
- `cursorAt()` - Verify cursor position  
- `getAllText()` - Extract complete terminal content
- `snapshot()` - Capture terminal state for comparison

### Advanced Testing
- **Pattern Matching**: `containsPattern()` with wildcards (`*`, `?`) and regex-like patterns (`.*`)
- **Attribute Testing**: `hasAttribute()`, `getTextColor()`, `getBackgroundColor()`
- **Region Testing**: `expectRegionEquals()`, `containsTextInRegion()`
- **Terminal Comparison**: `diff()` to compare terminal states
- **Case Insensitive**: `containsTextIgnoreCase()`

## Use Cases

- **CLI Application Testing**: Verify help text, error messages, and command output
- **TUI Testing**: Test terminal user interfaces with complex layouts
- **Color/Formatting Verification**: Ensure proper use of colors and text attributes  
- **Cursor Behavior**: Test cursor positioning in interactive applications
- **Screen Layout**: Verify complex terminal layouts and box drawing

## Example Applications

See `example/` directory for a complete demonstration including:
- A demo CLI with colored output and multiple commands
- Comprehensive tests showing all VTerm capabilities
- Real-world testing patterns and best practices

## Integration

VTerm is designed to work seamlessly with Zig's built-in testing framework:

```zig
// In your build.zig
const vterm = b.dependency("vterm", .{});
exe.root_module.addImport("vterm", vterm.module("vterm"));

// In your tests
const VTerm = @import("vterm").VTerm;
```

VTerm makes CLI testing **reliable, comprehensive, and maintainable** by providing the terminal emulation accuracy that traditional output capturing cannot match.