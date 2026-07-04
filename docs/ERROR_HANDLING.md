# Error Handling in zcli

The zcli framework provides comprehensive error handling through structured error types and detailed diagnostic information. All parsing functions use standard Zig error unions to provide both type safety and rich error context.

## Overview

zcli uses **structured error types** where parsing functions return standard Zig error unions:
- **Success**: The successfully parsed data (e.g., `ArgsType` or `OptionsResult(OptionsType)`)
- **Error**: A `ZcliError` with detailed diagnostic information about what went wrong

## Core Error Types

### ZcliError

The main error union used throughout zcli:

```zig
pub const ZcliError = error{
    // Argument parsing errors
    ArgumentMissingRequired,
    ArgumentInvalidValue,
    ArgumentTooMany,

    // Option parsing errors
    OptionUnknown,
    OptionMissingValue,
    OptionInvalidValue,
    OptionBooleanWithValue,
    OptionDuplicate,

    // Command routing errors
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
```

### Diagnostic Information

When errors occur, zcli provides detailed diagnostic information through the `ZcliDiagnostic` type, which includes:

- **Field context**: Which argument or option caused the error
- **Position information**: Where in the command line the error occurred
- **Type expectations**: What was expected vs. what was provided
- **Suggestions**: Smart suggestions for typos and similar names

## API Functions

### parseArgs

Parse positional arguments into a struct:

```zig
pub fn parseArgs(comptime ArgsType: type, args: []const []const u8, diag: ?*?ZcliDiagnostic) ZcliError!ArgsType
```

The final `diag` parameter is an optional out-parameter: pass `null` if you only need the error, or a `*?ZcliDiagnostic` to capture rich context about the failure (see [Diagnostic-Driven Error Messages](#diagnostic-driven-error-messages) below).

**Example:**
```zig
const Args = struct {
    name: []const u8,
    count: u32 = 1,
};

const parsed = parseArgs(Args, &.{"Alice", "42"}, null) catch |err| switch (err) {
    error.ArgumentMissingRequired => {
        std.debug.print("Missing required argument\n", .{});
        return;
    },
    error.ArgumentInvalidValue => {
        std.debug.print("Invalid argument value\n", .{});
        return;
    },
    else => return err,
};

std.debug.print("Name: {s}, Count: {}\n", .{ parsed.name, parsed.count });
```

### parseOptions

Parse command-line options into a struct:

```zig
pub fn parseOptions(
    comptime OptionsType: type,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    diag: ?*?ZcliDiagnostic,
) ZcliError!OptionsResult(OptionsType)
```

**Example:**
```zig
const Options = struct {
    verbose: bool = false,
    output: ?[]const u8 = null,
    files: [][]const u8 = &.{},
};

const result = parseOptions(Options, allocator, args, null) catch |err| switch (err) {
    error.OptionUnknown => {
        std.debug.print("Unknown option provided\n", .{});
        return;
    },
    error.OptionInvalidValue => {
        std.debug.print("Invalid value for option\n", .{});
        return;
    },
    else => return err,
};

defer cleanupOptions(Options, result.options, allocator);
// Use result.options and result.remaining_args
```

## Error Handling Patterns

### Basic Pattern

```zig
const parsed = parseOptions(Options, allocator, args, null) catch |err| {
    std.debug.print("Parse error: {}\n", .{err});
    std.process.exit(1);
};
defer cleanupOptions(Options, parsed.options, allocator);
```

### Detailed Error Handling

```zig
const parsed = parseOptions(Options, allocator, args, null) catch |err| switch (err) {
    error.OptionUnknown => {
        std.debug.print("Unknown option. Run with --help for usage.\n", .{});
        std.process.exit(2);
    },
    error.OptionInvalidValue => {
        std.debug.print("Invalid value provided for option.\n", .{});
        std.process.exit(2);
    },
    error.ArgumentMissingRequired => {
        std.debug.print("Missing required argument. Run with --help for usage.\n", .{});
        std.process.exit(2);
    },
    error.SystemOutOfMemory => return error.SystemOutOfMemory,
    else => {
        std.debug.print("Unexpected error: {}\n", .{err});
        std.process.exit(1);
    },
};
```

### Diagnostic-Driven Error Messages

The `catch`-and-switch patterns above only know *which* error occurred. To tell the user *what* went wrong — which option, what value, what was expected — pass a diagnostic out-parameter and format it with `formatDiagnostic`:

```zig
var diag: ?zcli.ZcliDiagnostic = null;
const result = parseOptions(Options, allocator, args, &diag) catch {
    if (diag) |d| {
        const msg = try zcli.formatDiagnostic(d, allocator);
        defer allocator.free(msg);
        std.debug.print("{s}\n", .{msg});
    }
    std.process.exit(2);
};
defer cleanupOptions(Options, result.options, allocator);
```

The formatted messages carry the full context, for example:

```
Missing required argument 'name' at position 1. Expected type: []const u8
Invalid value 'abc' for option '--count'. Expected type: u32
Boolean option '--verbose' does not accept a value (got 'yes')
Unknown option '--verbos'
Did you mean:
  --verbose
```

`OptionUnknown` and `CommandNotFound` diagnostics include "did you mean?" suggestions computed by edit distance. This is exactly how the framework produces its own error output — commands get it for free.

## Framework Integration

### Automatic Error Handling

When using the zcli framework, error handling is automatic:

```zig
// In your command's execute function
const Context = @import("command_registry").Context;

pub fn execute(args: Args, options: Options, context: *Context) !void {
    // args and options are already parsed and validated
    // Any parsing errors were handled by the framework
    try context.stdout().print("Hello, {s}!\n", .{args.name});
}
```

The framework automatically:
- Parses all arguments and options
- Displays user-friendly error messages for parsing errors
- Provides appropriate exit codes
- Shows help information when requested

### Command Errors

Commands can return errors which will be handled by the framework:

```zig
pub fn execute(args: Args, options: Options, context: *Context) !void {
    const io = context.io;
    const file = std.Io.Dir.cwd().openFile(io, args.filename, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try context.stderr().print("Error: File '{s}' not found\n", .{args.filename});
            return;
        },
        error.AccessDenied => {
            try context.stderr().print("Error: Permission denied accessing '{s}'\n", .{args.filename});
            return;
        },
        else => return err, // Let framework handle unexpected errors
    };
    defer file.close(io);

    // Process file...
}
```

## Memory Management

### Option Cleanup

When using `parseOptions` directly, always clean up array options:

```zig
const result = try parseOptions(Options, allocator, args, null);
defer cleanupOptions(Options, result.options, allocator);
```

The framework handles this cleanup automatically for command implementations.

### Error Contexts

Error contexts are lightweight and don't require explicit cleanup.

## Best Practices

1. **Use specific error handling**: Match on specific error types rather than catching all errors
2. **Provide helpful messages**: Give users actionable information about what went wrong
3. **Use appropriate exit codes**: 
   - `0` for success
   - `1` for general errors
   - `2` for usage errors (wrong arguments/options)
4. **Let framework handle parsing**: Use command implementations instead of manual parsing when possible
5. **Clean up resources**: Always use `defer` for cleanup, especially for array options

## Examples

### Complete Command-Line Parser

For standalone parsing outside the framework, the unified entry point re-exported at the package root is `zcli.parseCommandLine` — it handles positionals and options together in a single pass:

```zig
const std = @import("std");
const zcli = @import("zcli");

const Args = struct {
    input: []const u8,
};

const Options = struct {
    verbose: bool = false,
    output: ?[]const u8 = null,
    threads: u32 = 1,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var diag: ?zcli.ZcliDiagnostic = null;
    const result = zcli.parseCommandLine(Args, Options, null, allocator, init.environ_map, args[1..], &diag) catch |err| switch (err) {
        error.SystemOutOfMemory => return error.SystemOutOfMemory,
        else => {
            if (diag) |d| {
                const msg = try zcli.formatDiagnostic(d, allocator);
                defer allocator.free(msg);
                std.debug.print("{s}\n", .{msg});
            } else {
                std.debug.print("Parse error: {}\n", .{err});
            }
            std.process.exit(2);
        },
    };
    defer result.deinit();

    if (result.options.verbose) {
        std.debug.print("Verbose mode enabled\n", .{});
    }
    if (result.options.output) |output| {
        std.debug.print("Output: {s}\n", .{output});
    }
    std.debug.print("Input: {s}, threads: {}\n", .{ result.args.input, result.options.threads });
}
```

## Summary

The zcli error handling system provides:
- ✅ **Standard Zig patterns** using error unions
- ✅ **Rich diagnostic information** for debugging
- ✅ **Framework integration** for automatic error handling
- ✅ **Memory safety** with clear cleanup patterns
- ✅ **User-friendly messages** with actionable information
- ✅ **Type safety** through compile-time validation

This approach ensures users get helpful error messages while developers work with familiar Zig error handling patterns.