# zcli

A batteries-included framework for building command-line interfaces in Zig. Drop `.zig` files in a directory and get a fully-featured CLI — help text, completions, error suggestions, interactive prompts, progress bars, and documentation — with command discovery and routing wired up at compile time for zero-cost dispatch.

## Features

- Create files in `commands/` folder to add commands. Create folders to add subcommands.
- Define arguments and options as Zig structs — type-safe parsing at compile time.
- Auto-generated `--help`, `--version`, shell completions, and "did you mean?" suggestions.
- Transparent config file loading from JSON, TOML, or YAML with per-command scoping.
- Interactive prompts — text, confirm, select, multi-select, password, search, number, editor.
- Progress indicators — spinners (9 styles) and progress bars with ETA.
- Theming with semantic colors that adapt to terminal capabilities.
- Documentation generation — markdown, man pages, and HTML from command metadata.
- Plugin system with lifecycle hooks, global options, and build-time configuration.
- Zero-cost dispatch — commands are discovered and routing is generated at build time (no reflection or runtime filesystem scanning). Argument parsing is type-checked via comptime introspection and runs at invocation.

```zig
// src/commands/deploy.zig
const zcli = @import("zcli");

pub const meta = .{
    .description = "Deploy your application",
    .options = .{
        .env = .{ .short = 'e', .description = "Target environment" },
    },
};

pub const Args = struct { service: []const u8 };
pub const Options = struct { env: []const u8 = "production" };

pub fn execute(args: Args, options: Options, context: anytype) !void {
    try context.stdout().print("Deploying {s} to {s}\n", .{ args.service, options.env });
}
```

```
$ myapp deploy api --env staging
Deploying api to staging
```

---

## Quick Start

### 1. Add zcli to your project

```zig
// build.zig.zon
.dependencies = .{
    .zcli = .{
        .url = "https://github.com/ryanhair/zcli/archive/refs/heads/main.tar.gz",
        .hash = "...",  // zig build will tell you the correct hash
    },
},
```

### 2. Set up build.zig

```zig
const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zcli_dep = b.dependency("zcli", .{ .target = target, .optimize = optimize });
    const zcli_module = zcli_dep.module("zcli");

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("zcli", zcli_module);

    const zcli = @import("zcli");
    const cmd_registry = try zcli.generate(b, exe, zcli_dep, zcli_module, .{
        .commands_dir = "src/commands",
        .plugins = &[_]zcli.PluginConfig{
            .{ .name = "zcli_help", .path = "packages/core/src/plugins/zcli_help" },
            .{ .name = "zcli_version", .path = "packages/core/src/plugins/zcli_version" },
            .{ .name = "zcli_not_found", .path = "packages/core/src/plugins/zcli_not_found" },
        },
        .app_name = "myapp",
        .app_description = "My CLI application",
    });

    exe.root_module.addImport("command_registry", cmd_registry);
    b.installArtifact(exe);
}
```

### 3. Create main.zig and your first command

```zig
// src/main.zig
const registry = @import("command_registry");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var app = registry.init();
    app.run(gpa.allocator()) catch |err| switch (err) {
        error.CommandNotFound => std.process.exit(1),
        else => return err,
    };
}
```

```zig
// src/commands/hello.zig
pub const meta = .{ .description = "Say hello" };
pub const Args = struct { name: []const u8 };
pub const Options = struct {};

pub fn execute(args: Args, _: Options, context: anytype) !void {
    try context.stdout().print("Hello, {s}!\n", .{args.name});
}
```

```
$ zig build && ./zig-out/bin/myapp hello world
Hello, world!
```

---

## Commands

Commands are `.zig` files in your commands directory. The file path becomes the command path:

```
src/commands/
├── init.zig              → myapp init
├── deploy.zig            → myapp deploy
└── users/
    ├── create.zig        → myapp users create
    └── list.zig          → myapp users list
```

### Command structure

Every command has up to four exports:

```zig
const zcli = @import("zcli");
// Name your app's generated context type for full editor autocomplete on `context`.
const Context = @import("command_registry").Context;

pub const meta = .{
    .description = "Add files to the index",
    .examples = &.{ "add file.txt", "add --all" },
    .args = .{ .files = "Files to add" },
    .options = .{
        .all = .{ .short = 'a', .description = "Add all files" },
    },
    .aliases = &.{ "a" },
};

pub const Args = struct {
    files: []const []const u8,          // variadic: captures remaining args
};

pub const Options = struct {
    all: bool = false,                  // --all / -a (flag)
    output: []const u8 = "text",        // --output <value>
    count: u32 = 1,                     // --count <number>
    verbose: ?bool = null,              // optional flag
};

pub fn execute(args: Args, options: Options, context: *Context) !void {
    // context.stdout(), context.stderr(), context.allocator, context.theme,
    // context.plugins.<plugin_id>, etc. — all typed and autocompletable.
}
```

#### Typing `context`

`Context` is generated per-app from your config and plugin set, so it carries a
typed field for every plugin's data (`context.plugins.<plugin_id>`). You can type
the parameter two ways:

- **`context: *Context`** (above) — import `@import("command_registry").Context`.
  Best for app-local commands: full autocomplete, go-to-definition, and errors at
  the definition site. There's no import cycle — `Context` depends only on your
  config and plugins, not on the command files.
- **`context: anytype`** — portable across apps with no editor hints. Use this for
  reusable/library commands and inside plugin hooks (a plugin is compiled
  independently of the app that hosts it).

### Command groups

Add an `index.zig` to give a directory a description:

```zig
// src/commands/users/index.zig
pub const meta = .{ .description = "Manage users" };
// No execute — running "myapp users" shows subcommands
```

---

## Plugins

zcli ships with seven plugins. Add them in `build.zig`:

| Plugin | Provides | Default? |
|--------|----------|----------|
| **zcli_help** | `--help` / `-h`, auto-generated help text | Yes |
| **zcli_version** | `--version` / `-V` | Yes |
| **zcli_not_found** | "Did you mean?" suggestions for typos | Yes |
| **zcli_completions** | `completions generate/install/uninstall` for bash, zsh, fish | Optional |
| **zcli_config** | Transparent config file loading (JSON, TOML, YAML) | Optional |
| **zcli_output** | `--output` flag (json, table, plain) | Optional |
| **zcli_github_upgrade** | `upgrade` command via GitHub releases | Optional |

### Plugin context data

Plugins store data in `context.plugins.{plugin_id}`:

```zig
// In a command, check if help was requested
if (context.plugins.zcli_help.help_requested) { ... }
```

### Writing plugins

```zig
pub const plugin_id = "my_plugin";
pub const ContextData = struct { enabled: bool = false };

pub const global_options = [_]zcli.GlobalOption{
    zcli.option("verbose", bool, .{ .short = 'v', .default = false }),
};

pub fn handleGlobalOption(context: anytype, name: []const u8, value: anytype) !void {
    // Store option values in context.plugins.my_plugin
}

pub fn preExecute(context: anytype, args: zcli.ParsedArgs) !?zcli.ParsedArgs {
    // Run before every command. Return null to stop execution.
    return args;
}

pub fn onError(context: anytype, err: anyerror) !bool {
    // Handle errors. Return true if handled.
    return false;
}
```

### Config file plugin

The `zcli_config` plugin transparently loads option defaults from a config file. Supports JSON, TOML, and YAML — no changes to command code required.

```zig
// In build.zig plugins:
.{ .name = "zcli_config", .path = "packages/core/src/plugins/zcli_config" },
```

Config file discovery (by extension priority):
1. `--config <path>` flag
2. `./{app_name}.config.json` / `.toml` / `.yaml` / `.yml`
3. `$XDG_CONFIG_HOME/{app_name}/config.json` / `.toml` / `.yaml` / `.yml`

Values cascade: **CLI flags > command config > global config > struct defaults**.

```json
// .myapp.config.json
{
  "output": "json",         // global — applies to all commands
  "list": {                 // scoped — applies only to "list" command
    "all": true
  }
}
```

```toml
# .myapp.config.toml
output = "json"

[list]
all = true
```

```yaml
# .myapp.config.yaml
output: json
list:
  all: true
```

---

## Interactive Prompts

The `zinput` package provides 8 prompt types. Works standalone — no zcli dependency required.

```zig
const zinput = zcli.zinput;  // or @import("zinput")

// Text input
const name = try zinput.text(writer, reader, allocator, .{
    .message = "Project name:",
    .default = "my-project",
});

// Confirmation
const ok = try zinput.confirm(writer, reader, .{
    .message = "Continue?",
    .default = true,
});

// Single selection (arrow keys + enter)
const idx = try zinput.select(writer, reader, .{
    .message = "Framework:",
    .choices = &.{ "express", "fastify", "koa" },
});

// Multi-selection (space to toggle, enter to confirm)
const features = try zinput.multiSelect(writer, reader, allocator, .{
    .message = "Features:",
    .choices = &.{ "typescript", "eslint", "prettier" },
    .defaults = &.{ true, true, false },
});

// Password (masked input)
const pw = try zinput.password(writer, reader, allocator, .{
    .message = "Token:",
});

// Search (type to filter, arrow keys to navigate)
const pkg = try zinput.search(writer, reader, allocator, .{
    .message = "Package:",
    .choices = &.{ "express", "fastify", "koa", "hapi", "nest" },
});

// Number (with validation)
const port = try zinput.number(writer, reader, .{
    .message = "Port:",
    .default = 3000,
    .min = 1,
    .max = 65535,
});

// Editor (launches $EDITOR)
const msg = try zinput.editor(writer, reader, allocator, .{
    .message = "Commit message:",
    .default = "feat: ",
    .extension = ".md",
});
```

All prompts fall back to line-based input when stdin is not a TTY. The `prefix` field (default `"? "`) is configurable on all types.

---

## Progress Indicators

```zig
const zprogress = zcli.zprogress;

// Spinner
var spinner = zprogress.spinner(.{ .style = .dots });
spinner.start("Loading...");
// ... do work, call spinner.tick() in a loop ...
spinner.succeed("Done!");      // ✔ Done!
spinner.fail("Failed");        // ✖ Failed
spinner.warn("Warning");       // ⚠ Warning

// Progress bar
var bar = zprogress.progressBar(.{
    .total = 100,
    .show_eta = true,
    .show_rate = true,
});
for (0..100) |i| {
    bar.update(i + 1, null);
}
bar.finish();
```

9 spinner styles: `dots`, `dots2`, `dots3`, `line`, `arrow`, `bounce`, `clock`, `moon`, `simple`. Auto-disables animations when not a TTY. Symbols adapt to terminal unicode support.

---

## Theming

```zig
const ztheme = zcli.ztheme;

var theme_ctx = ztheme.Theme.init(allocator);

// Fluent API
try ztheme.theme("Error").red().bold().render(writer, &theme_ctx);
try ztheme.theme("Success").success().render(writer, &theme_ctx);

// Semantic roles: success, err, warning, info, muted, command, flag, path, value, code, header, link
```

Adapts to terminal capabilities: true color, 256 color, 16 color, or no color (respects `NO_COLOR`).

---

## Documentation Generation

Generate markdown, man pages, or HTML documentation from your command metadata — automatically on every build:

```zig
// In build.zig, after generate():
zcli.generateDocs(b, cmd_registry, zcli_dep, zcli_module, .{
    .formats = &.{ "markdown", "man", "html" },
    .output_dir = "docs",
});
```

Run `zig build` and docs appear in `docs/markdown/`, `docs/man/`, `docs/html/`. Single format goes directly into the output dir. HTML includes a styled, dark-mode-aware static site with navigation.

---

## Testing

zcli provides three tiers of testing. See [docs/TESTING.md](docs/TESTING.md) for full documentation.

### Unit testing (in-process)

Test commands directly without compiling a binary:

```zig
const testing = @import("zcli-testing");

test "deploy command" {
    var result = try testing.runCommand(DeployCommand, .{
        .args = .{ .service = "api" },
        .options = .{ .env = "staging" },
    });
    defer result.deinit();

    // Assert on raw text
    try std.testing.expectEqualStrings("Deploying api to staging\n", result.stdout);

    // Assert on rendered terminal (colors, formatting)
    try std.testing.expect(result.term.containsText("Deploying"));
    try std.testing.expect(result.term.hasAttribute(0, 0, .bold));
}
```

`result.term` is a virtual terminal ([vterm](packages/vterm/)) that parses ANSI codes — test colors, bold/italic, cursor position, and formatted output.

### Integration testing (subprocess)

```zig
const testing = @import("zcli-testing");

test "help flag" {
    var result = try testing.runSubprocess(allocator, "./zig-out/bin/myapp", &.{"--help"});
    defer result.deinit();
    try testing.expectExitCode(result, 0);
    try testing.expectContains(result.stdout, "USAGE:");
}
```

### Snapshot testing

```zig
try testing.expectSnapshot(allocator, result.stdout, @src(), "help_output", .{});
// Update: UPDATE_SNAPSHOTS=1 zig build test
```

---

## Packages

| Package | Description |
|---------|-------------|
| **core** | Command discovery, argument parsing, plugin system, registry |
| **zinput** | Interactive prompts (text, confirm, select, password, search, number, editor) |
| **zprogress** | Spinners and progress bars |
| **ztheme** | Terminal theming with semantic colors and capability detection |
| **markdown_fmt** | Markdown-to-terminal formatting with semantic tags |
| **terminal** | Raw mode, key reading, cursor control, unicode detection |
| **vterm** | Virtual terminal emulator for testing ANSI output |
| **testing** | Subprocess runner, assertions, snapshot testing, e2e harness |
| **interactive** | PTY-based test harness for interactive CLI testing |

All packages work standalone — you can use `zinput`, `zprogress`, `ztheme`, or `terminal` in any Zig project without the zcli framework.

---

## Example

The [showcase](examples/showcase/) is a fully functional task tracker CLI that demonstrates every zcli feature:

- **14 commands** with args, options, aliases, and nested groups
- **Interactive prompts** — text, confirm, select, search, number, password, editor
- **Progress indicators** — spinners and progress bars
- **Colored output** — status badges, themed formatting
- **JSON persistence** — read/write tasks to disk
- **Config file** — per-command defaults via `.tasks.config.json`
- **Shell completions**, **doc generation**, **help**, and **error suggestions**

```bash
cd examples/showcase && zig build
./zig-out/bin/tasks init          # Interactive project wizard
./zig-out/bin/tasks add "My task" # Add via flags
./zig-out/bin/tasks add           # Add interactively
./zig-out/bin/tasks list          # Colored task list
./zig-out/bin/tasks search        # Search with filtering
./zig-out/bin/tasks sync          # Spinner demo
```

The `zcli` meta-CLI scaffolds new projects: `zcli init myproject`

---

## License

MIT
