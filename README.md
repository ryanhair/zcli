# zcli

[![CI](https://github.com/ryanhair/zcli/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/ryanhair/zcli/actions/workflows/ci.yml)
[![Zig 0.16.0](https://img.shields.io/badge/zig-0.16.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/download/)
[![Release](https://img.shields.io/github/v/release/ryanhair/zcli?filter=v*)](https://github.com/ryanhair/zcli/releases)

**The filesystem is your command tree. The compiler is your argument parser.**

zcli is a batteries-included framework for building polished command-line apps in Zig. Drop a `.zig` file in `commands/` and it becomes a command — help text, shell completions, typo suggestions, and typed argument parsing are generated at compile time. One dependency, one self-contained binary.

**Full documentation lives at [zcli.sh](https://zcli.sh)** — [getting started](https://zcli.sh/getting-started/), the [docs](https://zcli.sh/docs/), [plugins](https://zcli.sh/plugins/), the [CLI/TUI hybrid](https://zcli.sh/ui/), [theming](https://zcli.sh/theming/), and [building CLIs with coding agents](https://zcli.sh/ai/). This README is the tour; the site is the reference.

<img alt="Demo of a zcli app: interactive prompts, a colored task table, live search filtering, and a spinner" src="examples/tasks/demo.gif" width="600" />

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
const Context = @import("command_registry").Context;

pub const meta = .{
    .description = "Deploy your application",
    .options = .{
        .env = .{ .short = 'e', .description = "Target environment" },
    },
};

pub const Args = struct { service: []const u8 };
pub const Options = struct { env: []const u8 = "production" };

pub fn execute(args: Args, options: Options, context: *Context) !void {
    try context.stdout().print("Deploying {s} to {s}\n", .{ args.service, options.env });
}
```

```
$ myapp deploy api --env staging
Deploying api to staging
```

No routing tables, no builder calls, no registration. Commands are discovered at build time and routing is generated as ordinary Zig code — the parser is built for your exact structs, so reading an option that doesn't exist is a compile error, and a mistyped command gets a "did you mean?" at runtime.

Variadic args, option types, typed `context`, aliases, and command groups: [zcli.sh/docs](https://zcli.sh/docs/#commands) (repo summary in [docs/COMMANDS.md](docs/COMMANDS.md)).

## Quick start

```bash
curl -fsSL https://zcli.sh/install.sh | sh    # install the zcli CLI (macOS/Linux)
zcli init myapp && cd myapp
zig build
./zig-out/bin/myapp hello World --loud
```

```powershell
irm https://zcli.sh/install.ps1 | iex         # install the zcli CLI (Windows)
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
zig fetch --save https://github.com/ryanhair/zcli/archive/refs/tags/v0.20.0.tar.gz
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
const Context = @import("command_registry").Context;

pub const meta = .{ .description = "Say hello" };
pub const Args = struct { name: []const u8 };
pub const Options = struct {};

pub fn execute(args: Args, _: Options, context: *Context) !void {
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
// In a zcli command — pre-wired to the command's streams, allocator, and theme.
// Standalone: `const Prompts = @import("prompts");` and fill the fields yourself.
const p = context.prompts();

const name = try p.text(.{
    .message = "Project name:",
    .default = "my-project",
});

const idx = try p.select(.{
    .message = "Framework:",
    .choices = &.{ "express", "fastify", "koa" },
});

const pw = try p.password(.{
    .message = "Token:",
});
```

Also: `confirm`, `multiSelect`, `search` (type-to-filter), `number` (range-validated), and `editor` (opens `$EDITOR`). Full API in [packages/prompts](packages/prompts/).

## Progress indicators

```zig
// Standalone: `const Progress = @import("progress");` and fill the fields yourself.
const p = context.progress();

var spinner = try p.spinner(.{ .style = .dots });
spinner.start("Connecting to server...");
spinner.succeed("Synced successfully"); // or .fail() / .warn() / .info()

var bar = try p.progressBar(.{ .total = items.len, .show_eta = true });
for (items, 0..) |item, i| {
    process(item);
    bar.update(i + 1, null);
}
bar.finish();
```

Nine spinner styles, plus stacked multi-bars for parallel work; animations auto-disable when not a TTY, symbols adapt to unicode support. Details in [packages/progress](packages/progress/).

## The CLI/TUI hybrid

Prompts and progress render on `zcli.ui` — a terminal-native layout engine, and it's yours to use directly. Output splits into a static stream that flows into scrollback and a live region that repaints in place just above it — a full layout, from a single line up to the whole viewport, not a fixed bottom strip. Unlike a full-screen TUI it never takes the terminal over, so your scrollback stays intact. This is the shape of modern agent-style CLIs: a component is just a function returning a node, and frames are diffed, so an animation repaints one cell, not the screen.

```zig
var app = try context.ui(.{});
defer app.deinit(); // restores the terminal; the final frame persists

try app.emit("compiled {s}", .{name});            // static → scrollback
try app.frame(try ui.column(app.arena(), .{ .border = .rounded }, &.{
    ui.widgets.spinner(.{}, state.tick),
    try ui.widgets.multiBar(app.arena(), .{}, &bars),
}));                                              // live → diffed repaint
```

Boxes, wrapped text, spacers, and custom leaves; `fit`/`len`/`fill` sizing; viewport-clamped, resize-aware (the live region re-lays-out and the visible scrollback tail reflows), and piped output degrades to plain lines.

When you want the whole terminal — a `top`-style dashboard, an interactive form — the same node tree, layout, and diff run in **full-screen mode**: `context.uiFullScreen(.{})` switches to the alternate screen and hands the `frame → event → update` loop to `app.run`. It comes with focusable widgets (`TextInput`, `Select`, `Checkbox`, `Button` — each a plain struct in your state, routed by a single `handle`-returns-`bool` contract), overlays via a `stack` of z-layers, scrollable viewports, mouse/focus/paste events, and anchored popups that flip and clamp to stay on screen. On exit the shell comes back exactly as it was. Walkthrough at [zcli.sh/ui](https://zcli.sh/ui/); design in [ADR-0013](docs/adr/0013-terminal-native-layout-engine.md) (full-screen and widgets in [ADRs 0015–0020](docs/adr/)), API in [packages/ui](packages/ui/).

## Theming

Declare a theme once in your root source file and the whole CLI follows it — help output, styled text, prompts, spinners, and progress bars:

```zig
// main.zig
pub const zcli_theme: zcli.Theme = .{
    .palette = .{
        .command = .{ .foreground = .{ .rgb = .{ .r = 255, .g = 179, .b = 71 } } },
        .accent = .{ .foreground = .{ .rgb = .{ .r = 255, .g = 179, .b = 71 } } },
    },
};
```

```zig
// In a command, style by meaning — roles resolve through the active palette:
const styled = zcli.theme.styled;

try styled("Synced").success().render(writer, &context.theme);
try styled("Error").red().bold().render(writer, &context.theme);
```

Semantic roles (`success`, `err`, `warning`, `command`, `path`, …) resolve at render time and adapt to the terminal: true color, 256 color, 16 color, or no color (respects `NO_COLOR`). Component tokens (`prompts.cursor`, `progress.spinner`, `surface.border`, …) default to palette roles, so one palette change restyles everything — including the chrome behind a full-screen panel. Styling defaults *derive* from the theme at compile time, so `ui.panel` and bordered boxes need no `Style` at the call site and `ui.text(ui.role(.success), …)` styles by meaning in one word. Guide at [zcli.sh/theming](https://zcli.sh/theming/); full API in [packages/theme](packages/theme/).

## Config files

The `zcli_config` plugin transparently loads option defaults from JSON, TOML, or YAML — zero changes to command code. Values cascade: **CLI flags > env vars > command config > global config > struct defaults**. A CLI flag or env var wins even when its value equals the struct default. Every option type coerces from config the same way it parses on the command line — bools, all int widths, floats, enums, arrays, and custom parse types.

```json
// .myapp.config.json
{
  "verbose": true,          // global — applies to all commands
  "list": { "all": true }   // scoped — applies only to "myapp list"
}
```

Discovery order and formats: [zcli.sh/docs/config](https://zcli.sh/docs/config/).

## Plugins

Cross-cutting features are plugins, added in one line of `build.zig`: help, version, "did you mean?", shell completions (bash/zsh/fish/PowerShell), config files, OS-keychain secrets, and self-upgrade via GitHub releases all ship in the box. Plugins hook the command lifecycle, register global options, expose typed data as `context.plugins.<id>`, and can ship commands of their own.

The full list and a guide to writing your own: [zcli.sh/plugins](https://zcli.sh/plugins/) (repo summary in [docs/PLUGINS.md](docs/PLUGINS.md)).

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

`result.term` is a real ANSI-parsing terminal emulator ([vterm](packages/vterm/)). Two more tiers — subprocess integration tests and snapshot tests — are covered at [zcli.sh/testing](https://zcli.sh/testing/).

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

The [showcase](examples/tasks/) is a fully functional task tracker CLI — the app in the demo GIF above — that exercises most zcli features: 14 commands with nested groups and aliases, six of the eight prompt types, spinners and progress bars, themed output, JSON persistence, config files, completions, and doc generation.

```bash
cd examples/tasks && zig build
./zig-out/bin/tasks init          # Interactive project wizard
./zig-out/bin/tasks add           # Add a task interactively
./zig-out/bin/tasks list          # Colored task list
./zig-out/bin/tasks search        # Live search with filtering
```

## Built with zcli

What a real zcli app looks like. The meta-CLI you install is one; the rest are the compiled, CI-checked example apps in this repo — each a small, complete CLI you can read end to end.

| App | What it is |
|-----|------------|
| [**zcli**](projects/zcli) — the meta-CLI | Itself a zcli app: `init`, `add`, `mv`, `rm`, `tree`, `dev`, `guide`, and `release` are files in its `commands/` directory, running on the framework's own plugins (help, completions, "did you mean?", GitHub self-upgrade). |
| [**tasks**](examples/tasks) | A full task tracker — the app in the demo GIF above. 14 commands with nested groups and aliases, six of the eight prompt types, spinners and progress bars, themed output, JSON persistence, config files, and completions. |
| [**ghauth**](examples/ghauth) | GitHub device-flow companion: stashes an API token in the OS keychain via `zcli_secrets`, then uses `zcli.http` to call the API as `whoami`. |
| [**oauth-device**](examples/oauth-device) | Mints a token from scratch by running GitHub's OAuth device flow (RFC 8628), then keychains it — freeform command code, not a framework feature. |
| [**notes**](examples/notes) | A tiny note keeper: saves and loads a typed struct as a JSON file and shares one `store` module across three commands. |
| [**repostat**](examples/repostat) | Prints stats for a public GitHub repo — the minimal `zcli.http` + typed-JSON example, with safe client defaults out of the box. |

Building something with zcli? Open a PR to add it here.

## Packages

| Package | Description |
|---------|-------------|
| [**core**](packages/core/) | Command discovery, argument parsing, plugin system, registry |
| [**prompts**](packages/prompts/) | Interactive prompts (text, confirm, select, password, search, number, editor) |
| [**progress**](packages/progress/) | Spinners and progress bars |
| [**theme**](packages/theme/) | Terminal theming with semantic colors and capability detection |
| [**markdown**](packages/markdown/) | Markdown-to-terminal formatting with semantic tags |
| [**terminal**](packages/terminal/) | Raw mode, key reading, cursor control, unicode detection |
| [**vterm**](packages/vterm/) | Virtual terminal emulator for testing ANSI output |
| [**testing**](packages/testing/) | Subprocess runner, assertions, snapshot testing, e2e harness |

All packages work standalone — use `prompts`, `progress`, `theme`, or `terminal` in any Zig project without the framework.

## Zig version support

zcli targets **stable Zig** — no nightly required. `main` and the latest release are built and tested against Zig 0.16.0 on Linux, macOS, and Windows in CI on every commit.

| zcli | Zig |
|------|-----|
| `main`, v0.18.0 and later | 0.16.0 |
| v0.14.0 – v0.17.0 | 0.15.1 |

Each release is tagged twice: `vX.Y.Z` is the framework library — the tag for your `build.zig.zon` — and `zcli-vX.Y.Z` carries the prebuilt meta-CLI binaries that `install.sh` downloads. The two ship in lockstep. Release history and the versioning policy live in [CHANGELOG.md](CHANGELOG.md).

### Verifying a release

CLI releases are signed. `checksums.txt` carries a SHA-256 for every binary and is itself signed with a [minisign](https://jedisct1.github.io/minisign/) key held offline — so a compromised release cannot forge a matching signature, not just a matching checksum. `install.sh` **requires `minisign`** and verifies the signature before installing (fail closed); `zcli upgrade` verifies it natively with no external tools. To check by hand:

```bash
gh release download zcli-vX.Y.Z -p 'checksums.txt*'
minisign -Vm checksums.txt -p docs/zcli-minisign.pub   # verifies the signature
sha256sum -c checksums.txt                              # then the binaries
```

The trust model and the key rotation/compromise procedure live in [docs/RELEASE-SIGNING.md](docs/RELEASE-SIGNING.md) ([ADR-0023](docs/adr/0023-release-signing-minisign.md)).

## Stability & the road to 1.0

zcli is pre-1.0: breaking changes can land in minor versions and are always
called out in the CHANGELOG; patch versions are always safe. The core command
contract (`meta`/`Args`/`Options`/`execute`), the plugin hooks, and the
`build.zig` integration have been stable across releases — the remaining churn is
scoped and mechanical.

If you're evaluating whether to adopt now or wait, [ROADMAP.md](ROADMAP.md) lays
out what freezes at 1.0, what stays deliberately open, what must land first, and
how to pin and upgrade safely today.

## License

MIT
