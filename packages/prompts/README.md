# prompts

Interactive terminal prompts for Zig CLIs: seven primary prompt types with
arrow-key navigation, optional live filtering, and grapheme-aware line editing
— each degrading gracefully to plain line-based input when stdin or stdout is
not a terminal (so scripts and pipes keep working).

## Features

- **Immediate editor operation**: `edit` opens an editor independently of stdout redirection and returns an owned edited document or structured failure with a recovery path
- **Seven primary prompt types**: `text`, `password`, `number`, `confirm`, `select`, `multiSelect`, `editor`
- **Non-TTY fallback**: redirect either stdin or stdout and every prompt falls back to stream input (line input for most prompts; editor reads to EOF; select prompts print a numbered list)
- **Interactive-only guard**: `requireInteractive()` fails with `error.NotInteractive` before the first question, for commands where the fallback makes no sense
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
// The import IS the type: one instance carries the environment,
// and every prompt is a method on it.
const Prompts = @import("prompts");

const p: Prompts = .{
    .writer = writer,
    .reader = reader,
    .allocator = allocator,
};

// Free-form text (returns an owned []u8 — caller frees; empty submit returns
// the default if set, otherwise an empty string)
const title = try p.text(.{
    .message = "Task title:",
});

// Pick one from a list (returns the chosen index)
const priority_idx = try p.select(.{
    .message = "Priority:",
    .choices = &.{ "low", "medium", "high", "critical" },
});

// Searchable selection (still returns the original choice index)
const framework_idx = try p.select(.{
    .message = "Framework:",
    .choices = &.{ "express", "fastify", "koa" },
    .search = true,
});

// Number with range validation (returns i64)
const points = try p.number(.{
    .message = "Story points:",
    .default = 1,
    .min = 0,
    .max = 100,
});

// Yes/no (returns bool)
const sure = try p.confirm(.{ .message = "Create it?" });
```

The other prompt types follow the same shape: `password` (masked input),
`multiSelect` (Space toggles and returns owned indices), and `editor` (opens
`$EDITOR` for multiline text). Plain `select` accepts Space like Enter.

## Editing a document

Use `edit` when editing is the command itself. It opens immediately and attaches
to the controlling terminal, even when stdout is redirected. It does not use the
prompt's line-input fallback or `interactive` override.

```zig
var result = try p.edit(.{
    .io = io,
    .environ = environ,
    .default = initial_document,
    .extension = ".md",
});
defer result.deinit(allocator); // context.allocator for context.prompts()
switch (result) {
    .edited => |document| try saveDocument(document),
    .failed => |failure| {
        if (failure.recovery_path) |path|
            try writer.print("Recover your document from {s}\n", .{path});
        return error.EditorFailed;
    },
}
```

An empty or unchanged saved document is successful. Bytes and final newlines are
preserved. Expected failures (invalid command, unavailable terminal, scratch-file
I/O, launch, wait, nonzero or abnormal termination, and read-back) are returned in
`.failed`; allocation failures remain Zig errors. Changed or unreadable scratch
files survive by default. Deinitializing the result frees its data and recovery
path, but does not delete a preserved file. `.recovery = .discard` opts out.

Prefer `.argv = &.{ "code", "--wait" }` for programmatic configuration. The
scratch filename is appended as one argument. Otherwise `editor_cmd`, `$VISUAL`,
then `$EDITOR` supply a command string, with `vi` (POSIX) or `notepad` (Windows)
as the fallback. Command strings support shell-word quoting, not expansion or
pipelines; invoke a shell explicitly when needed. In particular, use `.argv`
for Windows paths containing backslashes. The document limit is 128 MiB by default
(`.max_bytes`); `.attachment = .inherit` explicitly permits noninteractive tools.

The invitation-style `editor` prompt still waits for Enter, or skips that gate
with `.immediate = true` when interactive. Without a TTY it reads stdin to EOF;
empty input returns `error.EndOfStream`. Editor failure now returns
`error.EditorFailed`, `error.EditorLaunchFailed`, or `error.EditorReadFailed`
instead of silently returning the original document. The prompt reports any
recovery path before returning the error. Use `edit` for structured failure data.
See [ADR-0038](../../docs/adr/0038-editor-operation.md).

## Searchable lists

Set `.search = true` on either `select` or `multiSelect` to filter choices with
a case-insensitive substring query. Printable characters other than ASCII Space
filter, Backspace edits the query, Up/Down navigate, and the Space key selects
or toggles the highlighted choice; Enter selects (single choice) or commits
(multiple choices). ASCII Space is not query text. A searchable multi-select
retains selections that become hidden by filtering.

## Fallback, or interactive-only

The line-based fallback is the default and covers most commands: the same code
asks a question at a terminal and reads a line from a pipe, so scripts and CI
keep working without a `--non-interactive` flag.

Some commands have no meaningful answer off a terminal — a wizard whose whole
job is the conversation, a prompt whose fallback would silently pick something
destructive. Those guard once, before the first question:

```zig
const p = ...; // context.prompts() in a zcli command

// One call, up front: fails before anything is asked.
try p.requireInteractive(); // error.NotInteractive when piped

const name = try p.text(.{ .message = "Project name:" });
const ok = try p.confirm(.{ .message = "Create it?" });
```

`requireInteractive` returns `error.NotInteractive` unless **both** stdin and
stdout are terminals: stdin so keystrokes can be read in raw mode, stdout so the
rendered frame lands on the screen rather than in a redirected file. That is the
same check the prompts themselves make, so the guard's answer is exactly what
the next prompt would have done. `p.isInteractive()` asks it without erroring,
for a command that wants to branch (see `zcli add command`, which scaffolds a
plain skeleton when piped) instead of failing.

Setting `interactive` on the instance overrides the detection for that instance
— every prompt made through it and the guard alike. Note what `false` does and
doesn't do: it **forces line mode**, so the prompts still print their question
and still read stdin, which at a terminal means waiting for a typed line and on
a closed stream means `error.EndOfStream`. It is not a `--no-input` switch. A
flag that means "ask me nothing" has to skip the prompt sequence itself — take
the defaults, or require the values as options — and the guard is what tells
you the sequence can't run.

## Theming

The list prompts (`select`, `multiSelect`) and `editor` style their
cursor, selected row, check marker, and hint text through the theme's
`prompts` component tokens. Set `theme` on the `Prompts` instance to follow an
app theme and the detected terminal capabilities (including `NO_COLOR`) — every
prompt made through that instance is themed:

```zig
// In a zcli command, context.prompts() returns an instance already carrying
// the app theme:
const p = context.prompts();
const idx = try p.select(.{
    .message = "Pick:",
    .choices = &.{ "a", "b" },
});
```

Standalone, build a style context from the re-exported theming types
(`Prompts.Theme`, `Prompts.ThemeContext`, `Prompts.Capabilities`) and set
`.theme` on the instance.

Left unset, the default (`Prompts.default_style`) is the default theme at
ANSI-16 — the package's historical fixed colors. Tokens and their defaults
(`cursor`/`selected` → accent, `marker` → success, `hint` → muted) are defined
in [`theme`](../theme/)'s `PromptTheme`.

See [examples/tasks](../../examples/tasks/) for every prompt in a working CLI.

## Behavior notes

- Interactive mode needs a TTY on both stdin and stdout; prompts check and fall back automatically — don't hand-roll a TTY check, use `requireInteractive()` (fail) or `isInteractive()` (branch).
- `text` supports a live `Preview` callback: it returns one line of text for the current input (allocated from the prompt's frame arena), rendered above the input line in the theme's hint style and repainted per keystroke.
- Prompts flush the writer before each blocking read, so buffered writers are safe to pass.

## Dependencies

- [`terminal`](../terminal/) — raw mode, key/resize events, display width, wrapping
- [`theme`](../theme/) — theming integration
