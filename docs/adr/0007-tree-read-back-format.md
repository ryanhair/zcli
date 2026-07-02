# `tree --show-options` is the enriched read-back, with a unified arg/option grammar

Status: accepted

The AI's "observe" step (read-back) is served by enriching the existing `tree --show-options`, not by adding a separate format or `--json`. The default `tree` stays compact and pretty for humans; `--show-options` becomes the complete, machine-legible read-back (ANSI-free when non-TTY via the existing ztheme `no_color` path). The guiding principle is **read/write symmetry**: the read-back surfaces exactly the spec fields the AI writes via `add option`/`add arg`, so it can reconcile current shape against intent and round-trip.

To achieve that, args and options share **one notation** where every glyph maps to one spec field:

- `<…>` required · `[…]` optional
- `:type` element type · `=x` default · `…` (`...`) multiple/variadic · `/-x` short flag (options only)

Example:
```
create  aliases=add  [Create a user]
  args:    <name:[]const u8>  [count:u32=1]  [files:[]const u8...]
  options: [--loud/-l]  <--token:[]const u8>  [--repeat/-r:u32]  [--limit:u32=10]  [--tags:[]const u8...]
```

This extends the grammar `tree` already uses for args (`<>`/`[]`) to options, adding the short/default/multiple markers that were missing.

## Scope boundaries

- **Command-level `aliases` and `hidden` are included** — the AI must see the full authored truth.
- **Per-field descriptions are excluded.** `tree` is the *map* (shape); the `-d` prose lives in the command file, which the AI reads when editing that command. This is the one place read/write symmetry is intentionally partial.
- **Scope is authored command files only**, not plugin-provided commands (help/version/completions). The AI reconciles its own work; framework-provided commands are not its to manage.

## Considered Options

- **Separate AI format / `--json`** — rejected: a second dialect and token-heavy; text mirrors the file-layout mental model better (see the earlier read-back decision).
- **Enrich `--show-options` with a unified grammar (chosen)** — one detailed mode, no new surface, read/write symmetric.

## Consequences

- The gaps to close in the current renderer: short flags, defaults, nullable-vs-required for options, `multiple`/variadic markers, aliases, hidden.
- Existing arg notation (`<>`/`[]` + `:type`) is retained and extended, not replaced.
