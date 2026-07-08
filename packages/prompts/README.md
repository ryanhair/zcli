# prompts

Interactive terminal prompts for Zig CLIs: eight prompt types with arrow-key navigation, live filtering, and grapheme-aware line editing — each degrading gracefully to plain line-based input when stdin is not a TTY (so scripts and pipes keep working).

## Features

- **Eight prompt types**: `text`, `password`, `number`, `confirm`, `select`, `multiSelect`, `search`, `editor`
- **Non-TTY fallback**: every prompt detects a non-TTY stdin and falls back to line input (select prompts print a numbered list)
- **Unicode-correct**: UTF-8 input assembly, wide characters, and grapheme-aware backspace via the `terminal` package
- **Wrap- and resize-safe**: list prompts wrap long options with hang indents and re-render cleanly on terminal resize (SIGWINCH)
- **Interruptible**: an `interrupt_keys` config aborts with `error.Interrupted` for caller-defined "go back"/"cancel" flows
- **Works with any writer/reader**: no zcli dependency; rendering is verified end-to-end against the in-repo `vterm` emulator

## Installation

prompts ships with the [zcli](../../README.md) framework (`zcli_dep.module("prompts")`), or standalone:

```zig
// build.zig.zon
.dependencies = .{
    .prompts = .{ .path = "path/to/zcli/packages/prompts" },
},
```

```zig
// build.zig
const prompts_dep = b.dependency("prompts", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("prompts", prompts_dep.module("prompts"));
```

## Quick start

```zig
const prompts = @import("prompts");

// Free-form text (returns an owned []u8 — caller frees; empty submit returns
// the default if set, otherwise an empty string)
const title = try prompts.text(writer, reader, allocator, .{
    .message = "Task title:",
});

// Pick one from a list (returns the chosen index)
const priority_idx = try prompts.select(writer, reader, .{
    .message = "Priority:",
    .choices = &.{ "low", "medium", "high", "critical" },
});

// Number with range validation (returns i64)
const points = try prompts.number(writer, reader, .{
    .message = "Story points:",
    .default = 1,
    .min = 0,
    .max = 100,
});

// Yes/no (returns bool)
const sure = try prompts.confirm(writer, reader, .{ .message = "Create it?" });
```

The other prompt types follow the same shape: `password` (masked input), `multiSelect` (space toggles, returns owned indices), `search` (type-to-filter a list), and `editor` (opens `$EDITOR` for multiline text).

## Theming

The list prompts (`select`, `multiSelect`, `search`) and `editor` style their
cursor, selected row, check marker, and hint text through the theme's
`prompts` component tokens. Pass a `ThemeContext` to follow an app theme and
the detected terminal capabilities (including `NO_COLOR`):

```zig
// In a zcli command — the context already carries the app theme:
const idx = try prompts.select(writer, reader, .{
    .message = "Pick:",
    .choices = &.{ "a", "b" },
    .theme = context.theme,
});
```

Standalone, the default (`prompts.default_style`) is the default theme at
ANSI-16 — the package's historical fixed colors. Tokens and their defaults
(`cursor`/`selected` → accent, `marker` → success, `hint` → muted) are defined
in [`theme`](../theme/)'s `PromptTheme`.

See [examples/tasks](../../examples/tasks/) for every prompt in a working CLI.

## Behavior notes

- Interactive mode needs a TTY on stdin; prompts check and fall back automatically — never gate your command on TTY yourself.
- `text` supports a live `Preview` callback rendered above the input line, repainted per keystroke.
- Prompts flush the writer before each blocking read, so buffered writers are safe to pass.

## Dependencies

- [`terminal`](../terminal/) — raw mode, key/resize events, display width, wrapping
- [`theme`](../theme/) — theming integration
