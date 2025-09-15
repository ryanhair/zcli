# VTerm Future Enhancements

This document outlines potential improvements and additions to VTerm, prioritized by usefulness for testing CLI and TUI applications.

## High Priority - Testing API Improvements

### Advanced Text Search

```zig
// Find text with regex support
pub fn containsPattern(self: *VTerm, pattern: []const u8) bool
pub fn findPattern(self: *VTerm, allocator: Allocator, pattern: []const u8) ![]Position

// Case-insensitive search
pub fn containsTextIgnoreCase(self: *VTerm, text: []const u8) bool

// Search within specific regions
pub fn containsTextInRegion(self: *VTerm, text: []const u8, x1: u16, y1: u16, x2: u16, y2: u16) bool
```

### Attribute Testing

```zig
// Test text formatting at specific positions
pub fn hasAttribute(self: *VTerm, x: u16, y: u16, attr: TextAttribute) bool
pub fn getTextColor(self: *VTerm, x: u16, y: u16) Color
pub fn getBackgroundColor(self: *VTerm, x: u16, y: u16) Color

// Find text with specific attributes
pub fn findTextWithColor(self: *VTerm, text: []const u8, color: Color) ?Position
pub fn findBoldText(self: *VTerm, text: []const u8) ?Position
```

### Screen Comparison

```zig
// Compare two terminal states
pub fn diff(self: *VTerm, other: *VTerm, allocator: Allocator) !TerminalDiff
pub fn expectSameAs(self: *VTerm, other: *VTerm) !void

// Visual rectangle comparison for TUI layouts
pub fn expectRegionEquals(self: *VTerm, x: u16, y: u16, width: u16, height: u16, expected: []const u8) !void
```

## Medium Priority - Terminal Behavior

### Scrolling Support

```zig
// Essential for full terminal emulation
pub fn scroll(self: *VTerm, lines: i16) void // positive = up, negative = down
pub fn getScrollbackLine(self: *VTerm, allocator: Allocator, line_offset: i16) ![]u8
pub fn getScrollPosition(self: *VTerm) i16
```

### Alternative Screen Buffer

```zig
// Support for applications that switch to alt screen (like vim, less)
pub fn switchToAltScreen(self: *VTerm) void
pub fn switchToMainScreen(self: *VTerm) void
pub fn isInAltScreen(self: *VTerm) bool
```

### Tab Support

```zig
// Handle tab characters and tab stops
pub fn setTabStop(self: *VTerm, x: u16) void
pub fn clearTabStop(self: *VTerm, x: u16) void
pub fn nextTabStop(self: *VTerm) u16
pub fn expandTabs(text: []const u8, tab_width: u8) []u8 // utility function
```

## Medium Priority - Testing Utilities

### Input Simulation

```zig
// Simulate user input for interactive testing
pub fn sendKey(self: *VTerm, key: Key) void
pub fn sendKeys(self: *VTerm, keys: []const Key) void
pub fn typeString(self: *VTerm, text: []const u8) void

// Mouse input simulation
pub fn clickAt(self: *VTerm, x: u16, y: u16, button: MouseButton) void
```

### Animation Testing

```zig
// For testing animated CLIs or progress bars
pub const FrameCapture = struct {
    timestamp: u64,
    snapshot: Snapshot,
};

pub fn startRecording(self: *VTerm) void
pub fn stopRecording(self: *VTerm, allocator: Allocator) ![]FrameCapture
pub fn expectAnimationFrames(self: *VTerm, expected_frames: []const []const u8) !void
```

### Content Extraction Improvements

```zig
// Get text without formatting/ANSI codes
pub fn getPlainText(self: *VTerm, allocator: Allocator) ![]u8
pub fn getLineRange(self: *VTerm, allocator: Allocator, start_line: u16, end_line: u16) ![]u8

// Extract formatted text with style information
pub fn getStyledText(self: *VTerm, allocator: Allocator) !StyledText
```

## Lower Priority - Advanced Features

### Performance Optimizations

```zig
// For testing large outputs or long-running applications
pub fn resizeBuffer(self: *VTerm, new_width: u16, new_height: u16) !void
pub fn setMaxScrollback(self: *VTerm, max_lines: u32) void

// Batch operations for efficiency
pub fn writeBatch(self: *VTerm, texts: []const []const u8) void
```

### Extended ANSI Support

```zig
// More complete ANSI escape sequence support
// - 256-color support
// - True color (24-bit) support
// - Extended text attributes (strikethrough, etc.)
// - Window title sequences
// - Cursor shape changes
```

### Debugging and Introspection

```zig
// Debug helpers for test development
pub fn dumpScreen(self: *VTerm, writer: anytype) !void
pub fn dumpCells(self: *VTerm, writer: anytype) !void
pub fn getParseHistory(self: *VTerm) []ParseEvent // Show what ANSI sequences were processed

// Performance metrics
pub fn getStats(self: *VTerm) TerminalStats
```

## Integration Helpers

### Framework Integration

```zig
// Easy integration with testing frameworks
pub fn expectOutputMatches(input: []const u8, expected_patterns: []const []const u8) !void
pub fn expectNoAnsiErrors(input: []const u8) !void

// Zinc framework integration helpers
pub fn renderZincComponent(self: *VTerm, component: ZincComponent) !void
pub fn expectZincLayout(self: *VTerm, expected_layout: ZincLayout) !void
```

### Child Process Helpers

```zig
// Utilities for testing actual CLI processes
pub fn captureProcessOutput(allocator: Allocator, argv: []const []const u8) !ProcessCapture
pub fn testCommandOutput(allocator: Allocator, argv: []const []const u8, expectations: []const Expectation) !void
```

## Implementation Priority

1. **Phase 5 (Next)**: Advanced text search and attribute testing - these would immediately improve test quality
2. **Phase 6**: Scrolling and alt screen support - needed for testing more complex TUIs
3. **Phase 7**: Input simulation - enables testing interactive applications
4. **Phase 8**: Performance and debugging tools - polish for production use

## Design Principles for Future Features

- **Testing-First**: Every feature should make testing easier or more accurate
- **Memory Safe**: All allocations must be properly managed
- **Zero Dependencies**: Keep VTerm self-contained
- **Simple API**: Complex terminal behavior should have simple test interfaces
- **Real-World Focus**: Prioritize features needed by actual CLI/TUI applications

## Other possible future ideas

- Unicode combining characters
- Double-width characters (CJK)
- Complex scrolling regions
- Mouse input (can add later if needed)
- Comprehensive error recovery
- Performance optimization beyond basic efficiency

## Non-Goals

- **Full Terminal Emulator**: VTerm is for testing, not daily terminal use
- **Performance**: Optimize for test clarity over raw speed
- **Legacy Support**: Focus on modern ANSI sequences, not historical terminals
- **GUI Features**: Stay focused on text-mode terminal behavior

This roadmap focuses on making VTerm the best possible tool for testing terminal applications in the Zig ecosystem.
