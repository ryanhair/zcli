# zinput

Interactive terminal prompts for Zig CLIs: eight prompt types with arrow-key navigation, live filtering, and grapheme-aware line editing — each degrading gracefully to plain line-based input when stdin is not a TTY (so scripts and pipes keep working).

## Features

- **Eight prompt types**: `text`, `password`, `number`, `confirm`, `select`, `multiSelect`, `search`, `editor`
- **Non-TTY fallback**: every prompt detects a non-TTY stdin and falls back to line input (select prompts print a numbered list)
- **Unicode-correct**: UTF-8 input assembly, wide characters, and grapheme-aware backspace via the `terminal` package
- **Wrap- and resize-safe**: list prompts wrap long options with hang indents and re-render cleanly on terminal resize (SIGWINCH)
- **Interruptible**: an `interrupt_keys` config aborts with `error.Interrupted` for caller-defined "go back"/"cancel" flows
- **Works with any writer/reader**: no zcli dependency; rendering is verified end-to-end against the in-repo `vterm` emulator

## Installation

zinput ships with the [zcli](../../README.md) framework (`zcli_dep.module("zinput")`), or standalone:

```zig
// build.zig.zon
.dependencies = .{
    .zinput = .{ .path = "path/to/zcli/packages/zinput" },
},
```

```zig
// build.zig
const zinput_dep = b.dependency("zinput", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zinput", zinput_dep.module("zinput"));
```

## Quick start

```zig
const zinput = @import("zinput");

// Free-form text (returns owned ?[]const u8; null when the user submits nothing)
const title = try zinput.text(writer, reader, allocator, .{
    .message = "Task title:",
});

// Pick one from a list (returns the chosen index)
const priority_idx = try zinput.select(writer, reader, .{
    .message = "Priority:",
    .choices = &.{ "low", "medium", "high", "critical" },
});

// Number with range validation (returns i64)
const points = try zinput.number(writer, reader, .{
    .message = "Story points:",
    .default = 1,
    .min = 0,
    .max = 100,
});

// Yes/no (returns bool)
const sure = try zinput.confirm(writer, reader, .{ .message = "Create it?" });
```

The other prompt types follow the same shape: `password` (masked input), `multiSelect` (space toggles, returns owned indices), `search` (type-to-filter a list), and `editor` (opens `$EDITOR` for multiline text).

See [examples/showcase](../../examples/showcase/) for every prompt in a working CLI.

## Behavior notes

- Interactive mode needs a TTY on stdin; prompts check and fall back automatically — never gate your command on TTY yourself.
- `text` supports a live `Preview` callback rendered above the input line, repainted per keystroke.
- Prompts flush the writer before each blocking read, so buffered writers are safe to pass.

## Dependencies

- [`terminal`](../terminal/) — raw mode, key/resize events, display width, wrapping
- [`ztheme`](../ztheme/) — theming integration
