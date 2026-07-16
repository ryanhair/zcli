# Build-Time Code Generation in zcli

This document explains how zcli's build-time code generation works, covering command discovery, plugin system, registry generation, and the resulting runtime behavior.

## Overview

zcli achieves zero-cost dispatch by discovering commands and plugins, then generating routing code at build time. This eliminates the need for reflection, dynamic imports, or runtime file system scanning while providing a powerful plugin architecture. (Argument parsing for the matched command still runs at invocation, type-checked via comptime introspection.)

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
// Example plugin: zcli_help/plugin.zig
const std = @import("std");
const zcli = @import("zcli");

// Unique id — names this plugin's field in `context.plugins.<plugin_id>`.
pub const plugin_id = "zcli_help";

// Type-safe per-run state, stored at `context.plugins.zcli_help`. There are no
// string keys or runtime lookups: the generated Context has one typed field per
// plugin that declares a ContextData struct (must be default-constructible).
pub const ContextData = struct {
    help_requested: bool = false,
};

// Global options the plugin provides
pub const global_options = [_]zcli.GlobalOption{
    zcli.option("help", bool, .{ 
        .short = 'h', 
        .default = false, 
        .description = "Show help message" 
    }),
};

// Handle global options. `context` is `anytype`: a plugin is compiled
// independently of the app that hosts it, so it can't name the app's
// generated Context type.
pub fn handleGlobalOption(
    context: anytype,
    option_name: []const u8,
    value: anytype,
) !void {
    if (std.mem.eql(u8, option_name, "help")) {
        const enabled = if (@TypeOf(value) == bool) value else false;
        if (enabled) context.plugins.zcli_help.help_requested = true;
    }
}

// Lifecycle hook: runs right before the command. Return null to stop execution.
pub fn preExecute(
    context: anytype,
    args: zcli.ParsedArgs,
) !?zcli.ParsedArgs {
    if (context.plugins.zcli_help.help_requested) {
        try showHelp(context, context.command_path);
        return null; // Stop execution
    }
    return args; // Continue execution
}

// Lifecycle hook: handle an error. Return true if handled (suppresses it).
pub fn onError(
    context: anytype,
    err: anyerror,
) !bool {
    if (err == error.CommandNotFound) {
        try showSuggestions(context, context.command_path);
        return true; // Error handled, don't let it propagate
    }
    return false;
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
        
        pub fn execute(args: Args, options: Options, context: anytype) !void {
            if (args.command) |cmd| {
                try showCommandHelp(context, cmd);
            } else {
                try showAppHelp(context);
            }
        }
    };
};

// Optional setup hook for ContextData, called once per invocation before any
// lifecycle hook. Capture references off `context` (allocator, io, app_name,
// environ, streams) so `context.plugins.<plugin_id>` methods can serve calls
// without re-threading `context`. Pairs with deinitContextData below.
pub fn initContextData(data: *ContextData, context: anytype) !void {
    _ = data;
    _ = context;
}

// Optional cleanup hook for ContextData, called from Context.deinit().
// Only needed when ContextData owns resources (allocations, handles, etc.).
// Runs whether or not initContextData ran, so it must be safe on default data.
pub fn deinitContextData(data: *ContextData, allocator: std.mem.Allocator) void {
    _ = data;
    _ = allocator;
}
```

### Plugin Lifecycle Hooks

Plugins can implement any of these lifecycle hooks:

1. **`onStartup`** - Called once per invocation, after plugin data is captured but before argument parsing/routing (for one-time work like update checks)
2. **`preParse`** - Called before argument parsing
3. **`postParse`** - Called after parsing, before command execution  
4. **`preExecute`** - Called right before command execution (can cancel)
5. **`postExecute`** - Called after command execution
6. **`onError`** - Called when an error occurs
7. **`handleGlobalOption`** - Called when global options are processed

### Plugin Integration

Plugins are registered in `build.zig` one of three ways:

- **Built-ins** that ship with zcli — use `zcli.builtin(<tag>, .{...})`.
- **Third-party plugins shipped as their own Zig package** — depend on the
  package with `b.dependency(...)` and pass it as `.dependency`. The package
  must expose a module named `plugin`; see `examples/ext-plugin` for a complete
  package + consumer pair.
- **Project-local plugins** living in your own source tree — drop them under
  `.plugins_dir` and they're auto-discovered (they are *not* listed in
  `.plugins`). See ADR-0006.

```zig
const zcli = @import("zcli");

// A third-party plugin shipped as its own Zig package.
const greet_plugin_dep = b.dependency("greet_plugin", .{ .target = target, .optimize = optimize });

const cmd_registry = try zcli.generate(b, exe, zcli_dep, .{
    .commands_dir = "src/commands",
    .plugins = &.{
        zcli.builtin(.help, .{}),
        zcli.builtin(.version, .{}),
        zcli.builtin(.not_found, .{}),
        // External-package plugin: pass the dependency, not a path.
        .{ .name = "greet", .dependency = greet_plugin_dep },
    },
    // Project-local plugins under this directory are auto-discovered.
    .plugins_dir = "src/plugins",
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
const cmd_registry = try zcli.generate(b, exe, zcli_dep, .{
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
- Skips underscore-prefixed files and directories (helper code for commands to import, e.g. `_wizard.zig`)

### 4. Command Validation

Each discovered command is validated for:

- **Security**: No path traversal (`../`), hidden files (`.`), or shell injection
- **Naming**: Only alphanumeric, dash, and underscore characters
- **Structure**: Must be a valid Zig source file
- **Depth**: Must not exceed maximum nesting depth

## Sharing Code Between Commands

Each discovered command file is compiled as its **own module rooted at that
file**. A relative import of a sibling therefore reaches outside the module and
fails to compile:

```zig
// in src/commands/tags.zig
const registry = @import("../registry.zig");
// error: import of file outside module path
```

Instead, declare the shared code as a module once and register it via
`shared_modules`; every command can then import it by name:

```zig
// build.zig
const store_module = b.createModule(.{
    .root_source_file = b.path("src/store.zig"),
    .target = target,
    .optimize = optimize,
});

const cmd_registry = try zcli.generate(b, exe, zcli_dep, .{
    .commands_dir = "src/commands",
    .shared_modules = &[_]zcli.SharedModule{
        .{ .name = "store", .module = store_module },
    },
    // ...
});
```

```zig
// in any command:
const store = @import("store");
```

Pass the **same** `shared_modules` list to `addCommandTests` as well. The
command-test stub only wires the shared modules you hand it, so a command that
imports one won't compile under `zig build test` otherwise:

```zig
_ = zcli.addCommandTests(b, exe, zcli_dep, .{
    .commands_dir = "src/commands",
    .target = target,
    .optimize = optimize,
    .shared_modules = &[_]zcli.SharedModule{
        .{ .name = "store", .module = store_module },
    },
});
```

See `examples/tasks` for a full, compiling example (the `store` module shared
across its commands).

## Command Unit Tests (`addCommandTests`)

`zcli.addCommandTests` (`packages/core/src/build_utils/command_tests.zig`) is
the build-time entry point behind the `zig build test` step that a scaffolded
project ships with. It discovers every command file under `commands_dir` and
compiles each as its own in-process test binary, so a command's `test` blocks
(typically using `zcli-testing`'s `runCommand`) actually run — without pulling
in the whole generated app.

`exe` is the project's real executable (the same one passed to `generate()`);
the returned `test` step depends on it so `zig build test` also proves the
real registry/main.zig link — on every OS the test job runs on, not just
wherever someone happens to run `zig build build-examples`/install the exe.

```zig
pub fn addCommandTests(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    zcli_dep: *std.Build.Dependency,
    config: zcli.CommandTestsConfig,
) *std.Build.Step
```

`CommandTestsConfig`:

```zig
pub const CommandTestsConfig = struct {
    commands_dir: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    // Same list passed to `generate()`, so command imports resolve identically
    // under test.
    shared_modules: []const SharedModule = &.{},
    // Same `plugins_dir` passed to `generate()`, so the stub Context includes
    // the project's local plugins.
    plugins_dir: ?[]const u8 = null,
};
```

Each discovered command compiles against a *stub* `command_registry` module
(`Context = zcli.TestContext(&.{...})`, built from the project's local plugins
plus an in-memory `zcli_secrets` stand-in) rather than the real generated
registry — a command's tests must not require the whole app to compile.

```zig
// build.zig
_ = zcli.addCommandTests(b, exe, zcli_dep, .{
    .commands_dir = "src/commands",
    .target = target,
    .optimize = optimize,
    .plugins_dir = "src/plugins",
    .shared_modules = &shared_modules,
});
```

Returns the created `test` step (registered as `zig build test`) so the caller
can attach more tests to it. `zcli init` wires this automatically in every
scaffolded project; see `projects/zcli/src/commands/init.zig` for the generated
`build.zig` template. For the testing API itself (`runCommand`, VTerm
assertions, integration/E2E tiers), see [TESTING.md](TESTING.md).

## Documentation Generation (`generateDocs`)

`zcli.generateDocs` (`packages/core/src/build_utils/main.zig`) wires a `zig
build docs` step that renders command help (from the same `meta`/`Args`/
`Options` data the registry uses) to files on disk. It is opt-in and kept off
the default `install`/`test` steps, so an ordinary `zig build` produces no doc
output.

```zig
pub fn generateDocs(
    b: *std.Build,
    registry_module: *std.Build.Module,
    zcli_dep: *std.Build.Dependency,
    config: zcli.DocsConfig,
) void
```

`DocsConfig`:

```zig
pub const DocsConfig = struct {
    // Formats to generate; each gets its own subdirectory under output_dir.
    formats: []const []const u8 = &.{"markdown"},
    output_dir: []const u8 = "docs",
};
```

```zig
// build.zig — after cmd_registry is created by generate()
// Single format (default: markdown)
zcli.generateDocs(b, cmd_registry, zcli_dep, .{});

// Multiple formats — each gets its own subdirectory
zcli.generateDocs(b, cmd_registry, zcli_dep, .{
    .formats = &.{ "markdown", "man" },
    .output_dir = "docs",
});
```

Run it with `zig build docs`. Under the hood this builds and runs a small
host-target `zcli-doc-gen` executable (`packages/core/src/doc_gen_main.zig`)
against your `cmd_registry` module.

## Registry Generation Process

### 1. Plugin Registry Integration

The generated registry includes plugin support:

```zig
// Generated registry structure with plugins
pub const registry = CompiledRegistry(config, commands, plugins).init();

// Plugin hooks are wired into execution flow
pub fn execute(self: *Self, args: []const []const u8) !void {
    // Context is the per-app computed type; each plugin's ContextData is
    // default-initialized under `context.plugins.<plugin_id>`.
    var context = Context.init(allocator, io, environ);
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

### 3. Type-Safe Context Data

Each plugin's `ContextData` becomes a typed field on the generated `Context`,
nested under `plugins` and named by the plugin's `plugin_id`. The field type and
name are computed at compile time (see `ContextFor` in
`packages/core/src/context.zig`) — there is no `StringHashMap` or runtime key
lookup, so access is fully typed:

```zig
// Generated context (conceptually):
pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io, // the framework's std.Io; do I/O via context.stdout()/stderr()/stdin()
    // ... app metadata, command path, etc. ...

    // One field per plugin that declares ContextData, named by plugin_id:
    plugins: struct {
        zcli_help: zcli_help.ContextData = .{},
        // ... other plugins ...
    } = .{},
};

// Access from any hook or command:
if (context.plugins.zcli_help.help_requested) { ... }
```

Each `ContextData` must be default-constructible; the generated `Context`
initializes every plugin's field to `.{}`. If a plugin declares
`deinitContextData`, it is called from `Context.deinit()` for cleanup.

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
- Plugin context data is part of the computed Context, initialized inline

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
   // Lifecycle hooks (optional). `context` is `anytype` — plugins are compiled
   // independently of the host app, so they can't name its Context type.
   pub fn preParse(context: anytype, args: []const []const u8) ![]const []const u8
   pub fn postParse(context: anytype, parsed_args: zcli.ParsedArgs) !?zcli.ParsedArgs
   pub fn preExecute(context: anytype, args: zcli.ParsedArgs) !?zcli.ParsedArgs
   pub fn postExecute(context: anytype, success: bool) !void
   pub fn onError(context: anytype, err: anyerror) !bool

   // Global options (optional)
   pub const global_options = [_]zcli.GlobalOption{ ... };
   pub fn handleGlobalOption(context: anytype, option_name: []const u8, value: anytype) !void

   // Commands (optional)
   pub const commands = struct { ... };

   // Type-safe context data (optional)
   pub const plugin_id = "my_plugin";
   pub const ContextData = struct { ... };
   pub fn deinitContextData(data: *ContextData, allocator: std.mem.Allocator) void { ... }
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

### zcli_help Plugin

Provides comprehensive help system:
- Registers `--help` global option
- Provides `help` command
- Intercepts help requests in `preExecute` hook
- Shows command-specific and application help

### zcli_not_found Plugin  

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

Plugins expose state through their own `ContextData`, accessed by `plugin_id`.
Because every plugin's data is a typed field on the shared `Context`, one plugin
(or a command) can read another's state directly — no string keys, no casts:

```zig
// Store data (e.g. in handleGlobalOption / preExecute)
context.plugins.my_plugin.enabled = true;

// Retrieve data (from any other hook or command)
const enabled = context.plugins.my_plugin.enabled;
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

This plugin-aware build system ensures zcli applications can be extended with powerful, type-safe plugins while maintaining zero-cost dispatch.