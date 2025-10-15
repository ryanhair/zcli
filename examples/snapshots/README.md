# Snapshot Testing Showcase

This example demonstrates all the capabilities of the standalone `snapshot` package, showcasing how to test different types of output with various configuration options.

## Quick Start

```bash
# Build and run the demo
zig build run -- help

# Run all snapshot tests
zig build test

# Update snapshots after making changes
zig build update-snapshots
```

## Demo Commands

The `snapshot-demo` executable generates different types of output to demonstrate snapshot testing:

```bash
# Show help (static text to stderr)
zig build run -- help

# Colored output (ANSI escape codes)
zig build run -- colors

# Dynamic content (UUIDs, timestamps, memory addresses)
zig build run -- dynamic

# JSON structured data
zig build run -- json

# Formatted table with colors
zig build run -- table

# Log messages with timestamps
zig build run -- logs
```

## Snapshot Testing Options

The unified snapshot API uses an options struct with smart defaults:

```zig
pub const SnapshotOptions = struct {
    /// Whether to mask dynamic content (UUIDs, timestamps, memory addresses)
    mask: bool = true,
    /// Whether to preserve ANSI escape codes (colors, formatting)
    ansi: bool = true,
};
```

### Usage Examples

```zig
const snapshot = @import("snapshot");

// Default: mask dynamic content and preserve ANSI colors
// Best for most CLI output
try snapshot.expectSnapshot(allocator, output, @src(), "test_name", .{});

// Plain text only: no colors, no masking
// Best for structured data like JSON
try snapshot.expectSnapshot(allocator, output, @src(), "plain", .{ .ansi = false, .mask = false });

// Colors only: preserve ANSI but no masking
// Best for static colored output
try snapshot.expectSnapshot(allocator, output, @src(), "colors", .{ .mask = false });

// Masking only: strip colors but mask dynamic content
// Best for logs where you want content but not colors
try snapshot.expectSnapshot(allocator, output, @src(), "masked", .{ .ansi = false });
```

## Test Categories

### 1. Default Behavior Tests

- **`colors_default`**: Colored output with default options (mask=true, ansi=true)
- **`table_with_colors`**: Complex table with colors, no masking

### 2. Plain Text Tests

- **`colors_plain`**: Same colored output but stripped to plain text
- **`json_output`**: Clean JSON without ANSI or masking
- **`help_output`**: Static help text

### 3. Dynamic Content Masking

- **`dynamic_masked`**: UUIDs, timestamps, and memory addresses automatically masked
- **`logs_masked`**: Log entries with timestamps and IDs masked

### 4. Mixed Content Tests

- **`mixed_full`**: Complex content with both ANSI and dynamic elements (default options)
- **`mixed_colors_only`**: Same content with colors preserved but no masking
- **`mixed_masked_plain`**: Same content with masking but no ANSI

### 5. Utility Function Tests

- **`utility_masked`**: Direct use of `maskDynamicContent()` utility
- **`utility_stripped`**: Direct use of `stripAnsi()` utility

### 6. Edge Cases

- **`empty_content`**: Empty string handling
- **`whitespace_only`**: Whitespace-only content
- **`long_line`**: Very long lines (truncation in diff output)
- **`complex_ansi`**: Multiple consecutive ANSI codes

## Dynamic Content Masking

The snapshot package automatically detects and masks:

- **UUIDs**: `550e8400-e29b-41d4-a716-446655440000` → `[UUID]`
- **Timestamps**: `2024-01-15T10:30:45.123Z` → `[TIMESTAMP]`
- **Memory addresses**: `0x7fff5fbff710` → `[MEMORY_ADDR]`

### Before Masking

```
User ID: 550e8400-e29b-41d4-a716-446655440000
Timestamp: 1705312245
ISO Time: 2024-01-15T10:30:45.123Z
Memory address: 0x7fff5fbff710
Session: sess_a1b2c3d4e5f67890
```

### After Masking

```
User ID: [UUID]
Timestamp: 1705312245
ISO Time: [TIMESTAMP]
Memory address: [MEMORY_ADDR]
Session: sess_a1b2c3d4e5f67890
```

## ANSI Color Handling

### With ANSI Preservation (ansi=true)

Stores exact output including escape codes:

```
\x1b[32m✅ SUCCESS:\x1b[0m Operation completed successfully
\x1b[31m❌ ERROR:\x1b[0m Something went wrong
```

### With ANSI Stripping (ansi=false)

Stores clean text without escape codes:

```
✅ SUCCESS: Operation completed successfully
❌ ERROR: Something went wrong
```

## When to Use Each Option

| Content Type           | Recommended Options                 | Reason                                        |
| ---------------------- | ----------------------------------- | --------------------------------------------- |
| CLI help text          | `.{ .ansi = false, .mask = false }` | Static content, no colors needed              |
| Colored error messages | `.{}` (default)                     | Preserve colors, mask any dynamic IDs         |
| JSON/XML output        | `.{ .ansi = false, .mask = false }` | Structured data, no colors or dynamic content |
| Log files              | `.{}` (default)                     | May contain colors and timestamps/IDs         |
| Debug output           | `.{ .ansi = false }`                | Strip colors but mask memory addresses        |
| Static tables          | `.{ .mask = false }`                | Preserve formatting, no dynamic content       |

## Utility Functions

```zig
// Manual dynamic content masking
const masked = try snapshot.maskDynamicContent(allocator, text_with_uuids);
defer allocator.free(masked);

// Manual ANSI stripping
const clean = try snapshot.stripAnsi(allocator, colored_text);
defer allocator.free(clean);

// Framework testing helper (for testing the snapshot system itself)
try snapshot.expectSnapshotWithData(allocator, actual, @src(), "name", expected_data);
```

## Error Messages

The snapshot package provides clean, formatted error messages:

```
┌─ ANSI SNAPSHOT MISMATCH ─────────────────────────────────────┐
│ Test:     showcase.zig:42
│ Snapshot: colors_default.txt (masked)
├─────────────────────────────────────────────────────────────┤
│
│ -  1: Expected content here
│ +  1: Actual content here
├─────────────────────────────────────────────────────────────┤
│ Run 'zig build update-snapshots' to update
└─────────────────────────────────────────────────────────────┘
```

## Best Practices

1. **Use defaults first**: `try snapshot.expectSnapshot(allocator, output, @src(), "name", .{})` works for most cases
2. **Be explicit when different**: Use specific options when you need different behavior
3. **Test different combinations**: Use the same output with different options to test various aspects
4. **Meaningful names**: Use descriptive snapshot names that indicate the options used
5. **Group related tests**: Keep tests with similar content together for easier maintenance

## Architecture

This example demonstrates a real-world testing scenario where:

- An executable generates various types of output
- Tests capture and snapshot that output with different options
- The build system handles snapshot cleanup and updates
- Different option combinations test different aspects of the same functionality

This pattern works great for:

- CLI applications
- Code generators
- Template engines
- Log processors
- Any tool that produces text output
