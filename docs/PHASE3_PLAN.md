# Phase 3: Differentiation Features

## Context

Phases 1-2 cleaned up the codebase and polished DX. Phase 3 adds features that make zcli a "batteries included" framework — the kind of things that make developers choose zcli over raw arg parsing.

### What already exists

- **`packages/interactive/`** — PTY-based test harness for interactive CLIs (signal forwarding, terminal modes, script builder). This is for *testing* interactive programs, not providing interactive prompts to users.
- **`packages/testing/`** — Subprocess runner, fluent assertions, snapshot testing. Solid but subprocess-only (`runInProcess` is stubbed).
- **Environment variable support** — Already in the option parser. `CLI > env > defaults` precedence works.
- **Rich metadata at runtime** — `CommandInfo`, `OptionInfo`, descriptions, examples, aliases — all available to plugins via `context.getAvailableCommandInfo()`.
- **Shell completions** — Bash/zsh work, fish is incomplete (per-command options TODO).

---

## Feature 1: Command Testing Harness

**Why first**: Every serious CLI needs tests. zcli has subprocess testing but no way to test a single command in-process without compiling and running the full binary.

### Design

Add a `zcli.testing` module (or extend `packages/testing/`) with an in-process command runner:

```zig
const zcli_test = @import("zcli").testing;

test "add command" {
    const result = try zcli_test.runCommand(
        AddCommand,          // The command module
        &.{MyPlugin},        // Plugins to activate (uses TestContext)
        .{
            .args = .{ .name = "widget", .count = 5 },
            .options = .{ .verbose = true },
        },
    );
    defer result.deinit();

    try std.testing.expectEqualStrings("Added 5 widgets\n", result.stdout);
    try std.testing.expect(result.stderr.len == 0);
}
```

### What it provides

- **`runCommand(Command, plugins, config)`** — Runs a command's `execute()` with captured stdout/stderr
- **`TestResult`** — Contains `.stdout`, `.stderr` as strings, plus the context for inspection
- No subprocess overhead — runs in-process using `TestContext`
- Plugins get initialized properly (their `ContextData` is available)
- IO is captured via fixed buffer streams, not real file descriptors

### Implementation notes

- Uses `zcli.TestContext(plugins)` to build the context type
- Creates `IO` with `fixedBufferStream` writers instead of real stdout/stderr
- Calls `Command.execute(args, options, &context)` directly
- Returns captured output

### Files to create/modify

- `packages/core/src/testing.zig` — New module with `runCommand`, `TestResult`
- `packages/core/src/zcli.zig` — Re-export as `pub const testing = @import("testing.zig");` (but careful: `testing` conflicts with `std.testing` — maybe `command_testing` or `test_runner`)

---

## Feature 2: Doc Generation Plugin

**Why second**: All the metadata already exists. This is low-hanging fruit with high visibility.

### Design

A build-time step that generates documentation from command metadata:

```zig
// In build.zig:
const docs = zcli.generateDocs(b, cmd_registry, .{
    .format = .markdown,         // or .man_page
    .output_dir = "docs/commands",
});
```

### What it generates

**Markdown** (one file per command + index):
```markdown
# myapp users create

Create a new user account.

## Usage

    myapp users create <name> [--admin] [--role <role>]

## Arguments

| Name | Required | Description |
|------|----------|-------------|
| name | yes      | Username    |

## Options

| Flag | Short | Default | Description |
|------|-------|---------|-------------|
| --admin | -a | false | Grant admin privileges |
| --role  | -r | user  | User role |

## Examples

    myapp users create john --admin
    myapp users create jane --role moderator
```

**Man pages** (`myapp.1`, `myapp-users-create.1`):
- Standard roff format
- Installable to `zig-out/share/man/man1/`

### Implementation notes

- New build utility: `packages/core/src/build_utils/doc_generation.zig`
- Reads the same `CommandInfo` metadata that help/completions use
- Iterates all registered commands (from generated registry)
- Writes files via `b.addWriteFiles()`

### Files to create/modify

- `packages/core/src/build_utils/doc_generation.zig` — New: markdown + man page generators
- `packages/core/src/build_utils/main.zig` — Add `generateDocs()` public function
- `packages/core/build.zig` — Re-export `generateDocs`

---

## Feature 3: Config File Loading Plugin

**Why third**: Builds on existing env var support. The pattern of `CLI > config > env > defaults` is universal.

### Design

A plugin that loads config from standard locations:

```zig
// In build.zig:
.plugins = &.{
    .{
        .name = "zcli-config",
        .path = "packages/core/src/plugins/zcli_config",
        .config = .{
            .format = .toml,          // or .json
            .app_name = "myapp",      // determines file paths
        },
    },
},
```

### Config file discovery (standard paths)

1. `./.myapprc` (project-local)
2. `$XDG_CONFIG_HOME/myapp/config.toml` (user config)
3. `~/.config/myapp/config.toml` (fallback)

### Precedence

```
CLI flags > environment variables > config file > defaults
```

### How commands access config values

Config values map to option fields. If `Options` has a field `database_url`, the config file can set it:

```toml
database_url = "postgres://localhost/mydb"
```

The option parser already handles env vars — config file values would be injected at the same layer, before env vars are checked.

### Implementation notes

- New plugin: `packages/core/src/plugins/zcli_config/`
- Uses `onStartup` hook to load config file into plugin context data
- Uses `preParse` hook to inject config values as synthetic args
- TOML parsing: would need a comptime or runtime TOML parser (or start with JSON since `std.json` exists)
- Start with JSON (stdlib support), add TOML later

### Files to create

- `packages/core/src/plugins/zcli_config/plugin.zig`

---

## Feature 4: Interactive Prompts (`zinput`)

**Why last**: Biggest scope, highest reward. Makes zcli viable for `init`-style wizards.

### Design

A standalone package (like zprogress, ztheme) that provides user-facing interactive prompts:

```zig
const zinput = zcli.zinput;

// Text input with default
const name = try zinput.text(writer, reader, .{
    .message = "Project name:",
    .default = "my-project",
});

// Confirmation
const proceed = try zinput.confirm(writer, reader, .{
    .message = "Overwrite existing files?",
    .default = false,
});

// Selection from list
const framework = try zinput.select(writer, reader, .{
    .message = "Choose a framework:",
    .choices = &.{ "express", "fastify", "koa" },
});

// Multi-select
const features = try zinput.multiSelect(writer, reader, .{
    .message = "Select features:",
    .choices = &.{ "typescript", "eslint", "prettier", "tests" },
    .defaults = &.{ true, true, false, true },
});

// Password (masked input)
const password = try zinput.password(writer, reader, .{
    .message = "Enter password:",
    .mask = '*',
});
```

### Key design decisions

- **Takes writer/reader explicitly** — no global state, testable
- **Builds on ztheme** — styled prompts, capability-aware colors
- **TTY detection** — falls back to non-interactive defaults when not a TTY
- **Works with zcli context** — convenience wrappers that pull writer/reader from context

### Implementation notes

- New package: `packages/zinput/`
- Uses raw terminal mode (termios) for character-by-character input
- The `packages/interactive/` PTY code has terminal mode handling we can reference
- Arrow key navigation for select/multiSelect
- ANSI cursor manipulation for in-place rendering

### Files to create

- `packages/zinput/src/zinput.zig` — Main entry point
- `packages/zinput/src/text.zig` — Text prompt
- `packages/zinput/src/confirm.zig` — Yes/no prompt
- `packages/zinput/src/select.zig` — Single selection
- `packages/zinput/src/multi_select.zig` — Multi selection
- `packages/zinput/src/password.zig` — Masked input
- `packages/zinput/build.zig`, `build.zig.zon`

---

## Implementation Order

1. **Command Testing Harness** — smallest scope, immediate value for development
2. **Doc Generation** — builds on existing metadata, high visibility
3. **Config File Plugin** — builds on existing env var support
4. **Interactive Prompts** — largest scope, standalone package

## Non-goals for Phase 3

- GUI/TUI frameworks
- HTTP client utilities
- Database integrations
- Cross-compilation helpers
