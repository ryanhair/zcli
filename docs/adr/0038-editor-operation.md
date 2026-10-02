# Immediate editing separate from the invitation prompt

Status: accepted (implemented)

## Context

An explicit edit command should open the editor immediately. A questionnaire can
still ask the user to press Enter first. Redirected stdout commonly carries an ID
or JSON document and must not turn an editing operation into stdin consumption or
receive editor UI. Unsuccessful editors must not silently restore the initial
text, and successful saves must preserve document bytes.

## Decision

`Prompts.edit(config)` opens immediately and returns `EditResult`: owned edited
content, or `EditorFailure` describing command parsing, terminal attachment,
scratch creation/write, launch/wait/termination, or read-back failure. The result
has `deinit(allocator)`. A failure can include an underlying error, child
termination, and an owned recovery path. Deinitialization releases result memory;
it does not delete a preserved recovery file.

`Prompts.editor` retains its Enter invitation and noninteractive stdin fallback.
Its `.immediate = true` bypasses the Enter gate only at an interactive
prompt; the noninteractive stdin fallback is unchanged. The convenience prompt returns an error on editor failure and displays a
recovery path when present. Call `edit` for structured recovery decisions.

Programmatic callers supply argv. Otherwise resolve an explicit `editor_cmd`,
then nonempty VISUAL, then nonempty EDITOR, then vi on POSIX or notepad on Windows.
Command strings use shell-word quoting and escaping without variable, glob,
tilde, pipeline, or command expansion. An explicitly chosen shell, such as
`sh -c 'echo edited > "$1"' --`, works. The scratch filename is appended as one
argument. Executable lookup uses the supplied environment's PATH, and the child
receives that environment. Windows batch scripts are refused; select an
executable explicitly.

The default attachment opens /dev/tty on POSIX and CONIN$/CONOUT$ on Windows.
Editor streams use those handles independently of process stdout. An explicit
inherit attachment supports noninteractive editor tools and deterministic tests;
it does not assert terminal availability.

Scratch files use random names, exclusive creation and private permissions. A
successful read returns exact bytes, including final newlines and empty content,
and removes the file. On failure, changed or unreadable content is preserved by
default; unchanged initial content is removed. Read-back failure preserves the
file because a successful save may have changed it. Callers can explicitly select
`recovery = .discard`. Edited input is bounded by `max_bytes` (128 MiB default),
and a limit failure preserves saved work.

## Consequences

The command-string argument handling, unsuccessful exit behavior, and removal of
newline normalization are intentional behavior changes. Noninteractive prompt
input remains unchanged. Allocation failures during command setup remain errors;
a read-back allocation failure is structured failure data so the recovery path
is retained.
