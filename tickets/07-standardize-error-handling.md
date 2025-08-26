# Ticket 07: Standardize Error Handling Throughout Codebase

## Priority
🟡 **Medium**

## Component
Multiple modules (args.zig, options/, errors.zig)

## Description
The codebase currently uses a mix of simple errors and structured errors, creating inconsistency in error handling patterns. Some functions return basic `error.InvalidOption` while others use rich `StructuredError` with detailed context. This inconsistency makes error handling unpredictable and reduces user experience quality.

## Current Inconsistencies

### Pattern 1: Simple Errors
```zig
// In some places
return error.UnknownOption;
return error.InvalidOptionValue;
return error.MissingArgument;
```

### Pattern 2: Structured Errors (Preferred)
```zig
// In other places
return ParseResult(T){ .err = ErrorBuilder.unknownOption(option_name, false) };
return ParseResult(T){ .err = StructuredError{ 
    .argument_missing_required = .{
        .field_name = field.name,
        .position = i,
        .expected_type = @typeName(field.type),
    }
}};
```

### Pattern 3: Mixed Return Types
```zig
// Some functions return errors directly
fn parseOption() !OptionValue

// Others return ParseResult wrapper
fn parseArgs() ParseResult(Args)

// Others return union types
fn processCommand() union(enum) { success: Result, error: StructuredError }
```

## Problems Caused

### 1. Inconsistent Error Experience
- Some errors provide rich context and suggestions
- Others give minimal information
- Users get different quality of help depending on error type

### 2. Difficult Error Handling
- Calling code must handle different error types differently
- Error propagation becomes complex
- Plugin error handling becomes unpredictable

### 3. Maintenance Issues
- Adding new error information requires updating multiple patterns
- Error logging and reporting becomes complicated
- Testing error cases becomes inconsistent

## Proposed Solutions

### Option A: Structured Error Pattern (Current Direction)

#### 1. Unified Error Return Type
```zig
// Standardize on Result(T) pattern
pub fn Result(comptime T: type) type {
    return union(enum) {
        success: T,
        error: StructuredError,
        
        pub fn isError(self: @This()) bool {
            return self == .error;
        }
        
        pub fn unwrap(self: @This()) !T {
            return switch (self) {
                .success => |val| val,
                .error => |err| err.toZigError(),
            };
        }
        
        pub fn unwrapOrDefault(self: @This(), default: T) T {
            return switch (self) {
                .success => |val| val,
                .error => default,
            };
        }
    };
}
```

#### 2. Standardized Error Creation
```zig
// Centralized error creation with consistent patterns
pub const ErrorBuilder = struct {
    pub fn unknownOption(option_name: []const u8, is_short: bool) StructuredError {
        return .{
            .option_unknown = .{
                .option_name = option_name,
                .is_short_option = is_short,
                .suggestion = findSimilarOption(option_name),
            }
        };
    }
    
    pub fn missingArgument(field_name: []const u8, position: usize, expected_type: []const u8) StructuredError {
        return .{
            .argument_missing_required = .{
                .field_name = field_name,
                .position = position,
                .expected_type = expected_type,
            }
        };
    }
    
    pub fn invalidValue(field_name: []const u8, value: []const u8, expected_type: []const u8) StructuredError {
        return .{
            .argument_invalid_type = .{
                .field_name = field_name,
                .provided_value = value,
                .expected_type = expected_type,
                .suggestion = getSuggestionForType(value, expected_type),
            }
        };
    }
};
```

#### 3. Consistent Function Signatures
```zig
// Before: Mixed patterns
fn parseArgs(comptime T: type, args: []const []const u8) !T
fn parseOptions(comptime T: type, args: []const []const u8) ParseResult(T)
fn validateCommand(name: []const u8) CommandError!void

// After: Standardized
fn parseArgs(comptime T: type, args: []const []const u8) Result(T)
fn parseOptions(comptime T: type, args: []const []const u8) Result(T)  
fn validateCommand(name: []const u8) Result(void)
```

### Option B: Diagnostic Pattern (More Idiomatic to Zig)

The Diagnostic pattern follows Zig's standard error handling while providing rich error context through a separate diagnostics system. This approach is used by `zig-clap`, Zig's JSON parser, and other standard library components.

#### 1. Standard Error Types + Diagnostic Context
```zig
// Standard Zig error types (simple, fast)
pub const ParseError = error{
    UnknownOption,
    MissingArgument,
    InvalidArgumentType,
    TooManyArguments,
    CommandNotFound,
    // ... other error types
};

// Rich diagnostic information (only when needed)
pub const Diagnostic = union(std.meta.FieldEnum(ParseError)) {
    UnknownOption: struct {
        option_name: []const u8,
        is_short: bool,
        suggestions: []const []const u8,
        available_options: []const []const u8,
    },
    MissingArgument: struct {
        field_name: []const u8,
        position: usize,
        expected_type: []const u8,
    },
    InvalidArgumentType: struct {
        field_name: []const u8,
        position: usize,
        provided_value: []const u8,
        expected_type: []const u8,
    },
    TooManyArguments: struct {
        expected_count: usize,
        actual_count: usize,
    },
    CommandNotFound: struct {
        attempted_command: []const u8,
        command_path: []const []const u8,
        suggestions: []const []const u8,
    },
    // ... other diagnostic contexts
};
```

#### 2. Parser with Diagnostic Support
```zig
pub const Parser = struct {
    diagnostic: ?*Diagnostic = null,
    
    pub fn parseArgs(self: *Parser, comptime T: type, args: []const []const u8) ParseError!T {
        // Normal parsing logic
        const result = self.parseArgsImpl(T, args) catch |err| {
            // Populate diagnostic information on error
            if (self.diagnostic) |diag| {
                diag.* = self.createDiagnostic(err);
            }
            return err;
        };
        return result;
    }
    
    fn createDiagnostic(self: *Parser, err: ParseError) Diagnostic {
        return switch (err) {
            error.UnknownOption => Diagnostic{
                .UnknownOption = .{
                    .option_name = self.last_unknown_option,
                    .is_short = self.last_option_was_short,
                    .suggestions = self.findSimilarOptions(),
                    .available_options = self.getAllOptions(),
                }
            },
            error.MissingArgument => Diagnostic{
                .MissingArgument = .{
                    .field_name = self.last_missing_field,
                    .position = self.current_position,
                    .expected_type = self.expected_type_name,
                }
            },
            // ... other error mappings
        };
    }
};
```

#### 3. Usage Pattern
```zig
// Client code using the diagnostic pattern
pub fn main() !void {
    var diagnostic: Diagnostic = undefined;
    var parser = Parser{ .diagnostic = &diagnostic };
    
    const args = parseArgs(MyArgs, std.os.argv[1..]) catch |err| {
        // Standard error handling, with optional rich diagnostics
        switch (err) {
            error.UnknownOption => {
                const diag = diagnostic.UnknownOption;
                try stderr.print("Unknown option '{s}'\n", .{diag.option_name});
                if (diag.suggestions.len > 0) {
                    try stderr.print("Did you mean:\n");
                    for (diag.suggestions) |suggestion| {
                        try stderr.print("  {s}\n", .{suggestion});
                    }
                }
            },
            error.MissingArgument => {
                const diag = diagnostic.MissingArgument;
                try stderr.print("Missing required argument '{s}' at position {d}\n", 
                    .{diag.field_name, diag.position + 1});
                try stderr.print("Expected type: {s}\n", .{diag.expected_type});
            },
            else => return err,
        }
        return err;
    };
    
    // Use parsed args...
}
```

#### 4. Compile-Time Error/Diagnostic Sync
```zig
// Ensure every error has a corresponding diagnostic (compile-time check)
comptime {
    const error_fields = std.meta.fields(ParseError);
    const diagnostic_fields = std.meta.fields(std.meta.FieldEnum(Diagnostic));
    
    if (error_fields.len != diagnostic_fields.len) {
        @compileError("ParseError and Diagnostic field count mismatch");
    }
    
    // Verify each error has a diagnostic
    inline for (error_fields) |error_field| {
        var found = false;
        inline for (diagnostic_fields) |diag_field| {
            if (std.mem.eql(u8, error_field.name, diag_field.name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            @compileError("Missing diagnostic for error: " ++ error_field.name);
        }
    }
}

// Helper function to check if an error has diagnostic info
pub fn hasDiagnostic(err: anyerror) bool {
    inline for (std.meta.fields(Diagnostic)) |field| {
        if (std.mem.eql(u8, field.name, @errorName(err))) {
            return true;
        }
    }
    return false;
}
```

## Comparison: Structured Error vs Diagnostic Pattern

| Aspect | Structured Error (Option A) | Diagnostic Pattern (Option B) |
|--------|------------------------------|-------------------------------|
| **Zig Idiomaticity** | Custom pattern, deviates from Zig norms | Follows standard Zig error handling |
| **Error Propagation** | Requires custom Result(T) wrapper | Standard `!T` error propagation |
| **Performance** | Every error allocates structured context | Diagnostics only when requested |
| **Compatibility** | Requires wrappers for standard patterns | Works with existing Zig error patterns |
| **Error Information** | Always available with error | Available through diagnostic when needed |
| **Complexity** | Higher - custom error handling throughout | Lower - standard errors + optional diagnostics |
| **Memory Usage** | Higher - context always allocated | Lower - diagnostics only when needed |
| **Standard Library Alignment** | Custom approach | Aligns with std.json, zig-clap, etc. |
| **Plugin Integration** | Requires custom error handling in plugins | Plugins can use standard error handling |
| **Learning Curve** | Developers must learn custom patterns | Uses familiar Zig error patterns |

## Recommended Approach

**Option B (Diagnostic Pattern) is recommended** for the following reasons:

1. **Zig Idiomaticity**: Aligns with standard Zig error handling patterns
2. **Performance**: Only allocates diagnostic context when explicitly requested
3. **Compatibility**: Works seamlessly with existing Zig code and plugins
4. **Standard Library Precedent**: Used by `std.json`, `zig-clap`, and other established libraries
5. **Lower Complexity**: Uses familiar error propagation with optional rich context

## Migration Strategy (Option B - Diagnostic Pattern)

### Phase 1: Core Error Types & Diagnostics (Week 1)
- [ ] Define standard `ParseError` error set
- [ ] Create corresponding `Diagnostic` union with rich context
- [ ] Add compile-time sync validation between errors and diagnostics
- [ ] Implement basic diagnostic creation functions

### Phase 2: Parser Integration (Week 2)
- [ ] Update `parseArgs` and `parseOptions` to use standard errors
- [ ] Add diagnostic support to parsing functions
- [ ] Implement diagnostic context population on errors
- [ ] Add suggestion generation for common errors

### Phase 3: Framework Integration (Week 3)
- [ ] Update registry and command execution to use diagnostic pattern
- [ ] Maintain plugin compatibility with standard error handling
- [ ] Update error reporting in CLI framework
- [ ] Add diagnostic-aware error display

### Phase 4: Testing and Documentation (Week 4)
- [ ] Add comprehensive error handling tests
- [ ] Update error handling documentation for diagnostic pattern
- [ ] Create examples showing diagnostic usage
- [ ] Performance testing to verify diagnostic overhead is minimal

## Detailed Implementation (Diagnostic Pattern)

### Core Error and Diagnostic Types
```zig
// Standard error types (aligned with current StructuredError variants)
pub const ZcliError = error{
    // Argument errors
    ArgumentMissingRequired,
    ArgumentInvalidValue,
    ArgumentTooMany,
    
    // Option errors
    OptionUnknown,
    OptionMissingValue,
    OptionInvalidValue,
    OptionBooleanWithValue,
    OptionDuplicate,
    
    // Command errors
    CommandNotFound,
    SubcommandNotFound,
    
    // Build-time errors
    BuildCommandDiscoveryFailed,
    BuildRegistryGenerationFailed,
    BuildOutOfMemory,
    
    // System errors
    SystemOutOfMemory,
    SystemFileNotFound,
    SystemAccessDenied,
    
    // Special cases
    HelpRequested,
    VersionRequested,
    
    // Resource limits
    ResourceLimitExceeded,
};

// Rich diagnostic information (matches StructuredError contexts)
pub const ZcliDiagnostic = union(std.meta.FieldEnum(ZcliError)) {
    ArgumentMissingRequired: struct {
        field_name: []const u8,
        position: usize,
        expected_type: []const u8,
    },
    ArgumentInvalidValue: struct {
        field_name: []const u8,
        position: usize,
        provided_value: []const u8,
        expected_type: []const u8,
    },
    ArgumentTooMany: struct {
        expected_count: usize,
        actual_count: usize,
    },
    OptionUnknown: struct {
        option_name: []const u8,
        is_short: bool,
        suggestions: []const []const u8,
    },
    OptionMissingValue: struct {
        option_name: []const u8,
        is_short: bool,
        expected_type: []const u8,
    },
    OptionInvalidValue: struct {
        option_name: []const u8,
        is_short: bool,
        provided_value: []const u8,
        expected_type: []const u8,
    },
    OptionBooleanWithValue: struct {
        option_name: []const u8,
        is_short: bool,
        provided_value: []const u8,
    },
    OptionDuplicate: struct {
        option_name: []const u8,
        is_short: bool,
    },
    CommandNotFound: struct {
        attempted_command: []const u8,
        command_path: []const []const u8,
        suggestions: []const []const u8,
    },
    SubcommandNotFound: struct {
        subcommand_name: []const u8,
        parent_path: []const []const u8,
        suggestions: []const []const u8,
    },
    BuildCommandDiscoveryFailed: struct {
        file_path: []const u8,
        details: []const u8,
        suggestion: ?[]const u8,
    },
    BuildRegistryGenerationFailed: struct {
        details: []const u8,
        suggestion: ?[]const u8,
    },
    BuildOutOfMemory: struct {
        operation: []const u8,
        details: []const u8,
    },
    SystemOutOfMemory: void,
    SystemFileNotFound: struct {
        file_path: []const u8,
    },
    SystemAccessDenied: struct {
        file_path: []const u8,
    },
    HelpRequested: void,
    VersionRequested: void,
    ResourceLimitExceeded: struct {
        limit_type: []const u8,
        limit_value: usize,
        actual_value: usize,
        suggestion: ?[]const u8,
    },
};
```

### Parser with Diagnostic Support
```zig
pub const Parser = struct {
    diagnostic: ?*ZcliDiagnostic = null,
    
    // State for diagnostic context
    current_option: ?[]const u8 = null,
    current_option_is_short: bool = false,
    current_field: ?[]const u8 = null,
    current_position: usize = 0,
    
    pub fn parseArgs(self: *Parser, comptime T: type, args: []const []const u8) ZcliError!T {
        // Existing parseArgs logic, but with diagnostic population
        return self.parseArgsImpl(T, args) catch |err| {
            if (self.diagnostic) |diag| {
                diag.* = self.createDiagnostic(err);
            }
            return err;
        };
    }
    
    pub fn parseOptions(self: *Parser, comptime T: type, args: []const []const u8) ZcliError!T {
        return self.parseOptionsImpl(T, args) catch |err| {
            if (self.diagnostic) |diag| {
                diag.* = self.createDiagnostic(err);
            }
            return err;
        };
    }
    
    fn createDiagnostic(self: *Parser, err: ZcliError) ZcliDiagnostic {
        return switch (err) {
            error.OptionUnknown => ZcliDiagnostic{
                .OptionUnknown = .{
                    .option_name = self.current_option.?,
                    .is_short = self.current_option_is_short,
                    .suggestions = self.findSimilarOptions(),
                },
            },
            error.ArgumentMissingRequired => ZcliDiagnostic{
                .ArgumentMissingRequired = .{
                    .field_name = self.current_field.?,
                    .position = self.current_position,
                    .expected_type = self.getFieldTypeName(),
                },
            },
            // ... other error mappings
        };
    }
};
```

### Framework Integration
```zig
// Update existing functions to use diagnostic pattern
pub fn parseArgs(comptime T: type, allocator: std.mem.Allocator, args: []const []const u8) ZcliError!T {
    // Can be called without diagnostics for simple use cases
    var parser = Parser{};
    return parser.parseArgs(T, args);
}

pub fn parseArgsWithDiagnostics(comptime T: type, allocator: std.mem.Allocator, args: []const []const u8, diagnostic: *ZcliDiagnostic) ZcliError!T {
    // Rich error information available when needed
    var parser = Parser{ .diagnostic = diagnostic };
    return parser.parseArgs(T, args);
}
```

## Testing Strategy

### Error Consistency Testing
```zig
test "all parsing functions return structured errors" {
    const invalid_args = &.{"--nonexistent-option"};
    
    const args_result = parseArgs(TestArgs, invalid_args);
    const options_result = parseOptions(TestOptions, invalid_args);
    
    // Both should return structured errors with consistent information
    try testing.expect(args_result.isError());
    try testing.expect(options_result.isError());
    
    // Errors should have similar context quality
    const args_err = args_result.error;
    const options_err = options_result.error;
    try testing.expect(args_err.hasContext());
    try testing.expect(options_err.hasContext());
}
```

### Error Message Quality Testing
```zig
test "error messages provide actionable information" {
    const result = parseArgs(TestArgs, &.{"--verbos"});  // Typo
    try testing.expect(result.isError());
    
    const error_msg = try result.error.toString(testing.allocator);
    defer testing.allocator.free(error_msg);
    
    // Should suggest the correct option
    try testing.expect(std.mem.indexOf(u8, error_msg, "verbose") != null);
    try testing.expect(std.mem.indexOf(u8, error_msg, "Did you mean") != null);
}
```

## Documentation Updates

### Error Handling Guide
```markdown
# Error Handling in zcli

## Consistent Patterns

All parsing functions return `Result(T)` types:

```zig
const result = parseArgs(MyArgs, args);
switch (result) {
    .success => |args| {
        // Use parsed args
    },
    .error => |err| {
        // Handle structured error
        try err.display(context.stderr());
        return err.toZigError();
    }
}
```

## Error Enhancement

When creating errors, always use `ErrorBuilder`:

```zig
// Good
return Result(T){ .error = ErrorBuilder.unknownOption(option_name, false) };

// Bad - lacks context
return error.UnknownOption;
```
```

## Performance Considerations

### Error Creation Cost
- Structured errors require memory allocation for context
- Error suggestion generation can be expensive
- Consider lazy evaluation for expensive suggestions

### Optimization Strategies
```zig
pub const ErrorBuilder = struct {
    // Lazy suggestion generation
    pub fn unknownOption(option_name: []const u8, is_short: bool) StructuredError {
        return .{
            .option_unknown = .{
                .option_name = option_name,
                .is_short_option = is_short,
                .suggestion_generator = findSimilarOptionLazy,  // Called only when needed
            }
        };
    }
};
```

## Impact Assessment
- **User Experience**: Much improved with consistent, helpful error messages
- **Developer Experience**: Clearer error handling patterns
- **Performance**: Small overhead for error context (~1-2% in error paths)
- **Maintainability**: Easier to add new error types and enhance existing ones

## Acceptance Criteria
- [ ] All parsing functions use `Result(T)` return type
- [ ] All errors provide structured context and suggestions
- [ ] Consistent error message quality across all modules
- [ ] Backward compatibility maintained for existing code
- [ ] Performance impact < 2% in normal (non-error) paths
- [ ] Comprehensive test coverage for error scenarios

## Estimated Effort
**3-4 weeks** (distributed across phases with thorough testing)