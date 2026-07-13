# theme examples

Four self-contained programs that demonstrate the design system end to end.
Each is a `main` that renders styled text to stdout (see `common.zig` for the
buffered-writer wiring).

Run one:

```sh
zig build run-showcase        # or: degradation, custom-theme, detect
```

Build all of them at once:

```sh
zig build examples            # binaries land in zig-out/bin/theme-<name>
```

| Example        | Demonstrates                                                        |
| -------------- | ------------------------------------------------------------------- |
| `showcase`     | Every semantic role + the full fluent styling API on one screen     |
| `degradation`  | The **same** output at true_color / 256 / 16 / no_color             |
| `custom_theme` | A branded palette applied to unchanged role-tagged code + tokens    |
| `detect`       | Real terminal-capability detection from the environment and TTY     |

## What each shows

- **`showcase`** — pins the context to `true_color` and prints the default
  palette (`.success()`, `.command()`, `.path()`, …) followed by direct colors,
  RGB, hex, attributes, and role/explicit composition. The reference card.

- **`degradation`** — renders one palette four times, once per
  `TerminalCapability`. Watch `rgb(255,105,97)` snap from exact RGB to the
  nearest 256 index, to the nearest of the 16 ANSI colors, to plain text. This
  is the whole promise: style once, degrade automatically.

- **`custom_theme`** — defines a `Theme` with a branded palette and renders the
  *same* `styled(...).command()` / `.success()` calls through both the default
  and the brand context. Also shows component tokens (`prompts.cursor`,
  `progress.spinner`, `surface.border`) following the `accent` role for free.
  The file's header documents the `pub const zcli_theme` root-override idiom —
  how a real zcli app declares this once and every render path picks it up.

- **`detect`** — builds `Capabilities.init(environ, io)` from the live process
  environment and reports what it found. Try it four ways:

  ```sh
  zig build run-detect                  # detected from your terminal
  NO_COLOR=1 zig build run-detect       # forced to no_color
  COLORTERM=truecolor zig build run-detect
  zig build run-detect | cat            # not a TTY -> color disabled
  ```

All examples are non-interactive, so piping them works — and piping is itself a
demonstration: output degrades to plain text when stdout isn't a TTY (except
`showcase` and `degradation`, which pin an explicit capability so the escape
codes always show).
