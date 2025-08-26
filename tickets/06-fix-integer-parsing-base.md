# Ticket 06: Fix Integer Parsing Base Ambiguity

## Priority
🟡 **Medium**

## Component
`src/options/utils.zig`

## Description
The integer parsing currently uses base 0 which allows octal and hexadecimal parsing. This could lead to unexpected behavior when users provide values like `010` (interpreted as octal 8) or `0x10` (interpreted as hexadecimal 16) when they likely intend decimal interpretation.

## Location
- **File**: `src/options/utils.zig`
- **Lines**: 73

## Current Code
```zig
return std.fmt.parseInt(T, value, 0) catch {  // Base 0 = auto-detect
    logging.optionValueInvalid(value, @typeName(T));
    return error.InvalidOptionValue;
};
```

## Problem Examples
```bash
# User input -> Actual interpretation
myapp --count 010    # User expects 10, gets 8 (octal)
myapp --size 0x20    # User expects 0, gets 32 (hexadecimal)
myapp --timeout 08   # User expects 8, gets error (invalid octal)
```

## Proposed Solutions

### Option 1: Force Decimal (Recommended)
```zig
return std.fmt.parseInt(T, value, 10) catch {  // Always decimal
    logging.optionValueInvalid(value, @typeName(T));
    return error.InvalidOptionValue;
};
```

### Option 2: Explicit Base Support
```zig
// Support explicit prefixes but default to decimal
const base = if (std.mem.startsWith(u8, value, "0x") or std.mem.startsWith(u8, value, "0X"))
    16
else if (std.mem.startsWith(u8, value, "0o") or std.mem.startsWith(u8, value, "0O"))
    8
else if (std.mem.startsWith(u8, value, "0b") or std.mem.startsWith(u8, value, "0B"))
    2
else
    10;

return std.fmt.parseInt(T, value, base) catch {
    logging.optionValueInvalid(value, @typeName(T));
    return error.InvalidOptionValue;
};
```

### Option 3: Configuration-Based
```zig
pub const NumberParsingConfig = struct {
    allow_hex: bool = false,
    allow_octal: bool = false,
    allow_binary: bool = false,
};

pub fn parseInteger(comptime T: type, value: []const u8, config: NumberParsingConfig) !T {
    if (config.allow_hex and (std.mem.startsWith(u8, value, "0x") or std.mem.startsWith(u8, value, "0X"))) {
        return std.fmt.parseInt(T, value, 16);
    }
    // ... similar for other bases
    return std.fmt.parseInt(T, value, 10);
}
```

## Impact Analysis

### User Experience
- **Current**: Confusing and unexpected behavior with `010` → 8
- **Fixed**: Predictable decimal parsing
- **Enhanced**: Clear error messages for invalid formats

### Backward Compatibility
- **Risk**: Existing users relying on octal/hex parsing would break
- **Mitigation**: Audit examples and documentation for non-decimal usage
- **Timeline**: Can be phased in with deprecation warnings

## Recommendation

**Implement Option 1 (Force Decimal)** for the following reasons:
1. **Principle of Least Surprise**: CLI users expect decimal by default
2. **Consistency**: Most CLI tools use decimal-only parsing
3. **Security**: Prevents accidental octal interpretation
4. **Simplicity**: Reduces complexity and edge cases

If advanced base support is needed later, it can be added as an explicit feature with clear syntax.

## Testing Required

### Basic Cases
- [ ] Test decimal numbers: `1`, `42`, `1000`
- [ ] Test negative numbers: `-1`, `-42`
- [ ] Test zero: `0`, `00`, `000`
- [ ] Test boundary values: max/min for each integer type

### Edge Cases
- [ ] Test previously-octal values: `010` should now equal 10
- [ ] Test previously-hex values: `0x10` should now error
- [ ] Test invalid formats: `0o10`, `0b101`
- [ ] Test leading zeros: `001`, `007`, `009`

### Error Handling
- [ ] Test non-numeric input: `abc`, `1a2`
- [ ] Test overflow conditions
- [ ] Test empty strings
- [ ] Test whitespace handling

## Implementation Steps

1. **Update parsing function** to use base 10
2. **Update error messages** to be clearer about decimal requirement
3. **Add comprehensive tests** for decimal-only parsing
4. **Update documentation** to clarify decimal-only behavior
5. **Search codebase** for any code expecting octal/hex parsing

## Error Message Improvements

### Before
```
Invalid option value: '010'
```

### After
```
Invalid option value: '010'. Expected a decimal number (use 10 instead of 010).
```

### Enhanced Version
```zig
fn formatIntegerError(value: []const u8, comptime T: type) ![]const u8 {
    var suggestion: ?[]const u8 = null;
    
    // Provide helpful suggestions for common mistakes
    if (std.mem.startsWith(u8, value, "0x")) {
        suggestion = "hexadecimal not supported, use decimal";
    } else if (std.mem.startsWith(u8, value, "0") and value.len > 1) {
        // Try parsing as decimal to provide suggestion
        const decimal = std.fmt.parseInt(u64, value, 10) catch null;
        if (decimal != null) {
            suggestion = try std.fmt.allocPrint(allocator, "leading zeros not supported, use {} instead", .{decimal.?});
        }
    }
    
    return if (suggestion) |s| 
        try std.fmt.allocPrint(allocator, "Invalid option value: '{}'. {}", .{value, s})
    else
        try std.fmt.allocPrint(allocator, "Invalid option value: '{}'. Expected a decimal integer.", .{value});
}
```

## Documentation Updates

### Help Text
```
Options:
  --count <number>     Number of items (decimal integer)
  --timeout <seconds>  Timeout in seconds (use decimal, e.g., 30)
```

### Error Reference
```markdown
## E002: Invalid Numeric Value

zcli expects decimal integers for numeric options.

Examples:
- Correct: `--count 42`
- Incorrect: `--count 0x2A` (hexadecimal not supported)
- Incorrect: `--count 052` (octal not supported, use 42)
```

## Acceptance Criteria
- [ ] All integer parsing uses base 10 exclusively
- [ ] Clear error messages for invalid formats
- [ ] Helpful suggestions for common mistakes
- [ ] All existing tests pass with decimal-only behavior
- [ ] Documentation updated to reflect decimal-only parsing
- [ ] Performance impact negligible

## Estimated Effort
**4-6 hours** (2 hours implementation, 2-4 hours testing and documentation)