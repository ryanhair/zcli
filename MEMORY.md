# zcli Memory Management Guide

This document provides comprehensive guidance on memory management when using the zcli framework.

## Overview

The zcli framework is designed with memory safety as a core principle. Most memory management is handled automatically, but there are specific patterns you need to follow for certain operations.

## Memory Management Patterns

### 1. Automatic Memory Management (Framework Mode)

When using commands through the zcli framework (the typical usage), memory management is **completely automatic**:

```zig
// In your command file (e.g., src/commands/hello.zig)
pub const Options = struct {
    files: [][]const u8 = &.{},  // Array option
    verbose: bool = false,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    // Use options.files freely - cleanup is automatic
    for (options.files) |file| {
        try context.stdout().print("Processing: {s}\n", .{file});
    }
    // No cleanup needed - framework handles it automatically
}
```

**Why it works**: The zcli build system generates cleanup code that automatically calls `cleanupOptions` after each command execution.

### 2. Manual Memory Management (Direct API Usage)

When calling parsing functions directly, you must manage memory manually:

```zig
const std = @import("std");
const zcli = @import("zcli");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const Options = struct {
        files: [][]const u8 = &.{},
        verbose: bool = false,
    };
    
    const args = [_][]const u8{ "--files", "a.txt", "b.txt", "--verbose" };
    
    // Parse options - this allocates memory for array fields
    const result = try zcli.parseOptions(Options, allocator, &args);
    
    // CRITICAL: Always cleanup array options when done
    defer zcli.cleanupOptions(Options, result.options, allocator);
    
    // Use result.options safely here
    for (result.options.files) |file| {
        std.debug.print("File: {s}\n", .{file});
    }
}
```

## Memory Allocation Details

### What Gets Allocated

| Field Type | Memory Allocation | Cleanup Required |
|------------|------------------|------------------|
| `[]const u8` (strings) | **No allocation** - references args | ❌ No cleanup |
| `[][]const u8` (string arrays) | **Allocates slice** for array | ✅ `cleanupOptions` |
| `[]i32` (numeric arrays) | **Allocates slice** for array | ✅ `cleanupOptions` |
| `bool`, `i32`, `f64` (scalars) | **No allocation** - value types | ❌ No cleanup |
| `?T` (optionals) | **Same as T** | Same as T |

### Memory Ownership

```zig
const Options = struct {
    output: []const u8 = "",           // Points to args - no ownership
    files: [][]const u8 = &.{},       // Owns the slice, not the strings
    counts: []i32 = &.{},             // Owns the slice and integers
};

const args = [_][]const u8{ "--files", "a.txt", "b.txt", "--counts", "1", "2" };
const result = try zcli.parseOptions(Options, allocator, &args);
defer zcli.cleanupOptions(Options, result.options, allocator);

// Memory layout:
// result.options.files -> [ptr_to_"a.txt", ptr_to_"b.txt"]  (allocated slice)
//                          ↓             ↓
//                        "a.txt"       "b.txt"              (from args - not owned)
//
// result.options.counts -> [1, 2]                          (allocated slice + values)
```

## Lifetime Management

### Arguments Lifetime

Parsed arguments reference the original command-line arguments:

```zig
pub fn parseArgsExample() !void {
    const Args = struct {
        command: []const u8,
        files: [][]const u8,  // varargs
    };
    
    // CRITICAL: args must outlive parsed result
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);  // Free at end
    
    const parsed = try zcli.parseArgs(Args, args[1..]);
    
    // parsed.command and parsed.files[*] all point into args
    // Don't free args while using parsed!
    
    for (parsed.files) |file| {
        std.debug.print("File: {s}\n", .{file}); // Safe - args still alive
    }
    
    // args freed here via defer - parsed becomes invalid
}
```

### Context Allocator Usage

Commands can use the context allocator for temporary allocations:

```zig
pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    // Temporary allocation for command execution
    const buffer = try context.allocator.alloc(u8, 1024);
    defer context.allocator.free(buffer);  // Always free what you allocate
    
    // Use buffer for processing
    const formatted = try std.fmt.bufPrint(buffer, "Hello, {s}!", .{args.name});
    try context.stdout().print("{s}\n", .{formatted});
    
    // buffer freed automatically via defer
}
```

## Common Memory Patterns

### Pattern 1: Parse and Process

```zig
pub fn processOptions() !void {
    const result = try zcli.parseOptions(MyOptions, allocator, args);
    defer zcli.cleanupOptions(MyOptions, result.options, allocator);
    
    // Process immediately after parsing
    try processFiles(result.options.files);
}
```

### Pattern 2: Parse and Store

```zig
const Config = struct {
    files: [][]const u8,
    allocator: std.mem.Allocator,
    
    fn deinit(self: *Config) void {
        // Free the slice we allocated, not individual strings
        self.allocator.free(self.files);
    }
};

pub fn parseAndStore() !Config {
    const result = try zcli.parseOptions(MyOptions, allocator, args);
    // Don't defer cleanupOptions here - we're transferring ownership
    
    return Config{
        .files = result.options.files,  // Transfer ownership
        .allocator = allocator,
    };
}
```

### Pattern 3: Framework Command (No Manual Management)

```zig
// In src/commands/process.zig
pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    // Just use the options - framework handles all cleanup
    for (options.input_files) |file| {
        const content = try std.fs.cwd().readFileAlloc(
            context.allocator, 
            file, 
            1024 * 1024
        );
        defer context.allocator.free(content);  // Free what we allocate
        
        // Process content...
    }
    // options.input_files cleaned up automatically by framework
}
```

## Memory Safety Rules

### ✅ Safe Practices

1. **Always use `defer` for cleanup**:
   ```zig
   const result = try parseOptions(Options, allocator, args);
   defer cleanupOptions(Options, result.options, allocator);
   ```

2. **Keep args alive while using parsed results**:
   ```zig
   const args = try std.process.argsAlloc(allocator);
   defer std.process.argsFree(allocator, args);
   const parsed = try parseArgs(Args, args[1..]);
   // Use parsed here - args still alive
   ```

3. **Use context allocator for temporary allocations**:
   ```zig
   const temp = try context.allocator.alloc(u8, size);
   defer context.allocator.free(temp);
   ```

### ❌ Unsafe Practices

1. **Freeing args before using parsed results**:
   ```zig
   const args = try std.process.argsAlloc(allocator);
   const parsed = try parseArgs(Args, args[1..]);
   std.process.argsFree(allocator, args);  // ❌ DANGER!
   // parsed now contains dangling pointers
   ```

2. **Forgetting to cleanup array options**:
   ```zig
   const result = try parseOptions(Options, allocator, args);
   // ❌ Missing: defer cleanupOptions(Options, result.options, allocator);
   // Memory leak!
   ```

3. **Double-freeing or wrong allocator**:
   ```zig
   const result = try parseOptions(Options, allocator1, args);
   defer cleanupOptions(Options, result.options, allocator2);  // ❌ Wrong allocator!
   ```

## Debugging Memory Issues

### Memory Leaks

Use Zig's built-in leak detection:

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer {
    const leaked = gpa.deinit();
    if (leaked == .leak) {
        std.log.err("Memory leak detected!");
    }
}
```

### Valgrind Integration

For deeper analysis:

```bash
zig build -Doptimize=Debug
valgrind --tool=memcheck --leak-check=full ./zig-out/bin/myapp
```

### Common Leak Sources

1. **Array options without cleanup**
2. **Context allocator usage without defers**  
3. **Storing parsed results without proper ownership transfer**

## Performance Considerations

### Memory Allocation Overhead

- **String fields**: Zero allocation overhead (reference args)
- **Array fields**: One allocation per array field  
- **Argument parsing**: Zero allocation (references only)

### Optimization Tips

1. **Minimize array options** when possible
2. **Reuse Context allocator** for temporary work
3. **Use stack allocation** for small, fixed-size buffers
4. **Profile memory usage** in performance-critical paths

## Framework vs Direct Usage

### Framework Mode (Recommended)
- ✅ Automatic memory management
- ✅ Zero manual cleanup required
- ✅ Built-in safety guarantees
- ✅ Consistent patterns across commands

### Direct API Mode (Advanced)
- ⚠️ Manual memory management required
- ⚠️ Must follow cleanup patterns exactly
- ✅ Full control over memory usage
- ✅ Suitable for library integration

## Summary

The zcli framework prioritizes memory safety through:

1. **Automatic cleanup** in framework mode
2. **Clear ownership semantics** for direct API usage
3. **Minimal allocation strategy** (reference args when possible)
4. **Comprehensive documentation** of memory patterns

Follow the patterns in this guide, and memory management becomes straightforward and safe.