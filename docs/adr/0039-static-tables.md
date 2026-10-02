# Static tables for command results

Status: accepted

Commands that print a list and exit need aligned output without taking over the
terminal. The existing `ui.Table` is a scrolling, interactive widget. Hand
padding in `examples/tasks/list.zig` duplicated width logic and mishandled wide
text.

## Decision

`ui.StaticTable` is a one-shot value bundle in the `ui` package. A command uses
`context.table().print(columns, rows)`; standalone callers supply a writer,
allocator, theme, and optional terminal width. It owns no terminal session and
requires no `deinit`. Its cells are caller-owned.

On a terminal, the printer fits columns into the available width. Each column
declares alignment, a preferred minimum, an optional maximum, overflow
(`truncate` or `wrap`), and shrink priority. The column with greater priority
shrinks first. If all preferred minimums exceed the terminal, they shrink to
one cell each. A terminal too narrow for those cells and separators returns
`error.TerminalTooNarrow`; invalid minimum/maximum declarations return
`error.InvalidColumnWidth`.

For pipes and files, width is unbounded: maximums and overflow rules do not
remove content. Explicit line breaks in cells remain separate physical lines
in both modes. Terminal wrap may add further lines. Input ANSI escapes are
stripped; remaining ASCII control bytes (other than line breaks) are replaced
with spaces, so cell content cannot control the terminal or color redirected
output. The printer applies the theme's muted role to terminal headers only;
`NO_COLOR` and captured stdout suppress it. Width calculations use the
terminal package's grapheme-aware primitives.

`context.table()` selects the actual stdout destination. Captured output is
unbounded even when the test process itself has a TTY. A standalone caller
sets `width` explicitly, which also makes golden tests deterministic.

## Consequences

The tasks list command now uses this printer. The interactive widget remains
responsible for selection, scrolling, and cursor behavior. Static commands
receive readable terminal tables and complete text when piped.
