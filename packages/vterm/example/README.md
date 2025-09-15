# VTerm Example - Testing CLI Applications

This example demonstrates how to use VTerm to test command-line interface (CLI) applications with proper terminal emulation.

## Overview

The example includes:
- `src/main.zig` - A demo CLI application with colored output, ANSI codes, and various commands
- `tests/cli_test.zig` - Comprehensive tests using VTerm's testing API

## Features Demonstrated

### CLI Application Features
- Colored help output with ANSI escape codes
- Multiple commands (help, version, list, status)
- Command-line argument parsing
- Screen clearing and cursor positioning
- Status indicators with colors (green/yellow/red)

### VTerm Testing Features

#### Basic API
- `containsText()` - Search for text anywhere in the terminal
- `cursorAt()` - Verify cursor position
- `snapshot()` - Capture complete terminal state
- `getAllText()` - Extract all terminal content as text
- `getLine()` - Extract specific lines
- `expectOutput()` - Helper for comparing expected output

#### Advanced Features (NEW!)
- **Attribute Testing**:
  - `hasAttribute(x, y, attr)` - Test bold, italic, underline at specific positions
  - `getTextColor(x, y)` / `getBackgroundColor(x, y)` - Verify text colors
- **Pattern Matching**:
  - `containsPattern(pattern)` - Support wildcards (`*`, `?`) and regex-like patterns (`.*`)
  - `findPattern(allocator, pattern)` - Find and return positions of matches
  - `containsTextIgnoreCase(text)` - Case-insensitive text search
- **Region Testing**:
  - `expectRegionEquals(x, y, w, h, expected)` - Test rectangular areas
  - `containsTextInRegion(text, x, y, w, h)` - Search within specific regions
- **Terminal Comparison**:
  - `diff(other, allocator)` - Compare two terminal states and find differences

## Building and Running

### Build the CLI application:
```bash
cd example
zig build
```

### Run the CLI:
```bash
./zig-out/bin/demo-cli help
./zig-out/bin/demo-cli version
./zig-out/bin/demo-cli list
./zig-out/bin/demo-cli list -v
./zig-out/bin/demo-cli status
```

### Run the tests:
```bash
zig build test
```

## Test Examples

### Testing Help Output
```zig
test "help command displays usage information" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();
    
    try simulateCliOutput(&term, &.{"help"});
    
    // Verify help sections are present
    try testing.expect(term.containsText("USAGE:"));
    try testing.expect(term.containsText("COMMANDS:"));
    try testing.expect(term.containsText("OPTIONS:"));
}
```

### Testing Screen Clearing
```zig
test "status command clears screen" {
    var term = try VTerm.init(testing.allocator, 80, 24);
    defer term.deinit();
    
    // Put initial content
    term.write("Initial content\n");
    
    // Run status command (which clears screen)
    try simulateCliOutput(&term, &.{"status"});
    
    // Initial content should be gone
    try testing.expect(!term.containsText("Initial content"));
}
```

### Testing Cursor Position
```zig
test "cursor position after output" {
    var term = try VTerm.init(testing.allocator, 40, 10);
    defer term.deinit();
    
    term.write("Hello");
    try testing.expect(term.cursorAt(5, 0));
    
    term.write("\x1b[5;10H"); // Move to row 5, col 10
    try testing.expect(term.cursorAt(9, 4)); // 0-indexed
}
```

## Key Testing Patterns

1. **Initialize Terminal**: Create a VTerm with appropriate dimensions
2. **Simulate Output**: Write CLI output to the terminal
3. **Assert Content**: Use VTerm's testing API to verify output
4. **Clean Up**: Always call `defer term.deinit()` for proper cleanup

## Benefits

- **Accurate Testing**: Test exactly what users see, including colors and formatting
- **Position Testing**: Verify cursor positioning and screen layout
- **ANSI Support**: Properly handle escape sequences and terminal control codes
- **Memory Safe**: Built-in memory management with proper cleanup

This example shows how VTerm makes it easy to write comprehensive tests for CLI applications that would otherwise be difficult to test properly.