# Error Handling in zcli

The zcli framework provides a sophisticated error handling system that delivers rich, contextual error information while maintaining type safety and performance. This document explains how to work with the error handling system.

## Overview

zcli uses a **structured error system** where all parsing functions return a `ParseResult<T>` type that contains either:
- **Success** (`.ok`): The successfully parsed data
- **Error** (`.err`): A `StructuredError` with detailed context about what went wrong

## The ParseResult Pattern

### Basic Structure

```zig
pub fn ParseResult(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: StructuredError,
        
        // Convenience methods
        pub fn unwrap(self: @This()) T { ... }
        pub fn isError(self: @This()) bool { ... }
        pub fn getError(self: @This()) ?StructuredError { ... }
    };
}
```

### Usage Pattern

Instead of traditional error handling with `try`/`catch`:
```zig
// ❌ Old pattern (no longer used)
const options = try parseOptions(Options, allocator, args);
```

Use the ParseResult pattern:
```zig
// ✅ New pattern with structured errors
const result = parseOptions(Options, allocator, args);
switch (result) {
    .ok => |parsed| {
        // Use parsed.options
        defer cleanupOptions(Options, parsed.options, allocator);
    },
    .err => |structured_err| {
        // Handle error with rich context
        const description = try structured_err.description(allocator);
        defer allocator.free(description);
        try stderr.print("Error: {s}\n", .{description});
    },
}
```

## Structured Errors

### Error Categories

zcli's `StructuredError` type is a tagged union that covers all possible parsing errors:

#### Argument Errors
- `argument_missing_required` - Required argument not provided
- `argument_invalid_value` - Argument value cannot be parsed to expected type
- `argument_too_many` - More arguments provided than expected

#### Option Errors  
- `option_unknown` - Option not recognized
- `option_missing_value` - Option requires a value but none provided
- `option_invalid_value` - Option value cannot be parsed to expected type
- `option_boolean_with_value` - Boolean option given a value
- `option_duplicate` - Same option specified multiple times

#### Command Errors
- `command_not_found` - Unknown command specified
- `subcommand_not_found` - Unknown subcommand for a command group

#### System Errors
- `system_out_of_memory` - Memory allocation failed
- `system_file_not_found` - File not found
- `system_access_denied` - Permission denied

### Error Context

Each error variant contains rich context information:

```zig
// Argument error context
pub const ArgumentErrorContext = struct {
    field_name: []const u8,          // Name of the argument field
    position: usize,                 // Position in args (0-based)
    provided_value: ?[]const u8,     // What was provided (if any)
    expected_type: []const u8,       // Expected type description
    actual_count: ?usize,            // For too many arguments
};

// Option error context  
pub const OptionErrorContext = struct {
    option_name: []const u8,         // Option name (without -- or -)
    is_short: bool,                  // Whether it was -o or --option
    provided_value: ?[]const u8,     // Value provided (if any)
    expected_type: ?[]const u8,      // Expected type description
    suggested_options: ?[][]const u8, // Suggestions for typos
};
```

## API Functions

All parsing functions in zcli follow the ParseResult pattern:

### parseArgs
```zig
pub fn parseArgs(comptime ArgsType: type, args: []const []const u8) ParseResult(ArgsType)
```

Example:
```zig
const Args = struct {
    name: []const u8,
    count: u32,
};

const result = parseArgs(Args, &.{"Alice", "42"});
switch (result) {
    .ok => |parsed| {
        std.debug.print("Name: {s}, Count: {}\n", .{parsed.name, parsed.count});
    },
    .err => |err| {
        // Error with context about which argument failed
    },
}
```

### parseOptions
```zig
pub fn parseOptions(
    comptime OptionsType: type,
    allocator: std.mem.Allocator,
    args: []const []const u8
) OptionsParseResult(OptionsType)
```

Example:
```zig
const Options = struct {
    verbose: bool = false,
    output: ?[]const u8 = null,
    files: [][]const u8 = &.{},
};

const result = parseOptions(Options, allocator, args);
switch (result) {
    .ok => |parsed| {
        defer cleanupOptions(Options, parsed.options, allocator);
        // Use parsed.options
    },
    .err => |err| switch (err) {
        .option_unknown => |ctx| {
            std.debug.print("Unknown option: --{s}\n", .{ctx.option_name});
        },
        else => {},
    },
}
```

### parseOptionsAndArgs
```zig
pub fn parseOptionsAndArgs(
    comptime OptionsType: type,
    comptime meta: anytype,
    allocator: std.mem.Allocator,
    args: []const []const u8
) OptionsAndArgsParseResult(OptionsType)
```

This function separates options from positional arguments regardless of order:

```zig
const result = parseOptionsAndArgs(Options, null, allocator, args);
switch (result) {
    .ok => |parsed| {
        defer cleanupOptions(Options, parsed.options, allocator);
        defer parsed.deinit(); // Free remaining_args
        
        // parsed.options contains the options
        // parsed.remaining_args contains positional arguments
    },
    .err => |err| {
        // Handle error
    },
}
```

## Error Display

### Getting Human-Readable Descriptions

The `StructuredError` type provides a `description()` method:

```zig
const description = try err.description(allocator);
defer allocator.free(description);
try stderr.print("{s}\n", .{description});
```

Example outputs:
- `"Missing required argument 'username' at position 1. Expected type: string"`
- `"Invalid value 'abc' for option '--port'. Expected type: u16"`
- `"Unknown option '--verbos'. Did you mean '--verbose'?"`

### Accessing Suggestions

Some errors include suggestions for fixing typos:

```zig
if (err.suggestions()) |suggestions| {
    for (suggestions) |suggestion| {
        try stderr.print("  Did you mean: {s}\n", .{suggestion});
    }
}
```

## Framework Integration

### Automatic Error Handling

When using zcli's App framework, error handling is automatic:

```zig
const MyApp = zcli.App(@TypeOf(registry));

pub fn main() !void {
    var app = MyApp.init(allocator, registry, .{
        .name = "myapp",
        .version = "1.0.0",
        .description = "My application",
    });
    
    // The framework handles all ParseResult errors internally
    try app.run(args);
}
```

The framework automatically:
- Displays user-friendly error messages
- Shows suggestions for typos
- Provides appropriate exit codes
- Formats errors consistently

### Command Implementation

In your command implementations, you receive already-parsed arguments:

```zig
pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    // args and options are already parsed and validated
    // Any parsing errors were handled by the framework
    try context.stdout().print("Hello, {s}!\n", .{args.name});
}
```

## Error Types Reference

### Complete Error Type List

```zig
pub const StructuredError = union(enum) {
    // Argument parsing errors
    argument_missing_required: ArgumentErrorContext,
    argument_invalid_value: ArgumentErrorContext,
    argument_too_many: ArgumentErrorContext,
    
    // Option parsing errors
    option_unknown: OptionErrorContext,
    option_missing_value: OptionErrorContext,
    option_invalid_value: OptionErrorContext,
    option_boolean_with_value: OptionErrorContext,
    option_duplicate: OptionErrorContext,
    
    // Command routing errors
    command_not_found: CommandErrorContext,
    subcommand_not_found: CommandErrorContext,
    
    // System errors
    system_out_of_memory: void,
    system_file_not_found: []const u8,
    system_access_denied: []const u8,
    
    // Special cases
    help_requested: void,
    version_requested: void,
};
```

## Migration Guide

If you're updating from older zcli code:

### Before (Old Error Unions)
```zig
// Parsing with error unions
const options = parseOptions(Options, allocator, args) catch |err| {
    switch (err) {
        error.UnknownOption => std.debug.print("Unknown option\n", .{}),
        error.InvalidOptionValue => std.debug.print("Invalid value\n", .{}),
        else => return err,
    }
    return;
};
```

### After (ParseResult Pattern)
```zig
// Parsing with ParseResult
const result = parseOptions(Options, allocator, args);
switch (result) {
    .ok => |parsed| {
        defer cleanupOptions(Options, parsed.options, allocator);
        // Use parsed.options
    },
    .err => |err| switch (err) {
        .option_unknown => |ctx| {
            std.debug.print("Unknown option: --{s}\n", .{ctx.option_name});
            if (ctx.suggested_options) |suggestions| {
                for (suggestions) |suggestion| {
                    std.debug.print("  Did you mean: --{s}\n", .{suggestion});
                }
            }
        },
        .option_invalid_value => |ctx| {
            std.debug.print("Invalid value '{s}' for --{s}\n", 
                .{ctx.provided_value.?, ctx.option_name});
        },
        else => {
            const desc = try err.description(allocator);
            defer allocator.free(desc);
            std.debug.print("Error: {s}\n", .{desc});
        },
    },
}
```

## Best Practices

1. **Always handle both cases**: Never use `unwrap()` without checking `isError()` first
2. **Use structured error context**: Access the specific error context for detailed information
3. **Free descriptions**: Remember to free error descriptions allocated with `description()`
4. **Let the framework handle it**: When using the App framework, let it handle error display
5. **Provide good error messages**: The structured errors already contain rich context - use it!

## Examples

### Complete Error Handling Example

```zig
const std = @import("std");
const zcli = @import("zcli");

const Options = struct {
    verbose: bool = false,
    output: ?[]const u8 = null,
    threads: u32 = 1,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    const result = zcli.parseOptions(Options, allocator, args[1..]);
    switch (result) {
        .ok => |parsed| {
            defer zcli.cleanupOptions(Options, parsed.options, allocator);
            
            if (parsed.options.verbose) {
                std.debug.print("Verbose mode enabled\n", .{});
            }
            if (parsed.options.output) |output| {
                std.debug.print("Output: {s}\n", .{output});
            }
            std.debug.print("Threads: {}\n", .{parsed.options.threads});
        },
        .err => |err| {
            const stderr = std.io.getStdErr().writer();
            
            // Get a human-readable description
            const description = try err.description(allocator);
            defer allocator.free(description);
            
            try stderr.print("Error: {s}\n", .{description});
            
            // Show suggestions if available
            if (err.suggestions()) |suggestions| {
                try stderr.print("\nDid you mean:\n", .{});
                for (suggestions) |suggestion| {
                    try stderr.print("  {s}\n", .{suggestion});
                }
            }
            
            std.process.exit(1);
        },
    }
}
```

## Summary

The zcli error handling system provides:
- ✅ **Type-safe error handling** with ParseResult pattern
- ✅ **Rich error context** including field names, positions, and values  
- ✅ **Smart suggestions** for common typos
- ✅ **Consistent API** across all parsing functions
- ✅ **Framework integration** for automatic error display
- ✅ **Zero runtime overhead** through comptime optimization

This approach ensures that users get helpful, actionable error messages while developers get a clean, consistent API for error handling.