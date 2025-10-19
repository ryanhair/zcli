# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**zcli** is a Zig framework for building beautiful command-line interfaces with:

- **Build-time command discovery**: Automatically scans directories and generates type-safe routing
- **Plugin system**: Extensible architecture with lifecycle hooks and build-time configuration
- **Type-safe argument parsing**: Compile-time validation of commands, args, and options
- **Zero runtime overhead**: Everything resolved at compile time

### Key Principle

zcli uses **comptime metaprogramming** extensively. Commands are discovered by scanning the filesystem at build time, while plugins are explicitly configured. This hybrid approach balances automation with control.

---

## Zig Standards

- **Unused parameters**: Set to `_` directly in function declaration, not `_ = param`

  ```zig
  // Good
  pub fn execute(_: Args, options: Options, context: *Context) !void

  // Bad
  pub fn execute(args: Args, options: Options, context: *Context) !void {
      _ = args;
  }
  ```

- **Tests**: Unit tests belong in the source file being tested. Integration/e2e tests can be separate.

- **Type info access**: Use lowercase field names with `@"struct"` syntax:

  ```zig
  // Good
  switch (@typeInfo(T)) {
      .@"struct" => |s| s.fields,
      .pointer => |p| p.child,
  }

  // Bad
  switch (@typeInfo(T)) {
      .Struct => |s| s.fields,  // Wrong - uppercase doesn't exist
  }
  ```

---

## Architecture Overview

### Repository Structure

```
zcli/
├── packages/
│   ├── core/                      # Main zcli framework
│   │   ├── src/
│   │   │   ├── zcli.zig          # Public API
│   │   │   ├── registry.zig       # Command routing and plugin orchestration
│   │   │   ├── args.zig           # Argument parsing
│   │   │   ├── options.zig        # Option parsing
│   │   │   └── build_utils/       # Build system (code generation)
│   │   │       ├── main.zig       # Entry point: generate()
│   │   │       ├── types.zig      # Shared build types
│   │   │       ├── discovery.zig  # Filesystem scanning
│   │   │       ├── code_generation.zig  # Registry code generation
│   │   │       └── module_creation.zig  # Zig module setup
│   │   └── plugins/               # Core plugins
│   │       ├── zcli-help/
│   │       ├── zcli-not-found/
│   │       └── zcli-github-upgrade/
│   └── markdown_fmt/              # Markdown formatting utility
└── projects/
    └── zcli/                      # The zcli meta-CLI tool itself
        ├── src/commands/          # Commands for scaffolding projects
        │   ├── init.zig
        │   ├── add/
        │   │   ├── index.zig      # Metadata-only group
        │   │   └── command.zig
        │   └── gh/
        │       ├── index.zig      # Metadata-only group
        │       └── add/
        │           └── workflow/
        │               └── release.zig
        └── build.zig
```

---

## Build System Architecture

### How It Works

The build system has two distinct phases that use different techniques:

#### 1. Command Discovery (Dynamic - Filesystem Scanning)

**Why**: Users organize commands in directories; we discover them automatically.

**Process**:

1. `discovery.zig` scans `commands_dir` at build time
2. Finds `.zig` files and `index.zig` files
3. Builds a tree structure of command paths
4. Generates routing code as a **string**
5. Writes string to `.zig` file via `b.addWriteFiles()`

**Key files**: `packages/core/src/build_utils/discovery.zig`, `code_generation.zig`

#### 2. Plugin Registration (Static - Explicit Configuration)

**Why**: Plugins are explicitly listed in `build.zig`, so we know them at comptime.

**Process**:

1. User provides plugin configs in `generate()` call
2. `configToInitString()` introspects config structs at **comptime**
3. Generates initialization calls as strings: `.init(.{ .repo = "user/repo" })`
4. Plugins imported and registered in generated code

**Key insight**: We use `anytype` + comptime introspection, NOT runtime string building.

### The `generate()` Function

Located in `packages/core/src/build_utils/main.zig`:

```zig
pub fn generate(b: *std.Build, exe: *std.Build.Step.Compile, zcli_module: *std.Build.Module, config: anytype) *std.Build.Module
```

**Parameters**:

- `config: anytype` - Accepts any struct with required fields:
  - `commands_dir: []const u8`
  - `plugins: []const PluginConfigLike` (where each has `.name`, `.path`, optional `.config`)
  - `shared_modules: ?[]const SharedModule` (optional - modules available to all commands)
  - `app_name: []const u8`
  - `app_version: []const u8`
  - `app_description: []const u8`

**Returns**: A module containing the generated registry

**Example usage**:

```zig
const cmd_registry = zcli.generate(b, exe, zcli_module, .{
    .commands_dir = "src/commands",
    .plugins = &.{
        .{
            .name = "zcli-help",
            .path = "../../packages/core/plugins/zcli-help",
        },
        .{
            .name = "zcli-github-upgrade",
            .path = "../../packages/core/plugins/zcli-github-upgrade",
            .config = .{
                .repo = "username/repo",
                .command_name = "upgrade",
            },
        },
    },
    .app_name = "myapp",
    .app_version = "1.0.0",
    .app_description = "My CLI app",
});
```

### Build-Time Plugin Configuration

Plugins can accept build-time configuration through the `.config` field:

**In build.zig**:

```zig
.plugins = &.{
    .{
        .name = "my-plugin",
        .path = "path/to/plugin",
        .config = .{
            .setting1 = "value",
            .setting2 = true,
        },
    },
}
```

**In plugin code**:

```zig
pub fn init(config: Config) type {
    return struct {
        pub const commands = struct {
            pub const mycommand = struct {
                pub const meta = .{ .description = config.description };
                pub fn execute(args: Args, options: Options, ctx: *zcli.Context) !void {
                    // Use config values
                }
            };
        };
    };
}
```

**How it works**:

1. `inline for` loop in `generate()` makes configs available at comptime
2. `configToInitString()` introspects the config struct
3. Generates code like: `const plugin = @import("plugin").init(.{.setting1 = "value", .setting2 = true});`
4. This becomes part of the generated registry file

**Supported config types**: Strings (`[]const u8`), bools, integers. Extend `configToInitString()` for other types.

### Shared Modules

**Purpose**: Share code (business logic, data structures, utilities) across multiple commands.

**Problem solved**: Commands are compiled as isolated modules and by default can only import `std` and `zcli`. Shared modules allow commands to import project-specific code without duplication.

**Usage**:

```zig
// build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zcli_dep = b.dependency("zcli", .{ .target = target, .optimize = optimize });
    const zcli_module = zcli_dep.module("zcli");

    // Create shared modules
    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const format_module = b.createModule(.{
        .root_source_file = b.path("src/format.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("zcli", zcli_module);
    exe.root_module.addImport("lib", lib_module);
    exe.root_module.addImport("format", format_module);

    const zcli = @import("zcli");
    const cmd_registry = zcli.generate(b, exe, zcli_dep, zcli_module, .{
        .commands_dir = "src/commands",
        .plugins = &[_]zcli.PluginConfig{ /* ... */ },
        .shared_modules = &[_]zcli.SharedModule{
            .{ .name = "lib", .module = lib_module },
            .{ .name = "format", .module = format_module },
        },
        .app_name = "myapp",
        .app_version = "1.0.0",
        .app_description = "My application",
    });

    exe.root_module.addImport("command_registry", cmd_registry);
    b.installArtifact(exe);
}
```

**In commands**:

```zig
// src/commands/summary.zig
const std = @import("std");
const zcli = @import("zcli");
const lib = @import("lib");      // Shared module
const format = @import("format"); // Shared module

pub const meta = .{
    .description = "Show summary statistics",
};

pub const Args = struct {};
pub const Options = struct {};

pub fn execute(_: Args, _: Options, context: *zcli.Context) !void {
    const stdout = context.stdout();

    // Use shared module functions
    const stats = try lib.calculateStats(context.allocator);
    const output = try format.formatStats(stats);

    try stdout.print("{s}\n", .{output});
}
```

**Key points**:
- Shared modules must be created with `b.createModule()` before passing to `generate()`
- The same module should be added to both `exe.root_module` and `shared_modules` array
- All commands will have access to all shared modules
- Modules can have their own dependencies (transitive imports work)

**When to use**:
- Business logic shared across commands (data processing, calculations)
- Data structures and type definitions
- API clients or database interfaces
- Utility functions and helpers
- Parsers and formatters

**Example project structure**:
```
src/
├── main.zig                 # Entry point
├── lib.zig                  # Business logic (shared module)
├── format.zig               # Formatters (shared module)
├── cache.zig                # Caching layer (shared module)
└── commands/
    ├── summary.zig          # Imports lib, format
    ├── details.zig          # Imports lib, format
    └── clear.zig            # Imports cache
```

---

## Plugin System

### Plugin Anatomy

Plugins can provide:

1. **Lifecycle hooks**: `preExecute`, `onError`, `onStartup`
2. **Global options**: Available to all commands
3. **Commands**: Regular commands like any other
4. **Context extensions**: Add custom data to the context

### Lifecycle Hooks

```zig
/// Called before every command execution
pub fn preExecute(context: *zcli.Context, args: zcli.ParsedArgs) !?zcli.ParsedArgs {
    // Return null to stop execution
    // Return args to continue
}

/// Called when an error occurs
pub fn onError(context: *zcli.Context, err: anyerror) !bool {
    // Return true if error handled
    // Return false to let it propagate
}

/// Called once at startup
pub fn onStartup(context: *zcli.Context) !void {
    // Initialize plugin state
}
```

### Plugin Commands

Plugins export commands via a `commands` struct:

```zig
pub const commands = struct {
    pub const mycommand = struct {
        pub const meta = .{
            .description = "My command description",
            .examples = &.{ "myapp mycommand --flag" },
        };

        pub const Args = struct { /* positional args */ };
        pub const Options = struct { /* --flags */ };

        pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
            // Command logic
        }
    };
};
```

### Global Options

```zig
pub const global_options = [_]zcli.GlobalOption{
    zcli.option("verbose", bool, .{ .short = 'v', .default = false }),
};

pub fn handleGlobalOption(context: *zcli.Context, option_name: []const u8, value: anytype) !void {
    if (std.mem.eql(u8, option_name, "verbose")) {
        // Store in context
        try context.setGlobalData("verbose", if (value) "true" else "false");
    }
}
```

### Example: Help Plugin

See `packages/core/plugins/zcli-help/src/plugin.zig` for a complete example showing:

- Global option (`--help`)
- Hook usage (`preExecute`, `onError`)
- Command group help
- No commands provided (hooks only)

### Example: Upgrade Plugin

See `packages/core/plugins/zcli-github-upgrade/src/plugin.zig` for:

- Build-time configuration via `init()`
- Providing a command
- Startup hook for version checking

---

## Command Structure

### File-based Commands

**Location**: `src/commands/mycommand.zig`

**Structure**:

```zig
const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Command description",
    .examples = &.{
        "myapp mycommand arg1 arg2",
        "myapp mycommand --flag value",
    },
};

pub const Args = struct {
    name: []const u8,
    path: []const u8,
};

pub const Options = struct {
    verbose: bool = false,
    count: u32 = 1,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    const stdout = context.stdout();
    try stdout.print("Hello {s} from {s}\n", .{ args.name, args.path });

    if (options.verbose) {
        try stdout.print("Count: {d}\n", .{options.count});
    }
}
```

### Nested Commands

**Directory structure**:

```
src/commands/
├── users/
│   ├── list.zig    → "users list"
│   ├── create.zig  → "users create"
│   └── delete.zig  → "users delete"
```

**Automatic routing**: The build system creates `"users list"`, `"users create"`, etc.

### Command Groups

zcli supports three types of command groups:

#### 1. Pure Groups (No `index.zig`)

Directories without `index.zig` are purely organizational. They don't execute and show no description in help.

```
src/commands/
├── users/
│   ├── list.zig    → "users list"
│   └── create.zig  → "users create"
```

Running `myapp users` → Shows help listing `list` and `create` subcommands.

#### 2. Metadata-Only Groups (`index.zig` with only `meta`)

Optional groups can provide just metadata (description) without being executable:

```zig
// src/commands/users/index.zig
pub const meta = .{
    .description = "Manage users in the system",
};
```

**Behavior**:

- Running `myapp users` → Shows help for subcommands (same as pure groups)
- Running `myapp users --help` → Shows description and subcommands
- Help listings show the description: `users          Manage users in the system`
- No `execute`, `Args`, or `Options` required

**When to use**: Organize related commands with a clear description without adding executable behavior.

#### 3. Executable Groups (`index.zig` with `execute`)

Full command groups that can be executed directly:

```zig
// src/commands/users/index.zig
pub const meta = .{
    .description = "Manage users in the system",
};

pub const Args = struct {};
pub const Options = struct { all: bool = false };

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    // Handles: myapp users
    // Custom logic when called without subcommand
}
```

**Behavior**:

- Running `myapp users` → Executes the `index.zig` command
- Running `myapp users list` → Routes to the `list` subcommand

**When to use**: The parent command should do something meaningful on its own (e.g., `git` shows status, `docker` shows version).

### Real-World Example: zcli Project Structure

The `projects/zcli` tool demonstrates all three group types:

```
src/commands/
├── init.zig                           # Leaf command: "zcli init"
├── add/                               # Metadata-only group
│   ├── index.zig                      # meta = "Add commands and plugins..."
│   └── command.zig                    # Leaf: "zcli add command"
└── gh/                                # Metadata-only group
    ├── index.zig                      # meta = "Add GitHub-related features..."
    └── add/                           # Pure group (no index.zig)
        └── workflow/                  # Pure group (no index.zig)
            └── release.zig            # Leaf: "zcli gh add workflow release"
```

**Resulting commands**:

- `zcli init` - Initialize a new project
- `zcli add` - Shows help with description "Add commands and plugins..."
- `zcli add command <name>` - Create a new command
- `zcli gh` - Shows help with description "Add GitHub-related features..."
- `zcli gh add workflow release` - Add GitHub release workflow

**Why this structure**:

- `add/` and `gh/` use metadata-only groups for clear help text without unnecessary execute functions
- Deep nesting (`gh/add/workflow/`) uses pure groups for clean organization
- Each level provides progressively more specific functionality

---

## Common Patterns

### Context Usage

```zig
pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    // Memory allocation
    const allocator = context.allocator;
    const name = try allocator.dupe(u8, "example");
    defer allocator.free(name);

    // Output
    const stdout = context.stdout();
    const stderr = context.stderr();
    try stdout.print("Info\n", .{});
    try stderr.print("Error\n", .{});

    // App metadata
    const app = context.app_name;
    const version = context.app_version;

    // Command path
    const path = context.command_path; // ["users", "create"]

    // Global data (from plugins)
    const verbose = context.getGlobalData([]const u8, "verbose") orelse "false";
    try context.setGlobalData("my_key", "my_value");
}
```

### Error Handling

```zig
pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    // Errors propagate to plugins' onError hooks
    const file = std.fs.cwd().openFile(args.path, .{}) catch |err| {
        const stderr = context.stderr();
        try stderr.print("Failed to open {s}: {}\n", .{ args.path, err });
        return err;
    };
    defer file.close();
}
```

### Plugin Error Handling

```zig
pub fn onError(context: *zcli.Context, err: anyerror) !bool {
    if (err == error.FileNotFound) {
        const stderr = context.stderr();
        try stderr.print("File not found - did you mean to create it?\n", .{});
        return true; // Error handled
    }
    return false; // Let it propagate
}
```

---

## Testing Guidelines

### Unit Tests

Place tests in the same file as the code being tested:

```zig
test "parseArgs basic types" {
    const allocator = std.testing.allocator;

    const Args = struct {
        name: []const u8,
        count: u32,
    };

    const args = [_][]const u8{ "john", "42" };
    const result = try parseArgs(Args, allocator, &args);
    defer result.deinit();

    try std.testing.expectEqualStrings("john", result.value.name);
    try std.testing.expectEqual(@as(u32, 42), result.value.count);
}
```

### Integration Tests

For cross-boundary tests, create dedicated test files:

- `src/build_integration_test.zig` - Build system tests
- `src/error_edge_cases_test.zig` - Error handling tests

---

## Key Design Decisions

### Why String-based Code Generation for Commands?

Commands are discovered by scanning directories. We can't know their types at comptime in `build.zig` because they don't exist until we read the filesystem. Therefore:

1. Scan filesystem → collect file paths
2. Generate import and registration code as **strings**
3. Write to `.zig` file → compiler sees it as real code

### Why Comptime Introspection for Plugins?

Plugins are explicitly listed in the `generate()` call. We know them at comptime. Therefore:

1. Accept `anytype` config
2. Use `inline for` to iterate at comptime
3. Introspect struct fields to generate init calls
4. No runtime string manipulation needed

### Why `anytype` for `generate()` Config?

Flexibility. Users can:

- Use anonymous structs: `.{ .commands_dir = "src/commands" }`
- Add custom fields (validated via `@hasField()`)
- Get compile errors for missing required fields
- Avoid rigid struct definitions that change often

### Why Three Types of Command Groups?

The distinction between **pure groups**, **metadata-only groups**, and **executable groups** provides progressive enhancement:

1. **Pure groups** (no `index.zig`): Zero-config organization. Just create a directory.
2. **Metadata-only groups** (`index.zig` with only `meta`): Add description without implementation complexity.
3. **Executable groups** (`index.zig` with `execute`): Full control when the parent command needs behavior.

**Implementation**:

- Commands without `execute` trigger `error.CommandNotFound` in the registry
- The help plugin's `onError` hook intercepts this and shows group help
- This allows metadata-only groups to behave identically to pure groups functionally, while providing richer help text
- Descriptions are matched by exact path length: `["add"]` matches commands at depth 1, not nested commands like `["add", "command"]`

**Design rationale**: Most command groups are organizational (like `git remote` or `npm config`). Making `execute` optional reduces boilerplate and encourages better help documentation.

---

## Development Commands

```bash
# Build the core library (from repo root)
zig build

# Build the zcli tool (from projects/zcli or repo root)
zig build

# Build tests
zig build test

# Run the zcli tool
./zig-out/bin/zcli --help
./zig-out/bin/zcli init myproject
./zig-out/bin/zcli add command users list

# Clean build (no dedicated clean step)
rm -rf .zig-cache zig-out
```

---

## Common Tasks

### Adding a New Core Plugin

1. Create `packages/core/plugins/my-plugin/`
2. Add `build.zig` and `build.zig.zon`
3. Create `src/plugin.zig` with required exports
4. Add to `packages/core/build.zig.zon` dependencies
5. Document in plugin's `README.md`

### Adding a Command to zcli Tool

```bash
# Let zcli do it for you!
cd projects/zcli
./zig-out/bin/zcli add command my-command
```

Or manually:

1. Create `projects/zcli/src/commands/mycommand.zig`
2. Implement `meta`, `Args`, `Options`, `execute`
3. Rebuild - it's automatically discovered

### Extending the Build System

**Caution**: The build system in `packages/core/src/build_utils/` is delicate. Key points:

- `main.zig`: Entry point, orchestrates everything
- `discovery.zig`: Filesystem scanning logic
- `code_generation.zig`: Template generation
- `module_creation.zig`: Zig build module wiring

**Testing approach**: Create a test project, run `generate()`, inspect generated code.

---

## Troubleshooting

### "Field not found" in generated registry

- Check `code_generation.zig` - ensure field names match
- Verify plugin exports the expected declarations
- Look at `.zig-cache/o/*/zcli_generated.zig` to see what was generated

### Plugin command not showing up

- Plugin must export `pub const commands = struct { ... }`
- Each command must be a struct with `execute()` function
- Rebuild completely: `rm -rf .zig-cache zig-out && zig build`

### Build-time config not working

- Config field must be recognized by `configToInitString()`
- Check type support: strings, bools, ints currently supported
- Add new types by extending the switch in `configToInitString()`

### Comptime errors with `@typeInfo`

- Use lowercase: `.@"struct"`, `.pointer`, `.int` (not `.Struct`, `.Pointer`, `.Int`)
- This changed in recent Zig versions

### Command group showing wrong description

- Ensure your command has the correct path structure in the filesystem
- Check that `index.zig` exists at the right level for optional groups
- Descriptions are matched by **exact path length**: a command at `["add", "command"]` won't provide the description for `["add"]`
- Pure groups (no `index.zig`) show no description - add `index.zig` with `meta` if you need one

### Nested command groups not being registered

- Verify that nested `index.zig` files are being discovered: check `.zig-cache/o/*/zcli_generated.zig`
- Ensure the build system properly handles `optional_group` command types in:
  - `code_generation.zig`: Must register and import nested optional groups
  - `module_creation.zig`: Must create modules with full path names
- Module names should include the full path: `add_gh_index` not `gh_index`

---

## Future Considerations

### Potential Enhancements

- **Positional argument validation**: Currently best-effort; could add stricter compile-time checks
- **Option aliasing**: Multiple names for same option
- **Environment variable support**: Auto-bind env vars to options
- **Shell completion generation**: Bash/Zsh/Fish completions from metadata
- **Config file support**: Load defaults from TOML/JSON

### Known Limitations

- **Command name conflicts**: Plugin commands override file-based commands
- **Plugin execution order**: Hooks run in plugin registration order
- **Config types**: Limited to strings, bools, ints currently
- **No dynamic commands**: All commands must exist at build time

---

## Additional Resources

- **Zig documentation**: https://ziglang.org/documentation/
- **Example project**: See `projects/zcli/` for a complete working example
- **Plugin examples**: `packages/core/plugins/` directory

---

## Questions or Improvements

When working on this codebase:

1. **Understand the phase**: Are you working with build-time discovery (commands) or comptime configuration (plugins)?
2. **Read generated code**: Always check `.zig-cache/o/*/zcli_generated.zig` when debugging
3. **Follow the types**: Zig's type system is your friend - let compile errors guide you
4. **Test incrementally**: Build system changes can break in subtle ways
5. **Keep it simple**: Comptime is powerful but can be hard to debug - prefer clarity over cleverness
