# Removal of `usingnamespace` from Plugin System

## Problem

The Zig language has deprecated `usingnamespace` as it can lead to confusing code and namespace pollution. Our plugin system was using `usingnamespace` to merge plugin commands into a single Commands struct.

## Solution

We've reworked the plugin command system to avoid `usingnamespace` entirely by:

1. **Separating native and plugin commands** into distinct namespaces
2. **Providing unified lookup functions** for command discovery
3. **Maintaining type safety** while avoiding namespace merging

## New Architecture

### Before (with `usingnamespace`)
```zig
pub const Commands = struct {
    // Native commands
    pub const hello = @import("cmd_hello");
    
    // Plugin commands merged with usingnamespace
    pub usingnamespace if (@hasDecl(auth, "commands")) auth.commands else struct {};
    pub usingnamespace if (@hasDecl(help, "commands")) help.commands else struct {};
};
```

### After (without `usingnamespace`)
```zig
// Native commands in their own struct
pub const Commands = struct {
    pub const hello = @import("cmd_hello");
    pub const goodbye = @import("cmd_goodbye");
};

// Plugin commands in a separate namespace
pub const PluginCommands = struct {
    pub const auth = if (@hasDecl(auth, "commands")) auth.commands else struct {};
    pub const help = if (@hasDecl(help, "commands")) help.commands else struct {};
};

// Unified lookup function
pub fn getCommand(comptime name: []const u8) ?type {
    // Check native commands first
    if (@hasDecl(Commands, name)) {
        return @field(Commands, name);
    }
    
    // Then check plugin commands
    if (@hasDecl(PluginCommands.auth, name)) {
        return @field(PluginCommands.auth, name);
    }
    // ... check other plugins
    
    return null;
}

// Get all command names for help/discovery
pub fn getAllCommandNames() []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        
        // Add native commands
        const native_info = @typeInfo(Commands);
        for (native_info.@"struct".decls) |decl| {
            names = names ++ .{decl.name};
        }
        
        // Add plugin commands
        // ... iterate plugin structs
        
        return names;
    }
}
```

## Benefits

1. **No deprecated features** - Future-proof against Zig language changes
2. **Clear separation** - Native vs plugin commands are clearly distinguished
3. **Type-safe lookup** - `getCommand()` returns optional type for safe usage
4. **Discovery support** - `getAllCommandNames()` enables help generation and command listing
5. **No namespace pollution** - Commands from different sources don't accidentally override each other

## Usage Example

```zig
// Looking up and executing a command
if (getCommand("hello")) |cmd| {
    cmd.execute(args, options, context);
}

// Getting all available commands for help
const all_commands = getAllCommandNames();
for (all_commands) |cmd_name| {
    std.debug.print("  {s}\n", .{cmd_name});
}
```

## Migration Notes

For users of the plugin system:
- Commands are still accessible through the same execution path
- The lookup mechanism is transparent to end users
- Plugin developers don't need to change their plugin structure

For zcli internals:
- Command routing now uses `getCommand()` instead of direct field access
- Help generation uses `getAllCommandNames()` for command discovery
- The separation allows for future enhancements like command priorities or conflict resolution

## Testing

All existing tests pass with the new architecture. Additional tests verify:
- Command lookup works for both native and plugin commands
- `getAllCommandNames()` returns complete command list
- No namespace conflicts occur
- System works correctly with no plugins