# Ticket 11: Implement Multiple Error Collection and Recovery

## Priority
🟡 **Medium**

## Component
`src/args.zig`, `src/options/parser.zig`, error handling system

## Description
The current parsing system stops at the first error encountered, providing poor user experience when multiple issues exist. Users must fix errors one-by-one and re-run the command multiple times. Implementing error collection would allow users to see and fix all issues at once.

## Current Behavior
```bash
$ myapp --unknown-option --missing-value --invalid-count=abc command arg1
Error: Unknown option: --unknown-option

# User fixes first error and runs again:
$ myapp --missing-value --invalid-count=abc command arg1  
Error: Missing value for option: --missing-value

# User fixes second error and runs again:
$ myapp --invalid-count=abc command arg1
Error: Invalid value 'abc' for option --invalid-count
```

## Desired Behavior
```bash
$ myapp --unknown-option --missing-value --invalid-count=abc command arg1
Multiple errors found:
1. Unknown option: --unknown-option. Did you mean --known-option?
2. Missing value for option: --missing-value
3. Invalid value 'abc' for option --invalid-count. Expected integer.
```

## Implementation Strategy

### 1. Enhanced Error Collection
```zig
pub const ErrorCollection = struct {
    errors: std.ArrayList(StructuredError),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .errors = std.ArrayList(StructuredError).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *@This()) void {
        self.errors.deinit();
    }
    
    pub fn add(self: *@This(), error_value: StructuredError) !void {
        try self.errors.append(error_value);
    }
    
    pub fn hasErrors(self: @This()) bool {
        return self.errors.items.len > 0;
    }
    
    pub fn toSingleError(self: @This()) StructuredError {
        if (self.errors.items.len == 1) {
            return self.errors.items[0];
        }
        
        return .{
            .multiple_errors = .{
                .errors = self.errors.items,
                .count = self.errors.items.len,
            }
        };
    }
};
```

### 2. Updated Parsing Interface
```zig
pub const ParseMode = enum {
    fail_fast,      // Stop at first error (current behavior)
    collect_errors, // Collect all errors before failing
    best_effort,    // Parse what's possible, report errors for the rest
};

pub fn parseArgsWithMode(
    comptime T: type, 
    args: []const []const u8, 
    mode: ParseMode
) Result(T) {
    var error_collection = ErrorCollection.init(allocator);
    defer error_collection.deinit();
    
    var result: T = undefined;
    var success = true;
    
    // Parse each field, collecting errors instead of failing immediately
    inline for (@typeInfo(T).Struct.fields, 0..) |field, i| {
        const field_result = parseField(field, args, i);
        
        switch (field_result) {
            .success => |value| {
                @field(result, field.name) = value;
            },
            .error => |err| {
                success = false;
                
                switch (mode) {
                    .fail_fast => return Result(T){ .error = err },
                    .collect_errors, .best_effort => {
                        try error_collection.add(err);
                        
                        if (mode == .best_effort) {
                            // Provide reasonable default for this field
                            @field(result, field.name) = getDefaultValue(field.type);
                        }
                    },
                }
            },
        }
    }
    
    if (success or mode == .best_effort) {
        return Result(T){ .success = result };
    } else {
        return Result(T){ .error = error_collection.toSingleError() };
    }
}
```

### 3. Enhanced StructuredError for Multiple Errors
```zig
pub const StructuredError = union(enum) {
    // Existing error types...
    
    multiple_errors: struct {
        errors: []const StructuredError,
        count: usize,
        
        pub fn toString(self: @This(), allocator: std.mem.Allocator) ![]const u8 {
            var result = std.ArrayList(u8).init(allocator);
            defer result.deinit();
            
            try result.writer().print("Multiple errors found ({d} total):\n", .{self.count});
            
            for (self.errors, 0..) |err, i| {
                const err_msg = try err.toString(allocator);
                defer allocator.free(err_msg);
                
                try result.writer().print("{}. {s}\n", .{i + 1, err_msg});
            }
            
            return result.toOwnedSlice();
        }
        
        pub fn getSeverity(self: @This()) ErrorSeverity {
            var max_severity = ErrorSeverity.info;
            
            for (self.errors) |err| {
                const severity = err.getSeverity();
                if (@intFromEnum(severity) > @intFromEnum(max_severity)) {
                    max_severity = severity;
                }
            }
            
            return max_severity;
        }
    },
};

pub const ErrorSeverity = enum(u8) {
    info = 0,
    warning = 1,
    error = 2,
    critical = 3,
};
```

### 4. Smart Error Recovery
```zig
pub const ErrorRecovery = struct {
    pub fn getDefaultValue(comptime T: type) T {
        return switch (@typeInfo(T)) {
            .Bool => false,
            .Int => 0,
            .Float => 0.0,
            .Pointer => |ptr_info| {
                if (ptr_info.size == .Slice and ptr_info.child == u8) {
                    return "";  // Empty string for string slices
                } else {
                    @compileError("Cannot provide default for pointer type: " ++ @typeName(T));
                }
            },
            .Optional => null,
            .Array => |arr_info| {
                if (arr_info.child == u8) {
                    return [_]u8{0} ** arr_info.len;  // Zero-filled for u8 arrays
                } else {
                    @compileError("Cannot provide default for array type: " ++ @typeName(T));
                }
            },
            .Enum => |enum_info| {
                // Return first enum value as default
                return @field(T, enum_info.fields[0].name);
            },
            else => @compileError("Cannot provide default for type: " ++ @typeName(T)),
        };
    }
    
    pub fn suggestCorrection(error_type: StructuredError) ?[]const u8 {
        return switch (error_type) {
            .option_unknown => |ctx| findSimilarOption(ctx.option_name),
            .argument_invalid_type => |ctx| suggestTypeCorrection(ctx.provided_value, ctx.expected_type),
            else => null,
        };
    }
};
```

### 5. Configuration and User Control
```zig
pub const ParsingConfig = struct {
    mode: ParseMode = .fail_fast,
    max_errors: usize = 10,           // Limit error collection to prevent spam
    enable_suggestions: bool = true,   // Include "did you mean" suggestions
    enable_recovery: bool = false,     // Try to continue parsing with defaults
    
    pub fn fromEnvironment() @This() {
        return .{
            .mode = if (std.posix.getenv("ZCLI_COLLECT_ERRORS")) |_| 
                .collect_errors 
            else 
                .fail_fast,
            .enable_recovery = std.posix.getenv("ZCLI_BEST_EFFORT") != null,
        };
    }
};

pub fn parseArgsConfigurable(
    comptime T: type, 
    args: []const []const u8, 
    config: ParsingConfig
) Result(T) {
    return parseArgsWithMode(T, args, config.mode);
}
```

## Implementation Examples

### Option Parsing with Error Collection
```zig
pub fn parseOptionsWithErrorCollection(
    comptime OptionsType: type,
    args: []const []const u8,
    config: ParsingConfig
) Result(OptionsType) {
    var error_collection = ErrorCollection.init(allocator);
    defer error_collection.deinit();
    
    var result: OptionsType = getDefaultOptions(OptionsType);
    var i: usize = 0;
    
    while (i < args.len) {
        const arg = args[i];
        
        if (std.mem.startsWith(u8, arg, "--")) {
            const option_result = parseLongOption(OptionsType, args, &i);
            
            switch (option_result) {
                .success => |option| {
                    try applyOption(&result, option);
                },
                .error => |err| {
                    if (config.mode == .fail_fast) {
                        return Result(OptionsType){ .error = err };
                    }
                    
                    try error_collection.add(err);
                    
                    if (error_collection.errors.items.len >= config.max_errors) {
                        try error_collection.add(.{
                            .too_many_errors = .{
                                .limit = config.max_errors,
                                .message = "Stopping error collection due to limit",
                            }
                        });
                        break;
                    }
                }
            }
        }
        
        i += 1;
    }
    
    if (error_collection.hasErrors()) {
        return Result(OptionsType){ .error = error_collection.toSingleError() };
    }
    
    return Result(OptionsType){ .success = result };
}
```

### Command-Line Interface
```bash
# Environment variable control
export ZCLI_COLLECT_ERRORS=1
myapp --bad-option1 --bad-option2 --bad-option3

# Built-in flag support
myapp --zcli-collect-errors --bad-option1 --bad-option2

# Best effort mode
export ZCLI_BEST_EFFORT=1
myapp --bad-option command  # Continues with defaults
```

## User Experience Improvements

### Enhanced Error Messages
```zig
pub fn formatMultipleErrors(errors: []const StructuredError, allocator: std.mem.Allocator) ![]const u8 {
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    
    try output.writer().print("Found {} error{}:\n\n", .{
        errors.len, 
        if (errors.len == 1) @as([]const u8, "") else @as([]const u8, "s")
    });
    
    // Group similar errors
    var grouped_errors = try groupSimilarErrors(errors, allocator);
    defer grouped_errors.deinit();
    
    for (grouped_errors.items, 0..) |group, i| {
        try output.writer().print("{}. ", .{i + 1});
        
        if (group.count > 1) {
            try output.writer().print("({} similar) ", .{group.count});
        }
        
        const error_msg = try group.representative.toString(allocator);
        defer allocator.free(error_msg);
        try output.writer().print("{s}\n", .{error_msg});
        
        // Show suggestion if available
        if (group.suggestion) |suggestion| {
            try output.writer().print("   Suggestion: {s}\n", .{suggestion});
        }
        
        try output.writer().print("\n");
    }
    
    return output.toOwnedSlice();
}
```

### Progress Indication for Large Error Sets
```zig
pub fn parseWithProgress(
    comptime T: type, 
    args: []const []const u8, 
    config: ParsingConfig
) Result(T) {
    var progress = ProgressIndicator.init("Parsing arguments", args.len);
    defer progress.deinit();
    
    // ... parsing with progress updates
    
    if (error_count > 0) {
        progress.setStatus(try std.fmt.allocPrint(
            allocator, 
            "Found {} errors", 
            .{error_count}
        ));
    }
    
    return result;
}
```

## Testing Strategy

### Error Collection Testing
```zig
test "error collection gathers multiple errors" {
    const TestArgs = struct {
        count: u32,
        name: []const u8,
        enable: bool,
    };
    
    const args = &.{
        "--count", "not-a-number",      // Invalid type
        "--unknown-option", "value",     // Unknown option
        "--enable",                      // Missing value
        "missing-required-arg",         // Should be positional arg
    };
    
    const result = parseArgsWithMode(TestArgs, args, .collect_errors);
    
    try testing.expect(result == .error);
    try testing.expect(result.error == .multiple_errors);
    try testing.expect(result.error.multiple_errors.count == 3);  // 3 distinct errors
}

test "best effort mode provides partial results" {
    const TestArgs = struct {
        count: u32 = 0,
        name: []const u8 = "default",
        enable: bool = false,
    };
    
    const args = &.{
        "--count", "not-a-number",  // Invalid, will use default 0
        "--name", "valid-name",     // Valid, will be used
        "--enable", "invalid",      // Invalid, will use default false
    };
    
    const result = parseArgsWithMode(TestArgs, args, .best_effort);
    
    try testing.expect(result == .success);
    try testing.expectEqual(@as(u32, 0), result.success.count);       // Default used
    try testing.expectEqualSlices(u8, "valid-name", result.success.name); // Valid value used
    try testing.expectEqual(false, result.success.enable);            // Default used
}
```

## Performance Considerations

### Memory Management
```zig
// Error collection uses arena allocator to avoid fragmentation
pub const ErrorCollection = struct {
    arena: std.heap.ArenaAllocator,
    errors: std.ArrayList(StructuredError),
    
    pub fn init(base_allocator: std.mem.Allocator) @This() {
        var arena = std.heap.ArenaAllocator.init(base_allocator);
        return .{
            .arena = arena,
            .errors = std.ArrayList(StructuredError).init(arena.allocator()),
        };
    }
    
    pub fn deinit(self: *@This()) void {
        self.arena.deinit();  // Frees all errors at once
    }
};
```

### Processing Time Limits
```zig
pub const ParsingConfig = struct {
    // ... other fields
    max_parsing_time_ms: u64 = 5000,  // 5 second limit
    
    pub fn checkTimeout(self: @This(), start_time: u64) bool {
        const elapsed = std.time.milliTimestamp() - start_time;
        return elapsed > self.max_parsing_time_ms;
    }
};
```

## Backward Compatibility

### Default Behavior Preservation
```zig
// Existing API maintains fail-fast behavior
pub fn parseArgs(comptime T: type, args: []const []const u8) Result(T) {
    return parseArgsWithMode(T, args, .fail_fast);  // Preserves current behavior
}

// New API provides enhanced functionality
pub fn parseArgsEnhanced(comptime T: type, args: []const []const u8, config: ParsingConfig) Result(T) {
    return parseArgsWithMode(T, args, config.mode);
}
```

## Impact Assessment
- **User Experience**: Significantly improved with multiple error reporting
- **Performance**: Small overhead for error collection (~5-10%)
- **Memory**: Additional memory for error collection (bounded by max_errors)
- **Compatibility**: Fully backward compatible with existing APIs

## Acceptance Criteria
- [ ] Multiple errors collected and reported in single run
- [ ] Best-effort mode allows partial parsing with defaults
- [ ] Error messages are clear and actionable
- [ ] Performance impact < 10% for error collection mode
- [ ] Backward compatibility maintained for existing APIs
- [ ] Configuration options work through environment variables
- [ ] Memory usage bounded and cleaned up properly

## Estimated Effort
**2-3 weeks** (1 week for core error collection, 1-2 weeks for best-effort mode and user experience polish)