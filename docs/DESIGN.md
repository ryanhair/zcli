# zcli Framework Design

## Core Concept

A Zig CLI framework that uses comptime introspection to automatically discover and wire commands based on folder structure, eliminating runtime overhead and providing type-safe command handling. The framework supports a plugin architecture for extensibility while maintaining zero runtime cost through compile-time code generation.

## 1. Folder Structure & Command Mapping

```
myapp/
├── build.zig
├── src/
│   ├── main.zig         # Entry point, minimal runtime code
│   └── commands/
│       ├── root.zig      # Optional root command (when no subcommand given)
│       ├── version.zig   # `myapp version` command (leaf command)
│       └── users/
│           ├── index.zig  # `myapp users` command (optional for command groups)
│           ├── list.zig   # `myapp users list`
│           ├── search.zig # `myapp users search <query>`
│           └── create.zig # `myapp users create --name <name>`
```

**Naming Convention Rules:**

- Leaf commands (no subcommands): Use a `.zig` file directly
- Command groups (has subcommands): Use a folder with optional `index.zig`
- File names map directly to command names (kebab-case supported)
- Special file: `root.zig` for base command (optional, executed when no subcommand given)
- Hidden directories (starting with `.`) are automatically skipped
- Maximum nesting depth: 6 levels (configurable)

## 2. Build-Time Command Discovery

Since Zig's comptime cannot access the filesystem, zcli provides a build function that scans the commands directory during the build process:

```zig
// In user's build.zig
const std = @import("std");
const zcli = @import("zcli");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Get zcli dependency
    const zcli_dep = b.dependency("zcli", .{
        .target = target,
        .optimize = optimize,
    });
    const zcli_module = zcli_dep.module("zcli");
    
    exe.root_module.addImport("zcli", zcli_module);

    // Build with plugins and command discovery
    const cmd_registry = zcli.build(b, exe, zcli_module, .{
        .commands_dir = "src/commands",  // Optional, defaults to "src/commands"
        .app_name = "myapp",
        .app_description = "My CLI application",
        // Note: Version is automatically read from build.zig.zon
        .plugins = &.{
            .{ .name = "zcli-help", .path = "path/to/help/plugin" },
            .{ .name = "zcli-version", .path = "path/to/version/plugin" },
            .{ .name = "zcli-not-found", .path = "path/to/suggestions/plugin" },
        },
        .global_options = .{
            .verbose = .{ .short = 'v', .type = bool, .default = false, .help = "Enable verbose output" },
            .config = .{ .short = 'c', .type = ?[]const u8, .help = "Config file path" },
        },
    });

    exe.root_module.addImport("command_registry", cmd_registry);
    b.installArtifact(exe);
}
```

This generates a comptime registry using the Registry builder pattern:

```zig
// Generated command_registry.zig
const std = @import("std");
const zcli = @import("zcli");

// Command imports
const cmd_init = @import("cmd_init");
const cmd_version = @import("cmd_version");
const users_list = @import("users_list");
// ... more command imports

// Plugin imports  
const zcli_help = @import("zcli_help");
const zcli_not_found = @import("zcli_not_found");

pub const registry = zcli.Registry.init(.{
    .app_name = "myapp",
    .app_version = "1.0.0",  // This comes from build system
    .app_description = "My CLI application",
})
    .register("init", cmd_init)
    .register("version", cmd_version)
    .register("users list", users_list)
    // ... more command registrations
    .registerPlugin(zcli_help)
    .registerPlugin(zcli_not_found)
    .build();
```

The framework uses comptime introspection on this registry to:

- Build a static command routing table with hierarchical command paths
- Generate all necessary dispatch code without runtime reflection
- Create type-safe argument and option parsing based on command signatures
- Validate plugin conflicts and command uniqueness at compile time

## 3. Command Interface Contract

Each command file exports a standardized structure:

```zig
pub const meta = .{
    .description = "Search for users by name",
    .usage = "search <query> [files...] [--limit <n>]",
    .examples = &.{
        "search John",
        "search Jane --limit 10",
        "search Bob file1.txt file2.txt"
    },
    // Optional: document arguments and options
    .args = .{
        .query = "Search query string",
        .files = "Files to search in",
    },
    .options = .{
        .limit = .{ .desc = "Maximum number of results" },
        .format = .{ .desc = "Output format" },
    }
};

// Positional arguments (required and optional)
pub const Args = struct {
    query: []const u8,              // Required positional
    files: [][]const u8 = &.{},     // Optional varargs (remaining positionals)
};

// Named options (flags)
pub const Options = struct {
    limit: ?u32 = 10,
    format: enum { json, table } = .table,
    verbose: bool = false,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    // Command implementation
    // Access: args.query, args.files, options.limit, etc.
    // Context provides: allocator, io (stdout/stderr/stdin), environment, and more
}
```

**Positional Arguments Rules:**

- Required args must come before optional args
- Last field can be `[][]const u8` to capture remaining args
- Types supported: `[]const u8`, `u32`, `i32`, `bool`, enums
- Default values make an arg optional

**Context Structure:**

The context provides access to system resources and framework features:

```zig
pub const Context = struct {
    allocator: std.mem.Allocator,
    io: IO,                           // stdout, stderr, stdin
    environment: Environment,         // env vars, working directory
    app_name: []const u8,
    app_version: []const u8, 
    app_description: []const u8,
    command_path: ?[]const []const u8,  // Hierarchical command path
    available_commands: []const []const []const u8,
    
    // Global options access (planned)
    globals: GlobalOptions,
    
    // Type-safe extension system (planned)
    extensions: Extensions,
    
    // Convenience methods
    pub fn stdout(self: *@This()) std.fs.File.Writer { ... }
    pub fn stderr(self: *@This()) std.fs.File.Writer { ... }
    pub fn stdin(self: *@This()) std.fs.File.Reader { ... }
};
```

## 4. Global Options

Global options are defined when calling `zcli.build()` in your build.zig. These options are available to all commands and can be accessed through the context:

```zig
// In build.zig
const cmd_registry = zcli.build(b, exe, zcli_module, .{
    .global_options = .{
        .verbose = .{ .short = 'v', .type = bool, .default = false, .help = "Enable verbose output" },
        .config = .{ .short = 'c', .type = ?[]const u8, .help = "Config file path" },
        .api_key = .{ .env = "MYAPP_API_KEY", .type = []const u8, .help = "API key for service" },
        .no_color = .{ .type = bool, .default = false, .help = "Disable colored output" },
    },
    // ... other config
});
```

**Framework-Provided Options:**

Plugins can provide global options. For example, the zcli-help plugin provides:
- `--help/-h`: Shows command help
- `--version/-V`: Shows app version (if version plugin is included)

**Naming Convention:**

- CLI flags: underscores become dashes (`no_color` → `--no-color`)
- Zig access: accessed through typed globals struct (`context.globals.no_color`)

**Environment Variable Fallbacks:**

Global options and command-specific options can specify an environment variable as a fallback value using the `.env` field:

```zig
.global_options = .{
    .api_key = .{ 
        .env = "MYAPP_API_KEY", 
        .type = []const u8, 
        .help = "API key for service" 
    },
    .timeout = .{ 
        .env = "MYAPP_TIMEOUT", 
        .type = u32, 
        .default = 30, 
        .help = "Request timeout in seconds" 
    },
    .debug = .{ 
        .env = "MYAPP_DEBUG", 
        .short = 'd', 
        .type = bool, 
        .default = false, 
        .help = "Enable debug mode" 
    },
},
```

**Precedence Order (highest to lowest):**
1. **CLI argument**: `--api-key mykey` (highest priority)
2. **Environment variable**: `MYAPP_API_KEY=envkey` (fallback if CLI arg not provided)
3. **Default value**: `.default = "defaultkey"` (fallback if both above are missing)

**Type Conversion:**
- `bool`: Environment variables parsed as "true"/"false", "1"/"0", "yes"/"no" (case insensitive)
- `string`: Used directly from environment
- `integer/float`: Parsed from environment string
- `optional`: `null` if environment variable is not set or empty

**Command-Specific Options:**

Environment variable fallbacks also work for command-specific options:

```zig
// In commands/deploy.zig
pub const Options = struct {
    region: []const u8 = .{ .env = "AWS_REGION", .default = "us-east-1" },
    instance_type: []const u8 = .{ .env = "AWS_INSTANCE_TYPE", .default = "t3.micro" },
    dry_run: bool = .{ .env = "DRY_RUN", .default = false },
};
```

This allows users to configure commonly-used values through environment variables while still allowing CLI overrides.

**Context Access:**

Global options are accessible to all commands through the strongly-typed `context.globals` struct:

```zig
// In any command file (e.g., commands/deploy.zig)
pub fn execute(args: Args, options: Options, context: *Context) !void {
    // Access global options with full type safety
    if (context.globals.verbose) {
        try context.stdout().print("Verbose mode enabled\n", .{});
    }
    
    // Optional globals use Zig's optional syntax
    if (context.globals.config) |config_path| {
        try loadConfig(config_path);
    }
    
    // String globals are directly available
    const api_key = context.globals.api_key;
    try makeApiCall(api_key);
    
    // Environment variable fallbacks work transparently
    const timeout = context.globals.timeout; // From CLI, env var, or default
}
```

**Generated Globals Struct:**

Based on the `global_options` definition in build.zig, zcli generates a strongly-typed `Globals` struct at build time:

```zig
// Generated from your global_options config
pub const Globals = struct {
    verbose: bool,           // .default = false
    config: ?[]const u8,     // Optional type, no default
    api_key: []const u8,     // From .env fallback or CLI
    timeout: u32,            // .default = 30, .env = "MYAPP_TIMEOUT" 
    debug: bool,             // .default = false, .env = "MYAPP_DEBUG"
    no_color: bool,          // .default = false
};
```

**Global vs Command-Specific Options:**

- **Global options**: Available to all commands via `context.globals`
- **Command-specific options**: Defined per-command in the `Options` struct
- **Plugin-provided globals**: Handled by plugins (like `--help`) and typically don't need explicit access

```zig
// Command-specific options stay in the Options struct
pub const Options = struct {
    force: bool = false,        // Only for this command
    output: enum { json, yaml } = .json,
};

pub fn execute(args: Args, options: Options, context: *Context) !void {
    // Mix command-specific and global options naturally
    if (context.globals.verbose or options.force) {
        try context.stdout().print("Executing with force\n", .{});
    }
}
```

## 5. Comptime Processing Flow

1. **Discovery Phase**: Build step scans `commands/` directory and generates registry
2. **Validation Phase**: Ensure all command files conform to the interface
3. **Code Generation Phase**: Generate:

   - Command routing table
   - Argument parsing code for each command
   - Help text generation
   - Autocompletion data structures
   - Global options parsing

4. **Runtime Phase**: Minimal code that:
   - Parses argv
   - Handles --help and --version automatically
   - Parses global options
   - Looks up command in static table
   - Calls appropriate handler with parsed args and globals

## 6. Option Parsing Behavior

**Option Formats:**

- Long options: `--option value` or `--option=value`
- Short options: `-o value` or `-ovalue` (no space)
- Boolean flags: `--verbose` (presence = true)

**Short Option Bundling:**

- Allow: `-abc` equals `-a -b -c` (for boolean flags only)
- Error if bundled with value-taking option: `-abf file` is ambiguous

**Special Handling:**

- `--` stops option parsing (everything after is positional)
- Unknown options: compile-time error if possible, runtime error otherwise
- Case sensitive (no automatic case conversion)

**Value Types and Parsing:**

```zig
// String: --name "John Doe"
name: []const u8

// Optional string: --config file.toml
config: ?[]const u8

// Number: --port 8080
port: u16

// Boolean: --verbose (presence = true)
verbose: bool = false

// Enum: --format json
format: enum { json, yaml, toml }

// Array: --file a.txt --file b.txt
files: [][]const u8
```

**Option Conflicts:**

- Build-time validation prevents duplicate short flags
- Global vs command options with same name: command wins

## 7. Key Design Decisions

**Type-Safe Arguments:**

- Use Zig's type system to define command options
- Generate parsing code at comptime based on struct fields
- Support common types: strings, numbers, enums, optionals, arrays

**Error Handling:**

- Compile-time errors for malformed commands
- Runtime errors only for user input issues
- Clear error messages with suggestions

**Context System:**

- Pass a context struct to all commands
- Contains: stdout, stderr, stdin, globals, environment
- Enables testing and different output modes

**Progressive Enhancement:**

- Start with basic command mapping
- Add features like middleware, plugins, hooks
- Support async commands naturally with Zig's async

## 8. Help Generation

Help is automatically generated from command metadata and type information:

**App-Level Help (`myapp --help`):**

```
MyApp v1.0.0
A description of what the app does

USAGE:
    myapp [GLOBAL OPTIONS] <COMMAND> [ARGS]

COMMANDS:
    users     Manage users
    config    Configure the application
    version   Show version information

GLOBAL OPTIONS:
    -h, --help       Show help information
    -V, --version    Show version information
    -v, --verbose    Enable verbose output
    --config FILE    Path to config file

Run 'myapp <command> --help' for more information on a command.
```

**Command Group Help (`myapp users --help`):**

```
Manage users

USAGE:
    myapp users <SUBCOMMAND>

SUBCOMMANDS:
    list      List all users
    search    Search for users
    create    Create a new user
```

**Command Help (`myapp users search --help`):**

```
Search for users by name

USAGE:
    myapp users search <query> [files...] [OPTIONS]

ARGS:
    <query>       Search query
    [files...]    Optional files to search in

OPTIONS:
    --limit N     Maximum results to return (default: 10)
    --format FMT  Output format: json, table (default: table)

EXAMPLES:
    myapp users search John
    myapp users search Jane --limit 10
    myapp users search Bob file1.txt file2.txt
```

**Error Context Help:**
When a user makes an error, show relevant help subset:

```
Error: Unknown subcommand 'searh' for 'users'

Did you mean 'search'?

Available subcommands for 'users':
    list      List all users
    search    Search for users
    create    Create a new user
```

**Generation Rules:**

- Help text is 100% auto-generated from types and metadata
- Examples in `meta.examples` are optional but recommended
- Descriptions come from `meta.description`
- Argument/option help from struct field comments or metadata
- Type information determines argument format (required vs optional)

## 9. Error Context and Recovery

Smart error handling helps users recover from mistakes:

**Command Not Found:**

```
Error: Unknown command 'ustats'

Did you mean one of these?
    stats    Show statistics
    status   Show current status
    users    Manage users

Run 'myapp --help' to see all available commands.
```

**Subcommand Errors:**

```
Error: 'myapp users delete' expects at least 1 argument

USAGE:
    myapp users delete <user-id> [OPTIONS]

Run 'myapp users delete --help' for more information.
```

**Invalid Option Values:**

```
Error: Invalid value 'abc' for option '--port'
Expected: u16 (number between 0 and 65535)
```

**Unknown Options:**

```
Error: Unknown option '--formt'

Did you mean '--format'?

Run 'myapp users list --help' to see available options.
```

**Error Design:**

- Similarity matching using edit distance for suggestions
- Only suggest if distance < 3 edits, max 3 suggestions
- Always show what was expected
- Provide path to relevant help

**Exit Codes:**

- 0: Success
- 1: General error
- 2: Misuse (wrong arguments/options)
- 3: Command not found

## 10. Build System Integration

**Package Setup:**

```zig
// build.zig.zon
.{
    .name = "myapp",
    .version = "1.0.0",
    .dependencies = .{
        .zcli = .{
            .url = "https://github.com/user/zcli/archive/v0.1.0.tar.gz",
            .hash = "...",
        },
    },
}
```

**Complete build.zig:**

```zig
const std = @import("std");
const zcli = @import("zcli");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // zcli build integration
    const cmd_registry = zcli.generateCommandRegistry(b, .{
        .commands_dir = "src/commands",
        .app_name = "myapp",
        .app_description = "My awesome CLI app",
        // Version automatically read from build.zig.zon
    });

    exe.step.dependOn(&cmd_registry.step);
    exe.root_module.addImport("command_registry", cmd_registry.module);

    const zcli_dep = b.dependency("zcli", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zcli", zcli_dep.module("zcli"));

    b.installArtifact(exe);
}
```

**Minimal main.zig:**

```zig
const std = @import("std");
const registry = @import("command_registry");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = registry.registry.init();

    app.run(allocator) catch |err| switch (err) {
        error.CommandNotFound => {
            // Error was already handled by plugins or registry
            std.process.exit(1);
        },
        else => return err,
    };
}
```

**Alternative API for custom args:**

```zig
// If you need to provide custom arguments instead of using process.argsAlloc():
const args = try std.process.argsAlloc(allocator);
defer std.process.argsFree(allocator, args);

app.run_with_args(allocator, args[1..]) catch |err| switch (err) {
    error.CommandNotFound => std.process.exit(1),
    else => return err,
};
```

## 11. Plugin System

Plugins extend zcli functionality through lifecycle hooks and can provide commands, global options, and custom behavior:

**Plugin Interface:**

```zig
// Example plugin structure
pub const global_options = [_]zcli.GlobalOption{
    zcli.option("verbose", bool, .{ .short = 'v', .default = false, .description = "Verbose output" }),
};

// Lifecycle hooks (all optional)
pub fn handleGlobalOption(context: *zcli.Context, name: []const u8, value: anytype) !void { }
pub fn preExecute(context: *zcli.Context, args: zcli.ParsedArgs) !?zcli.ParsedArgs { }
pub fn postExecute(context: *zcli.Context, result: anytype) !void { }
pub fn onError(context: *zcli.Context, err: anyerror) !bool { }

// Plugin can provide commands
pub const commands = struct {
    pub const help = struct {
        pub const Args = struct { command: ?[]const u8 = null };
        pub const Options = struct {};
        pub const meta = .{ .description = "Show help for commands" };
        pub fn execute(args: Args, options: Options, context: *zcli.Context) !void { }
    };
};
```

**Plugin Registration:**

Plugins are registered in build.zig and processed in order:

```zig
const cmd_registry = zcli.build(b, exe, zcli_module, .{
    .plugins = &.{
        .{ .name = "zcli-help", .path = "path/to/plugin" },      // First priority
        .{ .name = "zcli-not-found", .path = "path/to/plugin" }, // Second priority
    },
    // ... other config
});
```

**Plugin Execution Order:**

1. Plugins execute in registration order (no priority system)
2. All `handleGlobalOption` hooks called for each global option
3. All `preExecute` hooks called before command execution
4. Command executes
5. All `postExecute` hooks called after successful execution
6. On error, `onError` hooks called until one handles the error

**Built-in Plugins:**

- **zcli-help**: Provides `--help` flag and help command
- **zcli-not-found**: Provides command suggestions using edit distance

## 12. Advanced Features

**Subcommand Inheritance:**

- Commands can inherit options from parent commands
- Shared validation and preprocessing

**Command Aliases:**

- Define aliases in command metadata
- Multiple paths to same handler

**Interactive Mode:**

- Optional REPL for command exploration
- Tab completion using comptime-generated data

**Type-Safe Context Extensions (Planned):**

Replace the current StringHashMap with a strongly-typed extension system:

```zig
// Define extension types at compile time
const Extensions = struct {
    database: ?*Database = null,
    logger: Logger,
    config: Config,
};

// Access in commands with full type safety
pub fn execute(args: Args, options: Options, context: *Context) !void {
    if (context.extensions.database) |db| {
        // Use database
    }
}
```

## 13. Developer Experience

**Zero Runtime Overhead:**

- All discovery and wiring happens at compile time
- Final binary has direct function calls
- No reflection or dynamic dispatch

**Type Safety:**

- Command arguments are fully type-checked
- Impossible to call commands with wrong types
- IDE support through Zig's type system

**Testing:**

- Commands are just functions, easy to unit test
- Mock context for isolated testing
- Integration test helpers

This design leverages Zig's unique comptime capabilities to create a framework that's both developer-friendly (automatic discovery, type safety) and extremely efficient (zero runtime overhead, static dispatch).
