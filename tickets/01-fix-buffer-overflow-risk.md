# Ticket 01: Fix Buffer Overflow Risk in Option Name Conversion

## Priority
🔴 **Critical**

## Component
`src/options/parser.zig`, `src/options/utils.zig`

## Description
The option name conversion uses a fixed 64-byte buffer which could overflow with very long option names. While the utility function does bounds checking, using a fixed buffer creates an artificial limitation and potential security risk.

## Location
- **File**: `src/options/parser.zig`
- **Lines**: 330-333

## Current Code
```zig
var option_field_name_buf: [64]u8 = undefined;
const option_field_name = utils.dashesToUnderscores(option_field_name_buf[0..], option_name) catch |err| {
    return err;
};
```

## Risk Assessment
- **Buffer Size**: 64 bytes may be insufficient for legitimate long option names
- **Error Handling**: Current bounds checking rejects valid long options
- **Attack Vector**: Could be exploited to cause DoS by triggering errors

## Proposed Solutions

### Option 1: Dynamic Allocation
```zig
const option_field_name_buf = try context.allocator.alloc(u8, option_name.len);
defer context.allocator.free(option_field_name_buf);
const option_field_name = utils.dashesToUnderscores(option_field_name_buf, option_name) catch |err| {
    return err;
};
```

### Option 2: Larger Static Buffer
```zig
var option_field_name_buf: [256]u8 = undefined;  // Increased from 64 to 256
```

### Option 3: In-Place Processing (Recommended)
```zig
// Process option names without copying when possible
const option_field_name = if (std.mem.containsAtLeast(u8, option_name, 1, "-"))
    try utils.dashesToUnderscores(try context.allocator.alloc(u8, option_name.len), option_name)
else
    option_name;  // No conversion needed
```

## Impact
- **Security**: Prevents potential buffer overflow attacks
- **Usability**: Allows legitimate long option names
- **Performance**: Reduces unnecessary copying

## Testing Required
- [ ] Test with option names > 64 characters
- [ ] Test with option names at various lengths (63, 64, 65, 100, 256)
- [ ] Verify memory cleanup with dynamic allocation
- [ ] Performance testing with many long options

## Acceptance Criteria
- [ ] No arbitrary limits on option name lengths
- [ ] No buffer overflow vulnerabilities
- [ ] Proper memory management
- [ ] Performance regression testing passes

## Estimated Effort
**3-5 hours**