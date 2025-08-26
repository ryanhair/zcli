# Ticket 08: Improve Float Parsing Edge Cases

## Priority
🟡 **Medium**

## Component
`src/options/utils.zig`

## Description
The float parsing validation has incomplete edge case handling, particularly for scientific notation and malformed decimal formats. The current negative number detection doesn't handle formats like `-1e-5` or edge cases like `-.` (dash followed by decimal point only).

## Location
- **File**: `src/options/utils.zig`
- **Lines**: 31-33

## Current Code
```zig
// Check for decimal point (e.g., "-0.5", "-.5")
if (arg[1] == '.' and arg.len > 2 and arg[2] >= '0' and arg[2] <= '9') {
    return true;
}
```

## Issues Identified

### 1. Missing Scientific Notation
```bash
# These are valid negative floats but not detected:
-1e-5     # Scientific notation
-2.5e10   # Scientific with decimal
-1E+3     # Uppercase E
-.5e-2    # Decimal starting with dot in scientific
```

### 2. Incomplete Decimal Validation
```bash
# Edge cases not handled:
-.        # Just dash and dot (should be invalid)
-..5      # Multiple dots (should be invalid)  
-0.       # Trailing dot (valid but edge case)
```

### 3. Missing Infinity/NaN Handling
```bash
# IEEE 754 special values:
-inf      # Negative infinity
-nan      # Not a number (though negative NaN is debatable)
```

## Proposed Solution

### Enhanced Float Detection
```zig
pub fn isNegativeFloat(arg: []const u8) bool {
    if (arg.len < 2 or arg[0] != '-') return false;
    
    const number_part = arg[1..];
    
    // Check for special IEEE 754 values
    if (std.ascii.eqlIgnoreCase(number_part, "inf") or 
        std.ascii.eqlIgnoreCase(number_part, "infinity") or
        std.ascii.eqlIgnoreCase(number_part, "nan")) {
        return true;
    }
    
    // Check for scientific notation pattern
    if (hasScientificNotation(number_part)) {
        return isValidScientificFloat(number_part);
    }
    
    // Check for simple decimal pattern
    if (hasDecimalPoint(number_part)) {
        return isValidDecimalFloat(number_part);
    }
    
    // Check for integer pattern (fallback to existing logic)
    return isValidInteger(number_part);
}

fn hasScientificNotation(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "e") != null or std.mem.indexOf(u8, s, "E") != null;
}

fn isValidScientificFloat(s: []const u8) bool {
    // Find the e/E position
    const e_pos = std.mem.indexOf(u8, s, "e") orelse std.mem.indexOf(u8, s, "E") orelse return false;
    
    if (e_pos == 0 or e_pos == s.len - 1) return false;  // e/E can't be at start or end
    
    const mantissa = s[0..e_pos];
    const exponent = s[e_pos + 1..];
    
    // Validate mantissa (can be decimal or integer)
    const mantissa_valid = if (std.mem.indexOf(u8, mantissa, ".") != null)
        isValidDecimalFloat(mantissa)
    else
        isValidInteger(mantissa);
    
    // Validate exponent (must be integer, can have + or -)
    const exponent_valid = if (exponent.len > 0 and (exponent[0] == '+' or exponent[0] == '-'))
        isValidInteger(exponent[1..])
    else
        isValidInteger(exponent);
    
    return mantissa_valid and exponent_valid;
}

fn isValidDecimalFloat(s: []const u8) bool {
    if (s.len == 0) return false;
    
    var dot_count: usize = 0;
    var digit_count: usize = 0;
    
    for (s) |c| {
        if (c == '.') {
            dot_count += 1;
            if (dot_count > 1) return false;  // Multiple dots invalid
        } else if (c >= '0' and c <= '9') {
            digit_count += 1;
        } else {
            return false;  // Invalid character
        }
    }
    
    // Must have at least one digit and exactly one dot
    return dot_count == 1 and digit_count > 0;
}
```

### Enhanced Float Parsing
```zig
pub fn parseFloat(comptime T: type, value: []const u8) !T {
    // Handle special IEEE 754 values
    if (std.ascii.eqlIgnoreCase(value, "inf") or 
        std.ascii.eqlIgnoreCase(value, "infinity")) {
        return std.math.inf(T);
    }
    
    if (std.ascii.eqlIgnoreCase(value, "-inf") or 
        std.ascii.eqlIgnoreCase(value, "-infinity")) {
        return -std.math.inf(T);
    }
    
    if (std.ascii.eqlIgnoreCase(value, "nan")) {
        return std.math.nan(T);
    }
    
    // Use standard parsing with better error handling
    return std.fmt.parseFloat(T, value) catch |err| switch (err) {
        error.InvalidCharacter => {
            // Provide specific guidance for common mistakes
            if (std.mem.count(u8, value, ".") > 1) {
                return error.MultipleDecimalPoints;
            } else if (std.mem.endsWith(u8, value, ".")) {
                return error.TrailingDecimalPoint;
            } else if (std.mem.startsWith(u8, value, ".")) {
                return error.LeadingDecimalPoint;
            }
            return error.InvalidFloatFormat;
        },
        else => err,
    };
}
```

## Test Cases to Add

### Basic Scientific Notation
```zig
test "scientific notation detection" {
    try testing.expect(isNegativeFloat("-1e5"));
    try testing.expect(isNegativeFloat("-2.5e-3"));
    try testing.expect(isNegativeFloat("-1E+10"));
    try testing.expect(isNegativeFloat("-.5e2"));
}
```

### Edge Cases
```zig
test "float edge cases" {
    // Invalid cases should return false
    try testing.expect(!isNegativeFloat("-."));      // Just dash-dot
    try testing.expect(!isNegativeFloat("-..5"));    // Multiple dots
    try testing.expect(!isNegativeFloat("-e5"));     // Missing mantissa
    try testing.expect(!isNegativeFloat("-1e"));     // Missing exponent
    try testing.expect(!isNegativeFloat("-1.e.5"));  // Multiple dots
    
    // Valid cases should return true
    try testing.expect(isNegativeFloat("-0."));      // Trailing dot is valid
    try testing.expect(isNegativeFloat("-.5"));      // Leading dot is valid
    try testing.expect(isNegativeFloat("-123.456")); // Standard decimal
}
```

### IEEE 754 Special Values
```zig
test "IEEE 754 special values" {
    try testing.expect(isNegativeFloat("-inf"));
    try testing.expect(isNegativeFloat("-infinity"));
    try testing.expect(isNegativeFloat("-nan"));
    
    // Case insensitive
    try testing.expect(isNegativeFloat("-INF"));
    try testing.expect(isNegativeFloat("-Infinity"));
    try testing.expect(isNegativeFloat("-NaN"));
}
```

### Parsing Tests
```zig
test "float parsing with better errors" {
    // Valid parsing
    try testing.expectEqual(@as(f64, -1.5e-3), try parseFloat(f64, "-1.5e-3"));
    try testing.expectEqual(@as(f32, std.math.inf(f32)), try parseFloat(f32, "inf"));
    
    // Invalid parsing with specific errors
    try testing.expectError(error.MultipleDecimalPoints, parseFloat(f64, "1.2.3"));
    try testing.expectError(error.TrailingDecimalPoint, parseFloat(f64, "123."));
    try testing.expectError(error.InvalidFloatFormat, parseFloat(f64, "1.2.3e5"));
}
```

## Error Message Improvements

### Enhanced Error Context
```zig
pub const FloatParsingError = union(enum) {
    multiple_decimal_points: struct { value: []const u8 },
    trailing_decimal_point: struct { value: []const u8 },
    invalid_scientific_notation: struct { value: []const u8, issue: []const u8 },
    invalid_character: struct { value: []const u8, position: usize, character: u8 },
    
    pub fn toString(self: @This(), allocator: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .multiple_decimal_points => |ctx| std.fmt.allocPrint(allocator,
                "Invalid float '{s}': multiple decimal points found. Use only one decimal point.",
                .{ctx.value}),
            .trailing_decimal_point => |ctx| std.fmt.allocPrint(allocator,
                "Invalid float '{s}': ends with decimal point. Add digits after the decimal or remove it.",
                .{ctx.value}),
            .invalid_scientific_notation => |ctx| std.fmt.allocPrint(allocator,
                "Invalid scientific notation '{s}': {s}. Format: 1.23e-4 or 1.23E+4",
                .{ctx.value, ctx.issue}),
            .invalid_character => |ctx| std.fmt.allocPrint(allocator,
                "Invalid float '{s}': unexpected character '{c}' at position {d}.",
                .{ctx.value, ctx.character, ctx.position}),
        };
    }
};
```

## Performance Considerations

### Optimization Strategy
```zig
// Fast path for simple cases, detailed parsing only when needed
pub fn isNegativeFloat(arg: []const u8) bool {
    if (arg.len < 2 or arg[0] != '-') return false;
    
    // Fast path: check for simple decimal
    if (isSimpleDecimal(arg[1..])) return true;
    
    // Slow path: complex parsing only if needed
    return isComplexFloat(arg[1..]);
}

fn isSimpleDecimal(s: []const u8) bool {
    // Quick check for common pattern: digits, optional dot, digits
    var has_dot = false;
    for (s) |c| {
        if (c == '.') {
            if (has_dot) return false;  // Multiple dots
            has_dot = true;
        } else if (c < '0' or c > '9') {
            return false;  // Non-digit, non-dot
        }
    }
    return true;
}
```

## Documentation Updates

### User Documentation
```markdown
## Numeric Options

zcli supports various numeric formats for float options:

### Standard Decimal
- `--ratio 3.14159`
- `--temperature -32.5`

### Scientific Notation
- `--small 1.5e-10`
- `--large 2.5E+8`
- `--negative -1.2e-3`

### Special Values
- `--infinity inf` or `--infinity infinity`
- `--not-a-number nan`

### Invalid Formats
- `1.2.3` (multiple decimal points)
- `1e` (missing exponent)
- `e5` (missing mantissa)
```

## Acceptance Criteria
- [ ] Scientific notation properly detected in negative number check
- [ ] IEEE 754 special values (inf, nan) handled correctly
- [ ] Clear error messages for malformed float formats
- [ ] All edge cases properly validated
- [ ] Performance regression < 1% for simple cases
- [ ] Comprehensive test coverage for all float formats

## Estimated Effort
**1-2 weeks** (1 week implementation and testing, potentially 1 more week for optimization and edge case refinement)