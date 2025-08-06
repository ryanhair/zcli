# zcli Framework Design

## Core Concept
A Zig CLI framework that uses comptime introspection to automatically discover and wire commands based on folder structure, eliminating runtime overhead and providing type-safe command handling.

## 1. Folder Structure & Command Mapping

```
myapp/
├── build.zig
├── src/
│   ├── main.zig         # Entry point, minimal runtime code
│   └── commands/
│       ├── root.zig      # Root command (when no subcommand given)
│       ├── version.zig   # `myapp version` command (leaf command)
│       └── users/
│           ├── index.zig  # `myapp users` command (required for command groups)
│           ├── list.zig   # `myapp users list`
│           ├── search.zig # `myapp users search <query>`
│           └── create.zig # `myapp users create --name <name>`
```

**Naming Convention Rules:**
- Leaf commands (no subcommands): Use a `.zig` file directly
- Command groups (has subcommands): Must use a folder with `index.zig`
- File names map directly to command names (kebab-case supported)
- Special file: `root.zig` for base command (when no subcommand given)

## 2. Build-Time Command Discovery

Since Zig's comptime cannot access the filesystem, zcli provides a build function that scans the commands directory during the build process:

```zig
// In user's build.zig
const std = @import("std");
const zcli = @import("zcli");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_source_file = .{ .path = "src/main.zig" },
    });

    // zcli generates the command registry
    const cmd_registry = zcli.generateCommandRegistry(b, .{
        .commands_dir = "src/commands",
        .output_path = "zig-cache/zcli/command_registry.zig",
    });
    
    exe.step.dependOn(&cmd_registry.step);
    exe.root_module.addImport("command_registry", cmd_registry.module);
    exe.root_module.addImport("zcli", b.dependency("zcli", .{}).module("zcli"));
}
```

This generates a registry file with all command imports:
```zig
// Generated command_registry.zig
pub const registry = .{
    .commands = .{
        .root = @import("../../src/commands/root.zig"),
        .version = @import("../../src/commands/version.zig"),
        .users = .{
            ._is_group = true,
            ._index = @import("../../src/commands/users/index.zig"),
            .list = @import("../../src/commands/users/list.zig"),
            .search = @import("../../src/commands/users/search.zig"),
        },
    },
};
```

The framework then uses comptime introspection on this generated registry to:
- Build a static command tree/routing table
- Generate all necessary dispatch code without runtime reflection
- Create type-safe argument parsing based on command signatures

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

pub fn execute(args: Args, options: Options, context: *Context) !void {
    // Command implementation
    // Access: args.query, args.files, options.limit, etc.
}
```

**Positional Arguments Rules:**
- Required args must come before optional args
- Last field can be `[][]const u8` to capture remaining args
- Types supported: `[]const u8`, `u32`, `i32`, `bool`, enums
- Default values make an arg optional

## 4. Global Options

Users can optionally define global options that are available to all commands:

```zig
// In main.zig or globals.zig
pub const global_options = .{
    .verbose = .{ .short = 'v', .help = "Enable verbose output" },
    .config = .{ .short = 'c', .type = ?[]const u8, .help = "Config file path" },
    .api_key = .{ .env = "MYAPP_API_KEY", .help = "API key for service" },
    .no_color = .{ .help = "Disable colored output" },
    // .help = ... // COMPILE ERROR: "help is reserved and handled by zcli"
    // .version = ... // COMPILE ERROR: "version is reserved and handled by zcli"
};
```

**Framework-Provided Options:**
- `--help/-h`: Always available, shows command help
- `--version/-V`: Always available, shows app version
- User cannot override these reserved options

**Naming Convention:**
- CLI flags: underscores become dashes (`no_color` → `--no-color`)
- Zig access: dashes become underscores (`--no-color` → `context.globals.no_color`)

**Context Access:**
```zig
// Commands access globals through context
pub fn execute(args: Args, options: Options, context: *Context) !void {
    if (context.globals.verbose) {
        try context.stdout.print("Verbose mode enabled\n", .{});
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
        .app_version = "1.0.0",
        .app_description = "My awesome CLI app",
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
const zcli = @import("zcli");
const registry = @import("command_registry");

// Optional: define global options
pub const global_options = .{
    .verbose = .{ .short = 'v', .help = "Enable verbose output" },
};

pub fn main() !void {
    var app = zcli.App.init(registry, .{
        .name = registry.app_name,
        .version = registry.app_version,
        .description = registry.app_description,
    });
    
    try app.run(std.os.argv[1..]);
}
```

## 11. Advanced Features

**Subcommand Inheritance:**
- Commands can inherit options from parent commands
- Shared validation and preprocessing

**Command Aliases:**
- Define aliases in command metadata
- Multiple paths to same handler

**Interactive Mode:**
- Optional REPL for command exploration
- Tab completion using comptime-generated data

**Plugin System:**
- Commands can be provided by external packages
- Discovered and integrated at compile time

## 7. Developer Experience

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