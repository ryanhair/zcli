# Build-Time Code Generation in zcli

This document explains how zcli's build-time code generation works, covering command discovery, plugin system, registry generation, and the resulting runtime behavior.

## Overview

zcli achieves zero runtime overhead by discovering commands and plugins, then generating dispatch code at build time. This eliminates the need for reflection, dynamic imports, or runtime file system scanning while providing a powerful plugin architecture.

## Build Process Flow

```
1. Command Discovery
   ├── Scan commands directory recursively
   ├── Validate command names and structure  
   ├── Build command tree with metadata
   └── Handle command groups and nesting

2. Plugin Discovery & Integration
   ├── Load external plugins from dependencies
   ├── Scan local plugins directory (optional)
   ├── Register plugin lifecycle hooks
   ├── Merge plugin commands with native commands
   └── Validate plugin compatibility

3. Registry Generation
   ├── Generate execution wrapper functions
   ├── Generate compile-time command registry
   ├── Wire plugin lifecycle hooks
   ├── Create module imports and dependencies
   └── Output complete registry source code

4. Compilation
   ├── Compile generated registry as a module
   ├── Link command modules with zcli
   ├── Generate static dispatch tables
   └── Produce final executable
```

## Plugin System Architecture

### Plugin Structure

Plugins use a lifecycle hook system with struct-based commands:

```zig
// Example plugin: zcli-help/src/plugin.zig
const std = @import("std");
const zcli = @import("zcli");

// Global options the plugin provides
pub const global_options = [_]zcli.GlobalOption{
    zcli.option("help", bool, .{ 
        .short = 'h', 
        .default = false, 
        .description = "Show help message" 
    }),
};

// Handle global options
pub fn handleGlobalOption(
    context: *zcli.Context,
    option_name: []const u8,
    value: anytype,
) !void {
    if (std.mem.eql(u8, option_name, "help") and value) {
        try context.setGlobalData("help_requested", "true");
    }
}

// Lifecycle hooks
pub fn preExecute(
    context: *zcli.Context,
    command_path: []const u8,
    args: zcli.ParsedArgs,
) !?zcli.ParsedArgs {
    const help_requested = context.getGlobalData([]const u8, "help_requested") orelse "false";
    if (std.mem.eql(u8, help_requested, "true")) {
        try showCommandHelp(context, command_path);
        return null; // Stop execution
    }
    return args; // Continue execution
}

pub fn onError(
    context: *zcli.Context,
    err: anyerror,
    command_path: []const u8,
) !void {
    if (err == error.CommandNotFound) {
        // Show suggestions
        try showSuggestions(context, command_path);
    }
}

// Commands provided by the plugin
pub const commands = struct {
    pub const help = struct {
        pub const Args = struct {
            command: ?[]const u8 = null,
        };
        pub const Options = struct {};
        pub const meta = .{
            .description = "Show help for commands",
        };
        
        pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
            if (args.command) |cmd| {
                try showCommandHelp(context, cmd);
            } else {
                try showAppHelp(context);
            }
        }
    };
};

// Optional context extension
pub const ContextExtension = struct {
    show_examples: bool = true,
    
    pub fn init(allocator: std.mem.Allocator) !@This() {
        return .{ .show_examples = true };
    }
    
    pub fn deinit(self: *@This()) void {
        _ = self;
    }
};
```

### Plugin Lifecycle Hooks

Plugins can implement any of these lifecycle hooks:

1. **`preParse`** - Called before argument parsing
2. **`postParse`** - Called after parsing, before command execution  
3. **`preExecute`** - Called right before command execution (can cancel)
4. **`postExecute`** - Called after command execution
5. **`onError`** - Called when an error occurs
6. **`handleGlobalOption`** - Called when global options are processed

### Plugin Integration

Plugins are integrated in `build.zig`:

```zig
const zcli_build = @import("zcli");

const cmd_registry = zcli_build.buildWithExternalPlugins(b, exe, zcli_module, .{
    .commands_dir = "src/commands",
    .plugins = &[_]zcli_build.PluginConfig{
        .{ .name = "zcli-help", .path = "../../plugins/zcli-help" },
        .{ .name = "zcli-version", .path = "../../plugins/zcli-version" },
        .{ .name = "zcli-not-found", .path = "../../plugins/zcli-not-found" },
    },
    .app_name = "myapp",
    .app_description = "My CLI application",
    // Note: Version is automatically read from build.zig.zon
});
```

## Command Discovery Process

### 1. Directory Scanning

The build system starts by scanning the configured commands directory:

```zig
// In build.zig
const cmd_registry = zcli_build.generateCommandRegistry(b, target, optimize, zcli_module, .{
    .commands_dir = "src/commands",  // Starting point
    .app_name = "myapp",
    .app_description = "My CLI app",
    // Note: Version is automatically read from build.zig.zon
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

### 1. Plugin Registry Integration

The generated registry includes plugin support:

```zig
// Generated registry structure with plugins
pub const registry = CompiledRegistry(config, commands, plugins).init();

// Plugin hooks are wired into execution flow
pub fn execute(self: *Self, args: []const []const u8) !void {
    var context = zcli.Context.init(allocator);
    defer context.deinit();
    
    // 1. Run preParse hooks
    var current_args = args;
    inline for (sorted_plugins) |Plugin| {
        if (@hasDecl(Plugin, "preParse")) {
            current_args = try Plugin.preParse(&context, current_args);
        }
    }
    
    // 2. Extract and handle global options
    const global_result = try self.parseGlobalOptions(&context, current_args);
    
    // 3. Route to command with lifecycle hooks
    try self.executeCommand(&context, global_result.remaining);
}
```

### 2. Plugin Command Integration

Plugin commands are discovered and integrated using comptime introspection:

```zig
// Plugin command discovery at compile time
inline for (plugins) |Plugin| {
    if (@hasDecl(Plugin, "commands")) {
        const cmd_info = @typeInfo(Plugin.commands);
        if (cmd_info == .@"struct") {
            inline for (cmd_info.@"struct".decls) |decl| {
                if (std.mem.eql(u8, decl.name, command_name)) {
                    const CommandModule = @field(Plugin.commands, decl.name);
                    
                    // Parse args/options like regular commands
                    const cmd_args = if (@hasDecl(CommandModule, "Args"))
                        try self.parseArgs(CommandModule.Args, parsed_args.positional)
                    else struct{}{};
                    
                    // Execute with full lifecycle support
                    try CommandModule.execute(cmd_args, cmd_options, context);
                }
            }
        }
    }
}
```

### 3. Context Extensions

Plugin context extensions are automatically managed:

```zig
// Generated context with plugin extensions
pub const Context = struct {
    allocator: std.mem.Allocator,
    io: zcli.IO,
    environment: zcli.Environment,
    plugin_extensions: ContextExtensions,
    
    // Plugin extensions are initialized automatically
    zcli_help: if (@hasDecl(zcli_help_plugin, "ContextExtension")) 
        zcli_help_plugin.ContextExtension 
    else 
        struct {},
};
```

## Runtime Behavior

### 1. Plugin Hook Execution

At runtime, plugins hooks are executed in priority order:

```zig
// Hooks execute in sorted priority order (higher first)
const sorted_plugins = blk: {
    // Sort plugins by priority at compile time
    var plugins_with_priority: [plugins.len]struct { type, i32 } = undefined;
    for (plugins, 0..) |Plugin, i| {
        plugins_with_priority[i] = .{ Plugin, getPriority(Plugin) };
    }
    
    // Bubble sort by priority (compile-time)
    // ... sorting logic ...
    
    break :blk result;
};
```

### 2. Zero Runtime Plugin Discovery

No plugin loading occurs at runtime:

- All plugins are known at compile time
- Plugin hooks are statically wired
- Command routing includes plugin commands
- Context extensions are pre-allocated

### 3. Type Safety

The plugin system maintains full type safety:

- Plugin command Args/Options are type-checked
- Lifecycle hook signatures are validated at compile time
- Context extensions are type-safe
- Invalid plugin structures cause compilation errors

## Plugin Development

### Creating a Plugin

1. **Create Plugin Structure**:
   ```
   my-plugin/
   ├── build.zig
   ├── build.zig.zon
   └── src/
       └── plugin.zig
   ```

2. **Implement Plugin Interface**:
   ```zig
   // Lifecycle hooks (optional)
   pub fn preParse(context: *zcli.Context, args: []const []const u8) ![]const []const u8
   pub fn postParse(context: *zcli.Context, command_path: []const u8, parsed_args: zcli.ParsedArgs) !?zcli.ParsedArgs  
   pub fn preExecute(context: *zcli.Context, command_path: []const u8, args: zcli.ParsedArgs) !?zcli.ParsedArgs
   pub fn postExecute(context: *zcli.Context, command_path: []const u8, success: bool) !void
   pub fn onError(context: *zcli.Context, err: anyerror, command_path: []const u8) !void
   
   // Global options (optional)
   pub const global_options = [_]zcli.GlobalOption{ ... };
   pub fn handleGlobalOption(context: *zcli.Context, option_name: []const u8, value: anytype) !void
   
   // Commands (optional)
   pub const commands = struct { ... };
   
   // Context extension (optional)
   pub const ContextExtension = struct { ... };
   ```

3. **Configure Build System**:
   ```zig
   // plugin build.zig
   const zcli_module = b.createModule(.{
       .root_source_file = b.path("../../src/zcli.zig"),
   });
   plugin_module.addImport("zcli", zcli_module);
   ```

### Plugin Distribution

Plugins can be distributed as:

1. **Local Plugins**: Included in the project repository
2. **External Dependencies**: Published packages in build.zig.zon
3. **Path-based**: Referenced by local file system path

## Built-in Plugins

### zcli-help Plugin

Provides comprehensive help system:
- Registers `--help` global option
- Provides `help` command
- Intercepts help requests in `preExecute` hook
- Shows command-specific and application help

### zcli-not-found Plugin  

Provides intelligent command suggestions:
- Implements `onError` hook for `CommandNotFound` errors
- Uses Levenshtein distance for suggestions
- Shows available commands when command not found

## Advanced Features

### 1. Plugin Priorities

Plugins can specify execution priority:

```zig
pub const priority: i32 = 100; // Higher values execute first
```

### 2. Plugin Conflict Detection

The build system validates:
- No duplicate command names between plugins
- No conflicting global option names
- Plugin dependency compatibility

### 3. Context Data Sharing

Plugins can share data through context:

```zig
// Store data
try context.setGlobalData("key", "value");

// Retrieve data  
const value = context.getGlobalData([]const u8, "key") orelse "default";
```

## Performance Characteristics

- **Build Time**: O(n + p) where n = commands, p = plugins
- **Runtime Dispatch**: O(1) for command lookup  
- **Plugin Hook Overhead**: O(h) where h = number of hooks (typically < 10)
- **Memory Usage**: Zero runtime plugin discovery overhead
- **Binary Size**: Only includes used plugin functionality

## Troubleshooting

### Common Plugin Issues

1. **Plugin Not Found**:
   - Check plugin path in build.zig
   - Verify build.zig.zon dependencies
   - Check plugin build.zig exports

2. **Hook Not Called**:
   - Verify hook function signature
   - Check plugin is registered
   - Ensure plugin priority is set correctly

3. **Context Extension Issues**:
   - Implement init/deinit methods
   - Check memory management
   - Verify type compatibility

This plugin-aware build system ensures zcli applications can be extended with powerful, type-safe plugins while maintaining zero runtime overhead.