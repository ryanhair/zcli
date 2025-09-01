# Plugin Architecture Proposal for zcli

## Executive Summary

After researching plugin systems in popular CLI frameworks (oclif, GitHub CLI, yargs, commander.js), I propose a constrained but powerful plugin system for zcli that balances simplicity with real-world flexibility.

## Current Issues

1. **Option Consumption Problem**: Plugins can "handle" options but can't remove them from the argument list, causing command routing failures
2. **Too Much Power**: Plugins can handle any option without registration, making behavior unpredictable
3. **No Transformation Capability**: Can't modify arguments before they reach commands
4. **Missing Lifecycle Hooks**: No pre/post command execution hooks

## Research Findings

### Successful Plugin Patterns

1. **Oclif**: Most robust system with commands, hooks, and nested plugins
   - Plugins export commands, hooks, or other plugins
   - Runtime plugin installation support
   - Strong TypeScript integration
   - Complex but powerful

2. **GitHub CLI**: Simple executable-based system
   - Extensions are separate executables with `gh-` prefix
   - Leverages existing authentication
   - No argument transformation - full ownership model
   - Very simple but limited to new commands

3. **Yargs**: Middleware-based system
   - Sequential middleware processing
   - Can transform arguments
   - No formal plugin architecture
   - Good for simple transformations

## Proposed Architecture

### Core Principles

1. **Explicit Registration**: Plugins must register what they handle
2. **Predictable Behavior**: Clear execution order and transformation rules
3. **Constrained Power**: Plugins can't arbitrarily intercept everything
4. **Compile-Time Safety**: Leverage Zig's comptime for type safety

### Plugin Capabilities

#### 1. Global Options Registration
```zig
pub const GlobalOption = struct {
    name: []const u8,
    short: ?u8 = null,
    type: type,
    default: anytype,
    description: []const u8,
};

pub const plugin = struct {
    pub const global_options = [_]GlobalOption{
        .{
            .name = "verbose",
            .short = 'v',
            .type = bool,
            .default = false,
            .description = "Enable verbose output",
        },
    };
    
    pub fn handleGlobalOption(
        context: *Context,
        option_name: []const u8,
        value: anytype,
    ) !void {
        if (std.mem.eql(u8, option_name, "verbose")) {
            context.setVerbosity(value);
        }
    }
};
```

#### 2. Lifecycle Hooks
```zig
pub const HookTiming = enum {
    pre_parse,      // Before argument parsing
    post_parse,     // After parsing, before command execution
    pre_execute,    // Right before command execution
    post_execute,   // After command execution
    on_error,       // When an error occurs
};

pub const plugin = struct {
    pub fn preExecute(
        context: *Context,
        command_path: []const u8,
        args: ParsedArgs,
    ) !?ParsedArgs {
        // Can transform args or return null to cancel execution
        return args;
    }
    
    pub fn onError(
        context: *Context,
        err: anyerror,
        command_path: []const u8,
    ) !void {
        // Handle errors (e.g., suggestions for typos)
    }
};
```

#### 3. Argument Transformation Pipeline
```zig
pub const TransformResult = struct {
    args: []const []const u8,
    consumed_indices: []const usize = &.{}, // Which args were consumed
    continue_processing: bool = true,
};

pub const plugin = struct {
    pub fn transformArgs(
        context: *Context,
        args: []const []const u8,
    ) !TransformResult {
        // Example: expand aliases
        if (args.len > 0 and std.mem.eql(u8, args[0], "co")) {
            var new_args = try context.allocator.alloc([]const u8, args.len);
            new_args[0] = "checkout";
            @memcpy(new_args[1..], args[1..]);
            return .{ .args = new_args };
        }
        return .{ .args = args };
    }
};
```

#### 4. Command Extensions (Not Overrides)
```zig
pub const plugin = struct {
    // Plugins can add new commands but not override existing ones
    pub const commands = [_]CommandRegistration{
        .{
            .path = "plugin.diagnostics",
            .handler = diagnosticsCommand,
        },
    };
    
    fn diagnosticsCommand(args: anytype, options: anytype, context: *Context) !void {
        // Plugin-specific command implementation
    }
};
```

### Execution Flow

```
1. Parse raw arguments
2. Run pre_parse hooks (can transform raw args)
3. Extract global options registered by plugins
4. Route to command
5. Run post_parse hooks (can transform parsed args)
6. Run pre_execute hooks (final transformation)
7. Execute command with transformed args
8. Run post_execute hooks
9. Handle any errors with on_error hooks
```

### Registration in Registry

```zig
const registry = zcli.Registry.init(config)
    .register("users.list", users_list)
    .registerPlugin(help_plugin)
    .registerPlugin(verbose_plugin)
    .registerPlugin(alias_plugin)
    .build();

// At compile time, the registry:
// 1. Collects all global options from plugins
// 2. Validates no conflicts
// 3. Generates parsing code that handles global options
// 4. Orders hooks by priority
```

## Real-World Use Cases

### 1. Help Plugin
```zig
pub const help_plugin = struct {
    pub const global_options = [_]GlobalOption{
        .{ .name = "help", .short = 'h', .type = bool, .default = false },
    };
    
    pub fn handleGlobalOption(context: *Context, name: []const u8, value: bool) !void {
        if (std.mem.eql(u8, name, "help") and value) {
            // Generate and display help
            try displayHelp(context);
            context.exit(0);
        }
    }
};
```

### 2. Verbose/Debug Plugin
```zig
pub const debug_plugin = struct {
    pub const global_options = [_]GlobalOption{
        .{ .name = "debug", .type = bool, .default = false },
        .{ .name = "verbose", .short = 'v', .type = u8, .default = 0 },
    };
    
    pub fn preExecute(context: *Context, path: []const u8, args: ParsedArgs) !?ParsedArgs {
        if (context.getGlobalOption("debug")) {
            try context.stdout().print("Executing: {s}\n", .{path});
            try context.stdout().print("Args: {any}\n", .{args});
        }
        return args;
    }
};
```

### 3. Alias Plugin
```zig
pub const alias_plugin = struct {
    const aliases = .{
        .{ "co", "checkout" },
        .{ "br", "branch" },
        .{ "ci", "commit" },
    };
    
    pub fn transformArgs(context: *Context, args: []const []const u8) !TransformResult {
        if (args.len == 0) return .{ .args = args };
        
        inline for (aliases) |alias_pair| {
            if (std.mem.eql(u8, args[0], alias_pair[0])) {
                var new_args = try context.allocator.dupe([]const u8, args);
                new_args[0] = alias_pair[1];
                return .{ .args = new_args };
            }
        }
        return .{ .args = args };
    }
};
```

### 4. Telemetry Plugin
```zig
pub const telemetry_plugin = struct {
    pub fn preExecute(context: *Context, path: []const u8, args: ParsedArgs) !?ParsedArgs {
        // Record command usage
        try recordUsage(path, args);
        return args;
    }
    
    pub fn postExecute(context: *Context, path: []const u8, success: bool) !void {
        // Record execution time and success
        try recordMetrics(path, success);
    }
};
```

## Benefits of This Approach

1. **Predictable**: Plugins must register what they handle
2. **Composable**: Multiple plugins can work together
3. **Type-Safe**: Compile-time validation of global options
4. **Flexible**: Supports transformation, lifecycle hooks, and extensions
5. **Simple**: Each plugin capability has a clear, focused purpose
6. **Performant**: Compile-time generation means no runtime overhead

## Migration Path

1. Keep existing plugin system working
2. Add new capabilities incrementally
3. Migrate existing plugins to new system
4. Deprecate old handleOption approach
5. Remove old system in major version

## Comparison with Alternatives

| Feature | Current zcli | Proposed zcli | oclif | GitHub CLI |
|---------|-------------|---------------|-------|------------|
| Global Options | No | Yes (registered) | Yes | No |
| Arg Transformation | No | Yes | Via middleware | No |
| Lifecycle Hooks | Limited | Full | Yes | No |
| Command Extensions | Yes | Yes | Yes | Yes |
| Runtime Plugins | No | No | Yes | Yes |
| Type Safety | Partial | Full | Partial | No |
| Complexity | Low | Medium | High | Low |

## Conclusion

This proposal provides a balanced approach that:
- Solves the current issues (option consumption, transformation)
- Remains simple and predictable
- Leverages Zig's compile-time capabilities
- Covers real-world use cases
- Maintains backward compatibility during migration

The key insight is that **constraining** the plugin system actually makes it more powerful by making behavior predictable and composable.