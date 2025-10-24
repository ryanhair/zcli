# zcli

**Build beautiful CLIs in Zig with zero boilerplate.**

zcli is a batteries-included framework for building command-line interfaces. Drop `.zig` files in a directory, and zcli generates a fully-featured CLI with help text, error handling, and type-safe argument parsing—all at compile time.

```bash
# Your file structure IS your CLI structure
src/commands/
├── hello.zig        # → myapp hello <name>
├── users/
│   ├── list.zig     # → myapp users list
│   └── create.zig   # → myapp users create <email>
└── config/
    └── set.zig      # → myapp config set <key> <value>
```

## Why zcli?

- **Zero boilerplate** - No routing, no parsing, no help text to write
- **Type-safe** - Arguments and options validated at compile time
- **Zero runtime overhead** - All discovery happens at build time
- **Beautiful output** - Colored help text with semantic highlighting
- **Batteries included** - Help, error messages, and "did you mean?" suggestions built-in

## Installation

### Quick Install (Recommended)

Install zcli with a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/ryanhair/zcli/main/install.sh | sh
```

This will:

- Download the appropriate binary for your platform
- Install it to `~/.local/bin`
- Update your shell configuration (bash, zsh, fish, or ksh) to include `~/.local/bin` in your PATH

After installation, you may need to restart your terminal or run `source ~/.zshrc` (or your shell's config file).

### Manual Download

Download pre-built binaries from the [releases page](https://github.com/ryanhair/zcli/releases):

1. Download the binary for your platform (e.g., `zcli-aarch64-macos` for Apple Silicon Mac)
2. Rename it to `zcli` and make it executable:
   ```bash
   chmod +x zcli
   mv zcli ~/.local/bin/zcli
   ```
3. Ensure `~/.local/bin` is in your PATH

### Build from Source

```bash
git clone https://github.com/ryanhair/zcli.git
cd zcli/projects/zcli
zig build -Doptimize=ReleaseFast
cp zig-out/bin/zcli ~/.local/bin/
```

Requires Zig 0.15.1 or later.

### Using the zcli Tool

Once installed, use the `zcli` command to scaffold new projects:

```bash
# Create a new CLI project
zcli init my-cli

# Add commands to your project
cd my-cli
zcli add command deploy
zcli add command users/create
```

## Quick Start

Build a complete CLI in 30 seconds with the `zcli` tool.

### 1. Create a new project

```bash
zcli init myapp
cd myapp
```

This scaffolds a complete project with:

- `build.zig` configured with zcli
- `src/main.zig` with the app entry point
- `src/commands/hello.zig` as an example command
- Help and error handling plugins pre-configured

### 2. Build and run

```bash
$ zig build
$ ./zig-out/bin/myapp hello World
Hello, World!

$ ./zig-out/bin/myapp hello Alice --loud
HELLO, Alice!

$ ./zig-out/bin/myapp --help
myapp v0.1.0
A CLI application built with zcli

USAGE:
    myapp [GLOBAL OPTIONS] <COMMAND> [ARGS]

COMMANDS:
    hello            Say hello to someone

GLOBAL OPTIONS:
    -h, --help       Show help information
    -V, --version    Show version information
```

**That's it!** You have a working CLI with colored output, help text, and error handling.

### 3. Add more commands

```bash
$ zcli add command deploy --description "Deploy your app"
Creating command: deploy
✓ Created src/commands/deploy.zig

$ zcli add command users/create --description "Create a new user"
Creating command: users/create
✓ Created src/commands/users/create.zig
```

### 4. Customize your commands

Edit the generated command files to add your logic. Here's what the example `hello.zig` looks like:

```zig
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
    try context.stdout().print("{s}, {s}!\n", .{ greeting, args.name });
}
```

That's all you need! zcli handles parsing, validation, and help text generation automatically.

## How It Works

zcli uses **convention over configuration**:

1. **File structure = CLI structure** - The directory layout in `src/commands/` directly maps to your CLI commands
2. **Types = validation** - Your `Args` and `Options` structs define what inputs are valid
3. **Compile-time discovery** - zcli scans your commands directory at build time and generates the routing code
4. **Zero runtime overhead** - All command discovery and validation happens at compile time

### The Magic Explained

When you run `zig build`, zcli:

1. Scans `src/commands/` for `.zig` files
2. Reads the `Args`, `Options`, and `meta` from each command
3. Generates a static registry that routes commands to the right `execute()` function
4. Generates type-safe parsing code for each command's arguments and options

There's no runtime reflection, no dynamic dispatch—just static function calls.

## Building Real CLIs

### Command Groups

Organize related commands into groups using directories:

```
src/commands/
├── hello.zig          # myapp hello <name>
├── users/
│   ├── list.zig       # myapp users list
│   ├── create.zig     # myapp users create <email>
│   └── delete.zig     # myapp users delete <id>
└── config/
    ├── get.zig        # myapp config get <key>
    └── set.zig        # myapp config set <key> <value>
```

**Example: `src/commands/users/create.zig`**

```zig
const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Create a new user",
    .examples = &.{ "users create alice@example.com --admin" },
};

pub const Args = struct {
    email: []const u8,
};

pub const Options = struct {
    admin: bool = false,
    name: ?[]const u8 = null,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    const role = if (options.admin) "admin" else "user";
    const display_name = options.name orelse args.email;

    try context.stdout().print("Creating {s} '{s}' ({s})\n",
        .{ role, display_name, args.email });
}
```

```bash
$ myapp users create alice@example.com --admin --name Alice
Creating admin 'Alice' (alice@example.com)
```

### Rich Metadata for Better Help

Add descriptions, examples, and field-level documentation:

```zig
pub const meta = .{
    .description = "Deploy your application",
    .examples = &.{
        "deploy production",
        "deploy staging --rollback",
        "deploy production --replicas 5",
    },
    .args = .{
        .environment = "Target environment (production, staging, development)",
    },
    .options = .{
        .replicas = .{ .description = "Number of instances to deploy" },
        .rollback = .{ .description = "Rollback to previous version instead of deploying" },
    },
};

pub const Args = struct {
    environment: []const u8,
};

pub const Options = struct {
    replicas: ?u32 = null,
    rollback: bool = false,
};
```

**Compile-Time Validation**: zcli validates all metadata fields at compile time to catch typos and invalid configurations. If you misspell a field name or use an invalid option, you'll get a clear error message during compilation:

```bash
error: Unknown meta field: 'desc'. Valid fields are: description, examples, args, options, hidden
```

This ensures your CLI's help text and documentation are always correct.

### Complex Arguments

Handle multiple argument types, including optional arguments and arrays:

```zig
pub const Args = struct {
    source: []const u8,              // Required
    destination: ?[]const u8,        // Optional
    files: [][]const u8,             // Remaining args as array
};

// Usage: myapp copy source.txt dest.txt file1.txt file2.txt
```

### Array Options

Accumulate multiple values for an option:

```zig
pub const Options = struct {
    include: [][]const u8 = &.{},    // Can specify --include multiple times
    exclude: [][]const u8 = &.{},
    verbose: bool = false,
};

// Usage: myapp process --include *.zig --include *.md --exclude test.zig
```

### Short Flags

Add single-character shortcuts for options:

```zig
pub const Options = struct {
    verbose: bool = false,
    output: ?[]const u8 = null,
};

pub const meta = .{
    .description = "Process files",
    .options = .{
        .verbose = .{ .short = 'v' },
        .output = .{ .short = 'o' },
    },
};

// Usage: myapp process -v -o output.txt
// Usage: myapp process -vo output.txt    (combined)
```

### Error Handling

zcli provides rich, contextual error messages automatically:

```bash
$ myapp deploy prod --replicas abc
Error: Invalid value 'abc' for option '--replicas'
Expected: unsigned integer

$ myapp deploi production
Error: Command 'deploi' not found

Did you mean?
    deploy
```

### Custom Option Names

Override the automatic naming:

```zig
pub const Options = struct {
    output_file: []const u8,
    max_connections: u32 = 10,
};

pub const meta = .{
    .options = .{
        .output_file = .{ .name = "output" },      // --output instead of --output-file
        .max_connections = .{ .name = "max-conn" }, // --max-conn instead of --max-connections
    },
};
```

## Working with Context

The `context` parameter gives you access to I/O streams, environment variables, and more:

```zig
pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    // Output streams
    try context.stdout().print("Success!\n", .{});
    try context.stderr().print("Warning: ...\n", .{});

    // Environment variables
    const home = context.environment.get("HOME");

    // App metadata
    const app_name = context.app_name;
    const app_version = context.app_version;

    // Command path (for nested commands)
    // For "myapp users create", command_path = ["users", "create"]
    const path = context.command_path;
}
```

## Sharing Code Between Commands

Commands are compiled as isolated modules and can only import `std` and `zcli` by default. To share business logic, utilities, or data structures across commands, use **shared modules**:

### Step 1: Create Your Shared Module

```zig
// src/lib.zig
const std = @import("std");

pub fn validateEmail(email: []const u8) bool {
    return std.mem.indexOf(u8, email, "@") != null;
}

pub const UserRole = enum {
    admin,
    user,
    guest,
};
```

### Step 2: Configure in build.zig

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zcli_dep = b.dependency("zcli", .{
        .target = target,
        .optimize = optimize,
    });
    const zcli_module = zcli_dep.module("zcli");

    // Create your shared module
    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
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
    exe.root_module.addImport("lib", lib_module);  // For main.zig

    const zcli = @import("zcli");
    const cmd_registry = zcli.generate(b, exe, zcli_dep, zcli_module, .{
        .commands_dir = "src/commands",
        .plugins = &[_]zcli.PluginConfig{ /* ... */ },
        .shared_modules = &[_]zcli.SharedModule{
            .{ .name = "lib", .module = lib_module },
        },
        .app_name = "myapp",
        .app_version = "1.0.0",
        .app_description = "My CLI application",
    });

    exe.root_module.addImport("command_registry", cmd_registry);
    b.installArtifact(exe);
}
```

### Step 3: Use in Commands

```zig
// src/commands/users/create.zig
const std = @import("std");
const zcli = @import("zcli");
const lib = @import("lib");  // Your shared module!

pub const meta = .{
    .description = "Create a new user",
};

pub const Args = struct {
    email: []const u8,
};

pub const Options = struct {
    role: lib.UserRole = .user,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    if (!lib.validateEmail(args.email)) {
        try context.stderr().print("Invalid email address\n", .{});
        return error.InvalidEmail;
    }

    try context.stdout().print("Creating {s} user: {s}\n",
        .{ @tagName(options.role), args.email });
}
```

**Key Points:**

- Shared modules use standard Zig module patterns (`b.createModule()` and `addImport()`)
- Add them to both `exe.root_module` (for main.zig) and `shared_modules` array (for commands)
- Import by name: `@import("lib")`, not relative paths
- Shared modules can have their own dependencies

See [SHARED_MODULES_GUIDE.md](SHARED_MODULES_GUIDE.md) for complete details.

## Plugin System

zcli includes two essential plugins:

- **zcli-help** - Automatic help generation with colored output
- **zcli-not-found** - "Did you mean?" suggestions for typos

Both are included by default in the quick start example. The plugin system is extensible—you can create custom plugins to add global options, hooks, and behaviors.

## Examples

Check out the [examples/](examples/) directory for complete working projects:

- **[examples/basic](examples/basic)** - Simple Git-like CLI with nested commands
- **[examples/swapi](examples/swapi)** - API client with HTTP requests
- **[examples/advanced](examples/advanced)** - Docker-like CLI with complex commands

## Documentation

- **[DESIGN.md](packages/core/DESIGN.md)** - Complete framework design and architecture
- **[Error Handling Guide](packages/core/ERROR_HANDLING.md)** - Comprehensive error handling patterns
- **[Memory Management](packages/core/MEMORY.md)** - Memory ownership and cleanup guide
- **[Build System](packages/core/BUILD.md)** - Build-time code generation details

## Requirements

- Zig 0.15.1 or later

## License

MIT

---

Built with ❤️ for the Zig community. Contributions welcome!
