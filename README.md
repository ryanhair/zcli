# zcli

[![CI](https://github.com/ryanhair/zcli/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/ryanhair/zcli/actions/workflows/ci.yml)
[![Zig 0.16.0](https://img.shields.io/badge/zig-0.16.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/download/)
[![Release](https://img.shields.io/github/v/release/ryanhair/zcli?filter=v*)](https://github.com/ryanhair/zcli/releases)

**The filesystem is your command tree. The compiler is your argument parser.**

zcli is a batteries-included framework for building polished command-line apps in Zig. Drop a `.zig` file in `commands/` and it becomes a command — help text, shell completions, typo suggestions, and typed argument parsing are generated at compile time. One dependency, one self-contained binary.

<img alt="Demo of a zcli app: interactive prompts, a colored task table, live search filtering, and a spinner" src="examples/showcase/demo.gif" width="600" />

## Your CLI is a directory

```
src/commands/
├── deploy.zig            → myapp deploy
└── users/
    ├── create.zig        → myapp users create
    └── list.zig          → myapp users list
```

A command is one file: a `meta` block for help text, two structs, and an `execute` function.

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

No routing tables, no builder calls, no registration. Commands are discovered at build time and routing is generated as ordinary Zig code — the parser is built for your exact structs, so reading an option that doesn't exist is a compile error, and a mistyped command gets a "did you mean?" at runtime.

Variadic args, option types, typed `context`, aliases, and command groups: [docs/COMMANDS.md](docs/COMMANDS.md).

## Quick start

```bash
curl -fsSL https://zcli.sh/install.sh | sh    # install the zcli CLI
zcli init myapp && cd myapp
zig build
./zig-out/bin/myapp hello World --loud
```

```
HELLO, World!
```

The scaffolded binary already has `--help`, `--version`, and typo suggestions wired up. From there, `zcli add command users/create` adds commands, `zcli dev` watches and rebuilds, `zcli tree` prints the command hierarchy, and `zcli guide` teaches the framework's idioms (to you or your coding agent).

The framework itself is an ordinary Zig dependency — the meta-CLI is optional:

<details>
<summary><strong>Manual setup</strong> — add zcli to an existing project</summary>

Pin the release in your `build.zig.zon` with an immutable hash:

```bash
zig fetch --save https://github.com/ryanhair/zcli/archive/refs/tags/v0.19.0.tar.gz
```

To track the development branch instead, fetch `.../archive/refs/heads/main.tar.gz` — its hash changes with every commit, so re-run the command to update.

```zig
// build.zig
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
    const cmd_registry = try zcli.generate(b, exe, zcli_dep, .{
        .commands_dir = "src/commands",
        .plugins = &.{
            zcli.builtin(.help, .{}),
            zcli.builtin(.version, .{}),
            zcli.builtin(.not_found, .{}),
        },
        .app_name = "myapp",
        .app_description = "My CLI application",
    });

    exe.root_module.addImport("command_registry", cmd_registry);
    b.installArtifact(exe);
}
```

```zig
// src/main.zig
const std = @import("std");
const registry = @import("command_registry");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var app = registry.init();
    app.run(init.gpa, init.io, init.environ_map, args) catch |err| switch (err) {
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

</details>

## What's in the box

**Files are commands.** Build-time discovery, zero-cost dispatch, comptime-checked args and options, aliases, nested groups — plus auto-generated help, version, shell completions, and "did you mean?" suggestions.

**The whole terminal toolkit.** Eight interactive prompts (text, confirm, select, multi-select, password, search, number, editor), spinners and progress bars with ETA, semantic theming that adapts to terminal capabilities, markdown-to-terminal rendering. Every piece is a standalone package that works without the framework.

**Production polish for free.** Config files (JSON/TOML/YAML) with per-command scoping, secrets in the OS keychain, self-upgrade from GitHub releases, man/HTML/markdown doc generation on every build, and a virtual-terminal test harness that can assert "this output is green and bold."

## Why zcli?

Zig already has good CLI libraries — the difference is the level they operate at.

[zig-clap](https://github.com/Hejsil/zig-clap) is an argument parser, and the lightest of the three: describe flags in a comptime help-text DSL, get typed results back, build the rest of the CLI yourself. If flag parsing is all you need, it's a great choice. [zli](https://github.com/xcaeser/zli) is a batteries-included framework built around a runtime builder: commands are constructed with `Command.init(...)`, wired up with `addCommand`, flags registered with `addFlag` and read by name — the command tree is assembled when the program starts.

zcli moves that work to the filesystem and the compiler. The directory tree *is* the command tree, discovered at build time with routing generated as ordinary Zig code. Arguments and options are plain structs, so the parser is generated for your exact types. And the batteries extend past parsing into the whole terminal experience.

| | zig-clap | zli | zcli |
|---|----------|-----|------|
| Scope | argument parser | CLI framework | CLI framework |
| Commands defined by | manual dispatch | runtime builder | files on disk, discovered at build time |
| Flags are | comptime DSL → typed result | registered at runtime, read by name | struct fields, checked at compile time |
| Beyond parsing | help text | help, version, spinners | help, completions, prompts, progress, theming, config files, plugins, testing tools |

If you want one dependency that covers the whole terminal experience, that's the niche zcli aims to fill.

## Interactive prompts

Eight prompt types with arrow-key navigation, live filtering, and unicode-correct editing. Every prompt falls back to plain line input when stdin isn't a TTY, so scripts and pipes keep working.

```zig
const zinput = zcli.zinput;  // or standalone: @import("zinput")

const name = try zinput.text(writer, reader, allocator, .{
    .message = "Project name:",
    .default = "my-project",
});

const idx = try zinput.select(writer, reader, .{
    .message = "Framework:",
    .choices = &.{ "express", "fastify", "koa" },
});

const pw = try zinput.password(writer, reader, allocator, .{
    .message = "Token:",
});
```

Also: `confirm`, `multiSelect`, `search` (type-to-filter), `number` (range-validated), and `editor` (opens `$EDITOR`). Full API in [packages/zinput](packages/zinput/).

## Progress indicators

```zig
const zprogress = zcli.zprogress;  // or standalone: @import("zprogress")

var spinner = zprogress.spinner(io, .{ .style = .dots });
spinner.start("Connecting to server...");
spinner.succeed("Synced successfully"); // or .fail() / .warn() / .info()

var bar = zprogress.progressBar(io, .{ .total = items.len, .show_eta = true });
for (items, 0..) |item, i| {
    process(item);
    bar.update(i + 1, null);
}
bar.finish();
```

Nine spinner styles; animations auto-disable when not a TTY, symbols adapt to unicode support. Details in [packages/zprogress](packages/zprogress/).

## Theming

```zig
const ztheme = zcli.ztheme;  // or standalone: @import("ztheme")

// In a zcli command you already have one: context.theme. Standalone:
const theme_ctx = ztheme.Theme.init(init.environ_map, io);

try ztheme.theme("Error").red().bold().render(writer, &theme_ctx);
try ztheme.theme("Success").success().render(writer, &theme_ctx);
```

Semantic roles (`success`, `err`, `warning`, `command`, `path`, …) adapt to the terminal: true color, 256 color, 16 color, or no color (respects `NO_COLOR`). Full API in [packages/ztheme](packages/ztheme/).

## Config files

The `zcli_config` plugin transparently loads option defaults from JSON, TOML, or YAML — zero changes to command code. Values cascade: **CLI flags > command config > global config > struct defaults**.

```json
// .myapp.config.json
{
  "output": "json",         // global — applies to all commands
  "list": { "all": true }   // scoped — applies only to "myapp list"
}
```

Discovery order and formats in [docs/PLUGINS.md](docs/PLUGINS.md#config-file-plugin).

## Plugins

Cross-cutting features are plugins, added in one line of `build.zig`: help, version, "did you mean?", shell completions (bash/zsh/fish), config files, `--output` formatting (json/table/plain), OS-keychain secrets, and self-upgrade via GitHub releases all ship in the box. Plugins hook the command lifecycle, register global options, expose typed data as `context.plugins.<id>`, and can ship commands of their own.

The full list and a guide to writing your own: [docs/PLUGINS.md](docs/PLUGINS.md).

## Testing

Test commands in-process against a virtual terminal — assert on colors and formatting, not escape codes:

```zig
const testing = @import("zcli-testing");

test "deploy command" {
    var result = try testing.runCommand(DeployCommand, .{
        .args = .{ .service = "api" },
        .options = .{ .env = "staging" },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Deploying api to staging\n", result.stdout);
    try std.testing.expect(result.term.containsText("Deploying"));
    try std.testing.expect(result.term.hasAttribute(0, 0, .bold));
}
```

`result.term` is a real ANSI-parsing terminal emulator ([vterm](packages/vterm/)). Two more tiers — subprocess integration tests and snapshot tests — are covered in [docs/TESTING.md](docs/TESTING.md).

## Documentation generation

Generate markdown, man pages, or HTML documentation from your command metadata — automatically on every build:

```zig
// In build.zig, after generate():
zcli.generateDocs(b, cmd_registry, zcli_dep, .{
    .formats = &.{ "markdown", "man", "html" },
    .output_dir = "docs",
});
```

The HTML output is a styled, dark-mode-aware static site with navigation.

## Example

The [showcase](examples/showcase/) is a fully functional task tracker CLI — the app in the demo GIF above — that exercises every zcli feature: 14 commands with nested groups and aliases, every prompt type, spinners and progress bars, themed output, JSON persistence, config files, completions, and doc generation.

```bash
cd examples/showcase && zig build
./zig-out/bin/tasks init          # Interactive project wizard
./zig-out/bin/tasks add           # Add a task interactively
./zig-out/bin/tasks list          # Colored task list
./zig-out/bin/tasks search        # Live search with filtering
```

## Built with zcli

- **[zcli](projects/zcli)** — the meta-CLI is itself a zcli app: `init`, `add`, `mv`, `rm`, `tree`, `dev`, `guide`, and `release` are files in its `commands/` directory, and it runs on the framework's own plugins (help, completions, "did you mean?", GitHub self-upgrade).
- **[tasks](examples/showcase)** — the showcase task tracker from the demo above.

Building something with zcli? Open a PR to add it here.

## Packages

| Package | Description |
|---------|-------------|
| [**core**](packages/core/) | Command discovery, argument parsing, plugin system, registry |
| [**zinput**](packages/zinput/) | Interactive prompts (text, confirm, select, password, search, number, editor) |
| [**zprogress**](packages/zprogress/) | Spinners and progress bars |
| [**ztheme**](packages/ztheme/) | Terminal theming with semantic colors and capability detection |
| [**markdown_fmt**](packages/markdown_fmt/) | Markdown-to-terminal formatting with semantic tags |
| [**terminal**](packages/terminal/) | Raw mode, key reading, cursor control, unicode detection |
| [**vterm**](packages/vterm/) | Virtual terminal emulator for testing ANSI output |
| [**testing**](packages/testing/) | Subprocess runner, assertions, snapshot testing, e2e harness |

All packages work standalone — use `zinput`, `zprogress`, `ztheme`, or `terminal` in any Zig project without the framework.

## Zig version support

zcli targets **stable Zig** — no nightly required. `main` and the latest release are built and tested against Zig 0.16.0 on Linux, macOS, and Windows in CI on every commit.

| zcli | Zig |
|------|-----|
| `main`, v0.18.0 and later | 0.16.0 |
| v0.14.0 – v0.17.0 | 0.15.1 |

Each release is tagged twice: `vX.Y.Z` is the framework library — the tag for your `build.zig.zon` — and `zcli-vX.Y.Z` carries the prebuilt meta-CLI binaries that `install.sh` downloads. The two ship in lockstep. Release history and the versioning policy live in [CHANGELOG.md](CHANGELOG.md).

## License

MIT
