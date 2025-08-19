# zcli Plugin Interface Contract

This document defines the interface contract for zcli plugins, ensuring compatibility and proper integration with the zcli framework.

## Plugin Structure

A zcli plugin is a Zig module that exports specific functions and types to extend zcli functionality. Plugins follow a transformer pattern, wrapping existing functionality to add new capabilities.

### Required Plugin File Structure

```
plugin-name/
├── build.zig           # Build configuration
├── build.zig.zon       # Dependencies
├── src/
│   ├── plugin.zig      # Main plugin implementation
│   └── ...             # Additional implementation files
└── README.md           # Plugin documentation
```

## Interface Contract

### Core Transformer Functions

Plugins can export one or more of these transformer functions:

#### 1. Command Transformer (`transformCommand`)

```zig
pub fn transformCommand(comptime next: anytype) type {
    return struct {
        pub fn execute(ctx: anytype, args: anytype) !void {
            // Pre-processing logic
            
            // Call next transformer in chain
            try next.execute(ctx, args);
            
            // Post-processing logic
        }
    };
}
```

**Contract Requirements:**
- Must accept a `comptime next: anytype` parameter
- Must return a type with an `execute` function
- `execute` must accept `(ctx: anytype, args: anytype)` parameters
- Must call `next.execute(ctx, args)` unless intentionally intercepting
- Must handle errors appropriately

#### 2. Error Transformer (`transformError`)

```zig
pub fn transformError(comptime next: anytype) type {
    return struct {
        pub fn handle(err: anyerror, ctx: anytype) !void {
            // Error handling logic
            
            // Optionally call next handler
            try next.handle(err, ctx);
        }
    };
}
```

**Contract Requirements:**
- Must accept a `comptime next: anytype` parameter
- Must return a type with a `handle` function
- `handle` must accept `(err: anyerror, ctx: anytype)` parameters
- Should call `next.handle(err, ctx)` unless fully handling the error
- Must propagate or transform errors appropriately

#### 3. Help Transformer (`transformHelp`)

```zig
pub fn transformHelp(comptime next: anytype) type {
    return struct {
        pub fn generate(ctx: anytype, command_name: ?[]const u8) ![]const u8 {
            // Get base help
            const base_help = try next.generate(ctx, command_name);
            defer ctx.allocator.free(base_help);
            
            // Enhance help content
            return enhanceHelp(ctx, base_help, command_name);
        }
    };
}
```

**Contract Requirements:**
- Must accept a `comptime next: anytype` parameter
- Must return a type with a `generate` function
- `generate` must accept `(ctx: anytype, command_name: ?[]const u8)` parameters
- Must return `![]const u8` (owned slice)
- Should call `next.generate()` to get base help
- Must manage memory properly (free base help, return owned slice)

### Context Extension (`ContextExtension`)

Plugins can extend the execution context with additional state:

```zig
pub const ContextExtension = struct {
    // Plugin-specific fields
    max_suggestions: usize,
    show_tips: bool,
    
    pub fn init(allocator: std.mem.Allocator) !@This() {
        _ = allocator; // Use if needed for initialization
        return .{
            .max_suggestions = 3,
            .show_tips = true,
        };
    }
    
    pub fn deinit(self: *@This()) void {
        _ = self; // Cleanup if needed
    }
};
```

**Contract Requirements:**
- Must provide `init(allocator: std.mem.Allocator) !@This()`
- Must provide `deinit(self: *@This()) void`
- `init` should handle allocation failures gracefully
- `deinit` must clean up all allocated resources
- Fields will be accessible as `ctx.plugin_name` in execution context

### Plugin Commands (`commands`)

Plugins can export additional commands:

```zig
pub const commands = struct {
    pub const help = struct {
        pub const meta = .{
            .description = "Show enhanced help information",
        };
        
        pub const Args = struct {
            command: ?[]const u8 = null,
        };
        
        pub const Options = struct {
            verbose: bool = false,
        };
        
        pub fn execute(args: Args, options: Options, ctx: anytype) !void {
            // Command implementation
        }
    };
};
```

**Contract Requirements:**
- Commands must follow standard zcli command structure
- Must provide `execute` function with proper signature
- Should include `meta` with description
- Args and Options are optional but recommended
- Command names must be valid Zig identifiers

## Context Interface Contract

### Required Context Fields

The execution context passed to plugins must provide:

```zig
// Core fields (always present)
allocator: std.mem.Allocator,
io: struct {
    stdout: std.fs.File.Writer,
    stderr: std.fs.File.Writer,
    stdin: std.fs.File.Reader,
},
app_name: []const u8,
app_version: []const u8,
app_description: []const u8,

// Plugin extension fields (dynamic)
plugin_name: PluginExtension, // If plugin exports ContextExtension
```

### Context Validation

Plugins should validate required context fields:

```zig
comptime {
    if (!@hasField(@TypeOf(ctx), "io")) {
        @compileError("Context must have 'io' field");
    }
    if (!@hasField(@TypeOf(ctx), "allocator")) {
        @compileError("Context must have 'allocator' field");
    }
}
```

## Memory Management Contract

### Allocation Responsibilities

1. **Plugin Context Extensions:**
   - Plugin owns memory allocated in `ContextExtension.init()`
   - Must clean up in `ContextExtension.deinit()`

2. **Command Arguments:**
   - Framework provides argument strings (not owned by plugin)
   - Plugin must not free argument strings

3. **Help Generation:**
   - Plugin must return owned help strings
   - Caller will free returned help content
   - Plugin must free any intermediate allocations

4. **Error Handling:**
   - Plugin should not allocate for error messages unless necessary
   - Use stack buffers or static strings when possible

### Allocation Failure Handling

Plugins must handle allocation failures gracefully:

```zig
const suggestions = findSimilarCommands(command, available, allocator) catch {
    // Fallback to simpler behavior on allocation failure
    try ctx.io.stderr.print("Command '{s}' not found\n", .{command});
    return;
};
defer allocator.free(suggestions);
```

## Error Handling Contract

### Error Propagation

1. **Command Transformers:**
   - Should propagate errors from `next.execute()` unless handling them
   - Can return new errors for plugin-specific failures

2. **Error Transformers:**
   - Should call `next.handle()` unless fully handling the error
   - Can transform errors into different error types
   - Must return the original or transformed error

3. **Help Transformers:**
   - Should propagate allocation errors
   - Can return simplified help on complex failures

### Error Types

Plugins should use appropriate error types:

```zig
// Standard zcli errors
error.CommandNotFound,
error.InvalidArgument,
error.MissingArgument,
error.InvalidOption,

// Plugin-specific errors (avoid if possible)
error.PluginConfigurationError,
```

## Testing Contract

### Required Tests

Plugins should include these test categories:

1. **Structure Tests:**
   ```zig
   test "plugin exports required functions" {
       try std.testing.expect(@hasDecl(@This(), "transformCommand"));
       // ... other exports
   }
   ```

2. **Context Extension Tests:**
   ```zig
   test "context extension lifecycle" {
       var ext = try ContextExtension.init(std.testing.allocator);
       defer ext.deinit();
       // Verify initialization
   }
   ```

3. **Allocation Failure Tests:**
   ```zig
   test "handles allocation failures" {
       var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, 0);
       // Test graceful degradation
   }
   ```

4. **Integration Tests:**
   ```zig
   test "transforms work with mock context" {
       // Test transformer functions with mock data
   }
   ```

## Plugin Discovery and Registration

### Build Integration

Plugins are discovered during build-time scanning:

1. Plugin dependencies are specified in `build.zig.zon`
2. Build script generates registry with plugin imports
3. Transformer chains are composed at compile-time

### Plugin Naming

- Plugin names should use kebab-case: `zcli-help`, `zcli-suggestions`
- Plugin variables use snake_case: `zcli_help`, `zcli_suggestions`
- Context extensions use plugin variable name as field name

## Compatibility Guidelines

### Version Compatibility

- Plugins should specify minimum zcli version in `build.zig.zon`
- Breaking changes in plugin interface require major version bump
- Plugins should gracefully handle missing context fields

### Performance Considerations

- Transformers add overhead to command execution
- Use comptime validation where possible
- Avoid allocations in hot paths
- Prefer stack allocation for small data

### Best Practices

1. **Minimal Interface:** Only export what's necessary
2. **Error Safety:** Handle all allocation and runtime failures
3. **Documentation:** Include comprehensive README and examples
4. **Testing:** Cover all code paths including failure cases
5. **Performance:** Profile and optimize critical paths

## Migration Guide

When updating plugins for new zcli versions:

1. Check for new required context fields
2. Update error handling patterns
3. Verify memory management compliance
4. Run full test suite including integration tests
5. Update documentation and examples

This interface contract ensures plugins remain compatible and maintainable as the zcli framework evolves.