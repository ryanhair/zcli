# zcli

A framework for building command-line interfaces in Zig with automatic command discovery and zero runtime overhead.

## Features

- 🚀 **Zero Runtime Overhead** - All command discovery and routing happens at build time
- 🔍 **Fully Automatic Discovery** - Just drop `.zig` files in your commands directory
- 🛡️ **Type Safe** - Full compile-time type safety for arguments and options
- 📝 **Auto-generated Help** - Help text generated automatically from command definitions
- 🎯 **Smart Error Handling** - Helpful error messages with "did you mean?" suggestions
- 🗂️ **Command Groups** - Organize commands with nested directories
- ⚡ **Fast Builds** - No external tools or file generation needed

## Quick Start

NOTE: throughout all the steps, replace `myapp` with your app name

### 1. Create a new project (if you don't already have one)

```bash
mkdir myapp
cd myapp
zig init
```

### 2. Add zcli to your project

Add `zcli` as a dependency:

```bash
zig fetch --save "git+https://github.com/ryanhair/zcli"
```

### 3. Set up your `build.zig`

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get zcli dependency
    const zcli_dep = b.dependency("zcli", .{
        .target = target,
        .optimize = optimize,
    });
    const zcli_module = zcli_dep.module("zcli");

    // Create your executable
    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("zcli", zcli_module);

    // Generate command registry automatically from your commands directory
    const zcli_build = @import("zcli");
    const cmd_registry = zcli_build.generateCommandRegistry(b, target, optimize, zcli_module, .{
        .commands_dir = "src/commands",
        .app_name = "myapp",
        .app_version = "1.0.0",
        .app_description = "My awesome CLI app",
    });

    exe.root_module.addImport("command_registry", cmd_registry);
    b.installArtifact(exe);
}
```

### 4. Create your `src/main.zig`

```zig
const std = @import("std");
const zcli = @import("zcli");
const registry = @import("command_registry");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = zcli.App(@TypeOf(registry.registry)).init(
        allocator,
        registry.registry,
        .{
            .name = registry.app_name,
            .version = registry.app_version,
            .description = registry.app_description,
        },
    );

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    try app.run(args[1..]);
}
```

### 5. Create your commands

Just drop `.zig` files in `src/commands/` - they're discovered automatically!

```zig
// src/commands/hello.zig
const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Say hello to someone",
    .examples = &.{
        "hello World",
        "hello Alice --loud",
    },
};

pub const Args = struct {
    name: []const u8,
};

pub const Options = struct {
    loud: bool = false,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    const greeting = if (options.loud) "HELLO" else "Hello";
    try context.stdout.print("{s}, {s}!\n", .{ greeting, args.name });
}
```

### 6. Organize with command groups (optional)

Create directories for command groups:

```
src/commands/
├── hello.zig           # myapp hello <name>
├── users/
│   ├── index.zig       # myapp users (group help)
│   ├── list.zig        # myapp users list
│   └── create.zig      # myapp users create
└── files/
    ├── index.zig       # myapp files (group help)
    └── upload.zig      # myapp files upload
```

### 7. Build and run your CLI

```bash
$ zig build
$ cd zig-out/bin
$ ./myapp hello World
Hello, World!

$ ./myapp hello Alice --loud
HELLO, Alice!

$ ./myapp --help
myapp v1.0.0
My awesome CLI app

USAGE:
    myapp [GLOBAL OPTIONS] <COMMAND> [ARGS]

COMMANDS:
    hello        Say hello to someone
    users        (command group)
    files        (command group)

$ ./myapp users list
[User data here...]
```

## Key Features Explained

### 🔍 **Fully Automatic Discovery**

- No build configuration needed - just create `.zig` files
- Commands are discovered by scanning `src/commands/` at build time
- File structure directly maps to CLI structure

### 🗂️ **Command Groups**

- Create directories to organize related commands
- Each group directory needs an `index.zig` for group-level help
- Unlimited nesting supported

### 🛡️ **Type-Safe Arguments & Options**

- Define `Args` struct for positional arguments
- Define `Options` struct for flags and options
- Automatic parsing and validation based on types
- Support for arrays, enums, optionals, and more

### 📝 **Auto-Generated Help**

- Help text generated from `meta`, `Args`, and `Options`
- Command-specific help with examples
- Smart error messages with suggestions

### ⚡ **Zero Runtime Overhead**

- All command discovery happens at build time
- Static dispatch - no reflection or dynamic lookup
- Optimal binary size and performance

## Advanced Features

### Custom Option Names

```zig
pub const Options = struct {
    output_file: []const u8,
};

pub const meta = .{
    .description = "Process files",
    .options = .{
        .output_file = .{ .name = "output" }, // Use --output instead of --output-file
    },
};
```

### Array Options

```zig
pub const Options = struct {
    files: [][]const u8 = &.{}, // Accumulates multiple --files values
    verbose: bool = false,
};

// Usage: myapp process --files file1.txt --files file2.txt --verbose
```

### Memory Management

When using zcli through the framework, array cleanup is automatic. For manual usage:

```zig
// Manual parsing requires cleanup
const parsed = try zcli.parseOptions(Options, allocator, args);
defer zcli.cleanupOptions(Options, parsed.options, allocator);

// Or cleanup individual fields
const parsed = try zcli.parseOptions(Options, allocator, args);
defer allocator.free(parsed.options.files);
```

### Complex Arguments

```zig
pub const Args = struct {
    source: []const u8,           // Required positional
    destination: ?[]const u8,     // Optional positional
    extra_files: [][]const u8,    // Remaining arguments
};
```

## Documentation

- [DESIGN.md](DESIGN.md) - Complete framework design specification
- [API.md](API.md) - Public API reference with stability guarantees  
- [MEMORY.md](MEMORY.md) - **Comprehensive memory management guide**
- [Examples](examples/) - Working example projects

## License

MIT
