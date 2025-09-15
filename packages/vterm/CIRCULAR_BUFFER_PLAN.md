# VTerm Circular Buffer with Scrollback - Design Plan

## Overview

Implement a circular buffer that maintains more lines than the visible viewport, enabling scrollback history while maintaining O(1) scroll performance.

## Architecture

```
┌──────────────────────────┐
│   Circular Buffer        │ ← Total capacity (e.g., 1000 lines)
│ ┌──────────────────────┐ │
│ │ Historical lines...  │ │ ← Scrollback history
│ │ Line -3              │ │
│ │ Line -2              │ │
│ │ Line -1              │ │
│ ├──────────────────────┤ │
│ │ Line 0  ← viewport   │ │ ← Visible viewport (e.g., 24 lines)
│ │ Line 1               │ │
│ │ ...                  │ │
│ │ Line 23              │ │
│ └──────────────────────┘ │
│   Future lines space...  │
└──────────────────────────┘
```

## Core Data Structure

```zig
pub const VTerm = struct {
    allocator: Allocator,
    
    // Circular buffer
    cells: []Cell,           // Total buffer (scrollback_lines * width)
    scrollback_lines: u16,   // Total lines in buffer (e.g., 1000)
    width: u16,              // Terminal width
    height: u16,             // Viewport height (visible lines, e.g., 24)
    
    // Circular buffer management
    buffer_start: u16,       // First line in circular buffer (wraps around)
    total_lines_written: u32, // Total lines ever written (for history tracking)
    
    // Viewport
    viewport_offset: i32,    // Offset from bottom (0 = bottom, negative = scrolled up)
    
    // Cursor (viewport-relative)
    cursor: Position,        // Relative to viewport, not buffer
    
    // ... other fields remain the same
};
```

## Key Concepts

### 1. Line Indexing
```zig
// Three coordinate systems:
// 1. Buffer index: Physical position in circular buffer (0..scrollback_lines-1)
// 2. Logical line: Line number since terminal started (0..total_lines_written)
// 3. Viewport position: Visible position on screen (0..height-1)

fn bufferLineIndex(self: *VTerm, logical_line: u32) u16 {
    // Map logical line to circular buffer position
    return @intCast((self.buffer_start + logical_line) % self.scrollback_lines);
}

fn viewportToBuffer(self: *VTerm, viewport_y: u16) ?u16 {
    // Convert viewport Y to buffer line index
    const logical_line = self.getBottomLine() - @as(u32, @intCast(self.height - 1 - viewport_y)) + self.viewport_offset;
    if (logical_line < 0 or logical_line >= self.total_lines_written) return null;
    return self.bufferLineIndex(@intCast(logical_line));
}

fn getBottomLine(self: *VTerm) u32 {
    // Get the logical line number at the bottom of viewport
    return @min(self.total_lines_written, self.scrollback_lines) - 1;
}
```

### 2. Cell Access with Viewport Translation
```zig
pub fn getCell(self: *VTerm, x: u16, y: u16) Cell {
    // x,y are viewport-relative
    const buffer_line = self.viewportToBuffer(y) orelse return Cell.default();
    const idx = @as(usize, buffer_line) * self.width + x;
    return self.cells[idx];
}

pub fn setCell(self: *VTerm, x: u16, y: u16, cell: Cell) void {
    // x,y are viewport-relative
    const buffer_line = self.viewportToBuffer(y) orelse return;
    const idx = @as(usize, buffer_line) * self.width + x;
    self.cells[idx] = cell;
}
```

### 3. Scrolling Operations
```zig
fn scrollUp(self: *VTerm) void {
    // O(1) - just update pointers
    self.total_lines_written += 1;
    
    // If we exceed buffer capacity, advance buffer start
    if (self.total_lines_written > self.scrollback_lines) {
        self.buffer_start = (self.buffer_start + 1) % self.scrollback_lines;
    }
    
    // Clear the new line
    const new_line = self.bufferLineIndex(self.total_lines_written - 1);
    const line_start = @as(usize, new_line) * self.width;
    for (line_start..line_start + self.width) |i| {
        self.cells[i] = Cell.default();
    }
}

pub fn scrollViewportUp(self: *VTerm, lines: u16) void {
    // Scroll viewport up in history (user scrollback)
    const max_scroll = @intCast(i32, self.total_lines_written - self.height);
    self.viewport_offset = @max(-max_scroll, self.viewport_offset - @as(i32, @intCast(lines)));
}

pub fn scrollViewportDown(self: *VTerm, lines: u16) void {
    // Scroll viewport down toward present
    self.viewport_offset = @min(0, self.viewport_offset + @as(i32, @intCast(lines)));
}

pub fn scrollToBottom(self: *VTerm) void {
    // Jump to bottom (present)
    self.viewport_offset = 0;
}
```

## API Changes

### New Public Methods
```zig
// Scrollback navigation
pub fn pageUp(self: *VTerm) void;
pub fn pageDown(self: *VTerm) void;
pub fn scrollToTop(self: *VTerm) void;
pub fn scrollToBottom(self: *VTerm) void;
pub fn getScrollbackPosition(self: *VTerm) ScrollPosition;

pub const ScrollPosition = struct {
    current_line: u32,    // Current viewport position in history
    total_lines: u32,     // Total lines in scrollback
    at_bottom: bool,      // Whether viewport is at bottom
};
```

### Modified Methods
All existing methods continue to work with viewport-relative coordinates:
- `write()` - Automatically scrolls to bottom when output occurs
- `getAllText()` - Returns only viewport content by default
- `containsText()` - Searches only visible viewport
- `snapshot()` - Captures viewport state

### New Optional Parameters
```zig
// Option to include scrollback in operations
pub fn getAllTextWithHistory(self: *VTerm, allocator: Allocator) ![]u8;
pub fn searchInHistory(self: *VTerm, text: []const u8) bool;
```

## Implementation Strategy

### Phase 1: Core Infrastructure
1. Modify VTerm struct for circular buffer
2. Implement line indexing functions
3. Update cell access methods with translation

### Phase 2: Basic Scrolling
1. Implement `scrollUp()` for automatic scrolling
2. Update cursor movement to trigger scrolls
3. Ensure all writes work with new system

### Phase 3: Scrollback Navigation
1. Add viewport scrolling methods
2. Implement page up/down
3. Add position tracking

### Phase 4: Testing
1. Test circular buffer wrapping
2. Test scrollback limits
3. Test viewport navigation
4. Test that existing features still work

## Memory Considerations

```zig
// Memory usage calculation
const memory_usage = scrollback_lines * width * @sizeOf(Cell);

// Example: 1000 lines × 80 columns × 8 bytes/cell = 640 KB
// Reasonable defaults:
const DEFAULT_SCROLLBACK = 1000;  // lines
const MAX_SCROLLBACK = 10000;     // lines
```

## Edge Cases to Handle

1. **Buffer Wrap**: When total_lines_written exceeds scrollback_lines
2. **Viewport Bounds**: Prevent scrolling beyond history limits
3. **Cursor During Scrollback**: Hide cursor when viewing history
4. **Write During Scrollback**: Auto-scroll to bottom on new output
5. **Clear Screen**: Should only clear viewport, not history
6. **Alternate Screen**: Should have separate buffer without scrollback

## Testing Examples

```zig
test "circular buffer wraps correctly" {
    var term = try VTerm.initWithScrollback(allocator, 10, 3, .{
        .scrollback_lines = 5,  // Only 5 lines total
    });
    defer term.deinit();
    
    // Write 7 lines (exceeds buffer)
    for (0..7) |i| {
        term.write(try std.fmt.allocPrint(allocator, "Line {}\n", .{i}));
    }
    
    // Lines 0-1 should be gone (overwritten)
    try testing.expect(!term.searchInHistory("Line 0"));
    try testing.expect(!term.searchInHistory("Line 1"));
    
    // Recent lines should be in scrollback
    try testing.expect(term.searchInHistory("Line 2"));
    try testing.expect(term.containsText("Line 6")); // Visible
}

test "viewport scrolling" {
    var term = try VTerm.initWithScrollback(allocator, 10, 3, .{
        .scrollback_lines = 100,
    });
    defer term.deinit();
    
    // Write 10 lines
    for (0..10) |i| {
        term.write(try std.fmt.allocPrint(allocator, "Line {}\n", .{i}));
    }
    
    // Should see lines 7,8,9 (last 3)
    try testing.expect(term.containsText("Line 9"));
    
    // Scroll up 3 lines
    term.scrollViewportUp(3);
    
    // Should now see lines 4,5,6
    try testing.expect(term.containsText("Line 4"));
    try testing.expect(!term.containsText("Line 9"));
}
```

## Benefits of This Approach

1. **O(1) Scrolling**: No memory copying, just pointer updates
2. **Configurable History**: User can set scrollback size
3. **Memory Efficient**: Fixed memory usage, old lines automatically discarded
4. **Viewport Flexibility**: Can view any part of history
5. **Maintains Compatibility**: Existing API works unchanged

## Open Questions

1. Should we support infinite scrollback with dynamic allocation?
2. How should search work - viewport only or include history?
3. Should we add visual indicators for scroll position?
4. How to handle very wide terminals (memory vs functionality)?