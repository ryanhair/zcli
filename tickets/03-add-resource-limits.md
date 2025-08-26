# Ticket 03: Add Resource Limits for DoS Protection

## Priority
🔴 **Critical**

## Component
Multiple modules (options parser, args parser, registry)

## Description
The framework lacks resource limits which could allow denial-of-service attacks through resource exhaustion. Attackers could provide extremely large arrays, many options, or deeply nested commands to exhaust memory or processing time.

## Attack Vectors Identified

### 1. Memory Exhaustion
- Large option arrays: `--files a.txt --files b.txt ... (thousands of times)`
- Long option names: `--very-very-very-...(thousands of chars)...option=value`
- Many global options from plugins

### 2. Processing Time
- Command suggestion algorithm: O(n²) with many similar commands
- Deeply nested command structures
- Large argument lists

## Current Vulnerabilities

### Option Arrays (src/options/parser.zig)
```zig
// No limits on array size
while (i < values.len) {
    try array_list.append(parsed_value);  // Unbounded growth
    i += 1;
}
```

### Command Suggestions (plugins/zcli-not-found/src/plugin.zig)
```zig
// O(n²) algorithm with no limits
for (context.available_commands) |cmd_parts| {
    const distance = levenshteinDistance(attempted_command, cmd_name);  // Expensive
}
```

## Proposed Limits

### Configuration Structure
```zig
pub const ResourceLimits = struct {
    max_option_arrays_elements: usize = 1000,
    max_option_name_length: usize = 256,
    max_total_options: usize = 100,
    max_argument_count: usize = 1000,
    max_command_depth: usize = 10,
    max_suggestions: usize = 10,
    suggestion_timeout_ms: u64 = 100,
};
```

### Implementation Points

#### 1. Option Parser Limits
```zig
// In parseOptions
if (total_options > limits.max_total_options) {
    return error.TooManyOptions;
}

if (array_list.items.len >= limits.max_option_arrays_elements) {
    return error.ArrayTooLarge;
}
```

#### 2. Command Depth Limits
```zig
// In command discovery
if (command_depth > limits.max_command_depth) {
    return error.CommandNestingTooDeep;
}
```

#### 3. Suggestion Limits
```zig
// In suggestion generation
const start_time = std.time.milliTimestamp();
for (context.available_commands) |cmd| {
    if (std.time.milliTimestamp() - start_time > limits.suggestion_timeout_ms) {
        break;  // Timeout reached
    }
    if (suggestions.items.len >= limits.max_suggestions) {
        break;  // Limit reached
    }
}
```

## Implementation Plan

### Phase 1: Core Limits (Week 1)
- [ ] Define `ResourceLimits` structure
- [ ] Implement option count and array size limits
- [ ] Add argument count limits
- [ ] Basic error messages for limit violations

### Phase 2: Advanced Limits (Week 2)  
- [ ] Command depth limits
- [ ] Suggestion algorithm limits and timeouts
- [ ] Memory usage tracking
- [ ] Configurable limits per application

### Phase 3: Monitoring (Week 3)
- [ ] Usage statistics collection
- [ ] Performance monitoring
- [ ] Tuning recommendations
- [ ] Documentation and best practices

## Configuration API

### Build-time Configuration
```zig
// In build.zig
const cmd_registry = zcli.build(b, exe, zcli_module, .{
    .resource_limits = .{
        .max_option_arrays_elements = 500,  // Override default
        .suggestion_timeout_ms = 50,        // Faster timeout
    },
});
```

### Runtime Configuration
```zig
// In main.zig
var app = registry.registry.init();
app.setResourceLimits(.{
    .max_total_options = 50,  // Stricter for this app
});
```

## Error Handling

### User-Friendly Messages
```zig
// Instead of generic errors
return StructuredError{
    .resource_limit_exceeded = .{
        .limit_type = "option_array_size",
        .limit_value = 1000,
        .actual_value = array_size,
        .suggestion = "Consider using configuration files for large option sets",
    }
};
```

## Testing Strategy

### Attack Simulation
- [ ] Memory exhaustion tests
- [ ] Processing time attacks  
- [ ] Boundary testing at limits
- [ ] Recovery testing after limit violations

### Performance Testing
- [ ] Benchmark with limits enabled/disabled
- [ ] Memory usage profiling
- [ ] Timeout effectiveness testing

## Backward Compatibility
- Default limits should allow all current legitimate usage
- Limits should be configurable to maintain flexibility
- Error messages should guide users to solutions

## Impact
- **Security**: Prevents DoS attacks via resource exhaustion
- **Stability**: Protects against accidental resource exhaustion
- **Performance**: Bounds worst-case performance scenarios

## Acceptance Criteria
- [ ] No resource exhaustion possible with malicious input
- [ ] Configurable limits with reasonable defaults
- [ ] Clear error messages when limits exceeded
- [ ] Performance impact < 5% in normal usage
- [ ] All existing functionality preserved

## Estimated Effort
**2-3 weeks** (1 week for core implementation, 1-2 weeks for testing and tuning)