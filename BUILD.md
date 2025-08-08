# Build-Time Code Generation in zcli

This document explains how zcli's build-time code generation works, covering command discovery, registry generation, and the resulting runtime behavior.

## Overview

zcli achieves zero runtime overhead by discovering commands and generating dispatch code at build time. This eliminates the need for reflection, dynamic imports, or runtime file system scanning.

## Build Process Flow

```
1. Command Discovery
   ├── Scan commands directory recursively
   ├── Validate command names and structure  
   ├── Build command tree with metadata
   └── Handle command groups and nesting

2. Registry Generation
   ├── Generate execution wrapper functions
   ├── Generate compile-time command registry
   ├── Create module imports and dependencies
   └── Output complete registry source code

3. Compilation
   ├── Compile generated registry as a module
   ├── Link command modules with zcli
   ├── Generate static dispatch tables
   └── Produce final executable
```

## Command Discovery Process

### 1. Directory Scanning

The build system starts by scanning the configured commands directory:

```zig
// In build.zig
const cmd_registry = zcli_build.generateCommandRegistry(b, target, optimize, zcli_module, .{
    .commands_dir = "src/commands",  // Starting point
    .app_name = "myapp",
    .app_version = "1.0.0", 
    .app_description = "My CLI app",
});
```

### 2. File Discovery

For each `.zig` file found, the build system:

- Removes the `.zig` extension to get the command name
- Validates the command name for security (no path traversal, special chars)
- Records the file path for module creation
- Builds a hierarchical command structure

### 3. Directory Processing

For each subdirectory found:

- Treats it as a command group if it contains `.zig` files
- Recursively scans up to a maximum depth (default: 6 levels)
- Looks for `index.zig` to determine if it's a valid group
- Skips empty directories automatically

### 4. Command Validation

Each discovered command is validated for:

- **Security**: No path traversal (`../`), hidden files (`.`), or shell injection
- **Naming**: Only alphanumeric, dash, and underscore characters
- **Structure**: Must be a valid Zig source file
- **Depth**: Must not exceed maximum nesting depth

## Registry Generation Process

### 1. Execution Function Generation

For each discovered command, zcli generates a wrapper function:

```zig
// Generated for src/commands/hello.zig
fn executehello(args: []const []const u8, allocator: std.mem.Allocator, context: *zcli.Context) !void {
    const command = @import("cmd_hello");
    
    // Parse options first if they exist
    const parsed_options = if (@hasDecl(command, "Options")) blk: {
        const command_meta = if (@hasDecl(command, "meta")) command.meta else null;
        const options_result = try zcli.parseOptionsWithMeta(command.Options, command_meta, allocator, args);
        remaining_args = args[options_result.result.next_arg_index..];
        break :blk options_result.options;
    } else .{};
    
    // Setup automatic cleanup for array fields
    defer if (@hasDecl(command, "Options")) {
        cleanupArrayOptions(command.Options, parsed_options, allocator);
    };
    
    // Parse remaining arguments
    const parsed_args = if (@hasDecl(command, "Args")) 
        try zcli.parseArgs(command.Args, remaining_args)
    else 
        .{};
    
    // Execute the command
    try command.execute(parsed_args, parsed_options, context);
}
```

### 2. Registry Structure Generation

The build system generates a compile-time registry structure:

```zig
// Generated registry structure
pub const registry = .{
    .commands = .{
        .hello = .{ 
            .module = @import("cmd_hello"), 
            .execute = executehello 
        },
        .users = .{
            ._is_group = true,
            ._index = .{ 
                .module = @import("users_index"), 
                .execute = executeusersindex 
            },
            .list = .{ 
                .module = @import("users_list"), 
                .execute = executeuserslist 
            },
            .create = .{ 
                .module = @import("users_create"), 
                .execute = executeuserscreate 
            },
        },
    },
};
```

### 3. Module Import Generation

Each discovered command gets its own module with proper imports:

```zig
// Generated module imports
const cmd_hello = b.addModule("cmd_hello", .{
    .root_source_file = b.path("src/commands/hello.zig"),
});
cmd_hello.addImport("zcli", zcli_module);
registry_module.addImport("cmd_hello", cmd_hello);
```

### 4. Memory Management Integration

The generated code includes automatic memory cleanup:

```zig
// Generated cleanup function
fn cleanupArrayOptions(comptime OptionsType: type, options: OptionsType, allocator: std.mem.Allocator) void {
    const type_info = @typeInfo(OptionsType);
    if (type_info != .@"struct") return;
    
    inline for (type_info.@"struct".fields) |field| {
        const field_value = @field(options, field.name);
        const field_type_info = @typeInfo(field.type);
        
        // Check if this is a slice type (array)
        if (field_type_info == .pointer and 
            field_type_info.pointer.size == .slice) {
            // Free the slice itself
            allocator.free(field_value);
        }
    }
}
```

## Runtime Behavior

### 1. Static Command Dispatch

At runtime, command routing uses compile-time generated switch statements:

```zig
// Generated routing logic (simplified)
inline for (@typeInfo(CommandsType).@"struct".fields) |field| {
    if (std.mem.eql(u8, field.name, command_name)) {
        const cmd = @field(commands, field.name);
        
        if (cmd._is_group) {
            try self.routeSubcommandComptime(cmd, args, command_name);
        } else {
            try self.executeCommand(cmd, args);
        }
        return;
    }
}
```

### 2. Zero Runtime Discovery

No file system operations or reflection occur at runtime:

- All commands are known at compile time
- Command routing uses static dispatch
- Help text is pre-generated where possible
- Module imports are resolved at compile time

### 3. Type Safety

The generated code maintains full type safety:

- Args structs are validated at compile time
- Options structs are type-checked during parsing
- Invalid command structures cause compilation errors
- Memory safety is enforced through Zig's type system

## Build System Integration

### 1. Build.zig Integration

The build system provides a simple integration point:

```zig
const zcli_build = @import("zcli");
const cmd_registry = zcli_build.generateCommandRegistry(b, target, optimize, zcli_module, .{
    .commands_dir = "src/commands",
    .app_name = "myapp", 
    .app_version = "1.0.0",
    .app_description = "Description",
});

exe.root_module.addImport("command_registry", cmd_registry);
```

### 2. Error Handling

Build-time errors provide detailed diagnostics:

- **Command Discovery Errors**: Invalid paths, access denied, missing directories
- **Registry Generation Errors**: Out of memory, invalid command structure
- **Validation Errors**: Invalid command names, excessive nesting, security violations

### 3. Caching and Performance

The build system is designed for efficiency:

- Command discovery results could be cached (future enhancement)
- Only scans directories when files change
- Generates minimal code for maximum performance
- Optimizes for common use cases

## Advanced Features

### 1. Command Groups

Nested command structures are fully supported:

```
src/commands/
├── hello.zig                    # myapp hello
├── users/
│   ├── index.zig               # myapp users (group help)
│   ├── list.zig                # myapp users list
│   ├── create.zig              # myapp users create
│   └── permissions/
│       ├── list.zig            # myapp users permissions list
│       └── grant.zig           # myapp users permissions grant
```

### 2. Special Name Handling

Commands with reserved names are handled automatically:

```zig
// Command named "test.zig" becomes:
.@"test" = .{ .module = @import("cmd_test"), .execute = executetest },
```

### 3. Security Features

Multiple security layers protect against attacks:

- Path traversal prevention in command names
- Directory depth limits
- Special character filtering
- Hidden file exclusion

## Troubleshooting

### Common Build Issues

1. **Commands Not Found**
   - Check `commands_dir` path in build.zig
   - Verify directory exists and contains .zig files
   - Check file permissions

2. **Invalid Command Names**
   - Remove special characters from filenames
   - Avoid hidden files (starting with .)
   - Don't use path separators in names

3. **Excessive Nesting**
   - Limit command groups to 6 levels deep
   - Flatten deeply nested structures
   - Use shorter path names

### Debugging Tips

1. **Enable Build Logging**
   ```zig
   std.log.info("Discovered {} commands", .{discovered.root.count()});
   ```

2. **Check Generated Registry**
   - Look in `zig-cache/` for generated files
   - Verify command_registry.zig contents
   - Check for compilation errors in generated code

3. **Validate Command Structure**
   - Ensure commands export required functions
   - Check Args/Options struct definitions
   - Verify meta constants are properly formed

## Performance Characteristics

- **Build Time**: O(n) where n = number of command files
- **Runtime Dispatch**: O(1) for command lookup
- **Memory Usage**: Zero runtime command metadata overhead
- **Binary Size**: Minimal - only includes used commands

## Future Enhancements

Potential improvements to the build system:

- Build caching based on file modification times
- Parallel command discovery for large projects  
- Advanced validation and linting during discovery
- Plugin system for custom command processors
- Integration with external documentation generators

This build-time approach ensures zcli applications have minimal runtime overhead while providing maximum developer convenience through automatic command discovery and type-safe code generation.