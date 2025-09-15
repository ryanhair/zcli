# VTerm Scrolling Implementation Plan

## Current Behavior
When the cursor reaches the bottom of the terminal:
- Cursor stays at bottom-right corner (height-1, width-1)
- New text overwrites existing content at that position
- No content is shifted up or preserved

## Scrolling Requirements

### Core Functionality
1. **Line Shifting**: When cursor moves below the last line, shift all lines up by one
2. **Memory Efficiency**: Reuse existing buffer instead of allocating new memory
3. **Content Preservation**: Maintain all cell attributes during scroll

### Implementation Approaches

## Option 1: In-Place Array Shifting (Recommended)
**Approach**: Shift lines within the existing `cells` array

```zig
fn scrollUp(self: *VTerm) void {
    // Move lines 1..height up to lines 0..height-1
    for (1..self.height) |y| {
        const src_start = y * self.width;
        const dst_start = (y - 1) * self.width;
        @memcpy(
            self.cells[dst_start..dst_start + self.width],
            self.cells[src_start..src_start + self.width]
        );
    }
    
    // Clear the last line
    const last_line_start = (self.height - 1) * self.width;
    for (last_line_start..last_line_start + self.width) |i| {
        self.cells[i] = Cell.default();
    }
}
```

**Pros:**
- Simple implementation
- No additional memory needed
- Preserves all attributes
- Easy to understand and debug

**Cons:**
- O(n) operation for each scroll
- No scrollback buffer

## Option 2: Circular Buffer with Virtual Viewport
**Approach**: Keep a larger buffer and move a viewport window

```zig
pub const VTerm = struct {
    cells: []Cell,          // Larger than viewport
    viewport_start: usize,  // First visible line
    total_lines: usize,     // Total lines in buffer
    // ...
}
```

**Pros:**
- O(1) scroll operation
- Natural scrollback support
- Efficient for heavy scrolling

**Cons:**
- More complex implementation
- Requires viewport translation for all operations
- More memory usage

## Recommended Implementation (Option 1)

Start with in-place shifting for simplicity:

### 1. Add scroll method
```zig
fn scrollUp(self: *VTerm) void {
    // Implementation as shown above
}
```

### 2. Update cursor handling
```zig
// In putChar, advanceCursor, and newline handling:
if (self.cursor.y >= self.height) {
    self.scrollUp();
    self.cursor.y = self.height - 1;
}
```

### 3. Handle special cases
- CSI sequences that move cursor below bottom
- Explicit scrolling commands (CSI S, CSI T)
- Scroll regions (DECSTBM) - future enhancement

## Testing Strategy

### Basic Scrolling Test
```zig
test "terminal scrolls when cursor moves past bottom" {
    var term = try VTerm.init(testing.allocator, 10, 3);
    defer term.deinit();
    
    term.write("Line 1\n");
    term.write("Line 2\n");
    term.write("Line 3\n");
    term.write("Line 4\n");  // Should trigger scroll
    
    // Line 1 should be gone
    try testing.expect(!term.containsText("Line 1"));
    // Lines 2-4 should be visible
    try testing.expect(term.containsText("Line 2"));
    try testing.expect(term.containsText("Line 3"));
    try testing.expect(term.containsText("Line 4"));
}
```

### Attribute Preservation Test
```zig
test "scrolling preserves text attributes" {
    var term = try VTerm.init(testing.allocator, 10, 2);
    defer term.deinit();
    
    term.write("\x1b[31mRed\x1b[0m\n");
    term.write("Normal\n");
    term.write("Trigger scroll\n");
    
    // Red text should still be red after scrolling
    try testing.expectEqual(Color.red, term.getTextColor(0, 0));
}
```

## Implementation Order
1. Implement `scrollUp()` method
2. Update newline handling in `write()`
3. Update `advanceCursor()` 
4. Update `putChar()`
5. Add comprehensive tests
6. Update documentation

## Future Enhancements
- Scrollback buffer for terminal history
- Scroll regions (top/bottom margins)
- Smooth scrolling animations (if needed)
- Alternative screen buffer support with scrolling