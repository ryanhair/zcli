# progress examples

One runnable example per indicator, plus a multi-step flow that combines them.
Each is a self-contained `main` that wires a buffered stdout writer over the
process `std.Io` (see `common.zig`) and drives a single feature of the package.

Run one (they animate, so use a real terminal):

```sh
zig build run-spinner       # or: spinner_styles, bar, multi_bar, tasks
```

Build all of them at once:

```sh
zig build examples          # binaries land in zig-out/bin/progress-<name>
```

| Example           | Demonstrates                                                                 |
| ----------------- | --------------------------------------------------------------------------- |
| `spinner`         | A self-animating spinner through phases → `succeed`                         |
| `spinner_styles`  | All nine `SpinnerStyle`s + every finish state (`succeed`/`fail`/`warn`/`info`/`persist`/`stop`) |
| `bar`             | A caller-driven progress bar with percentage, ETA, elapsed, and rate stats  |
| `multi_bar`       | Stacked labelled bars updated concurrently from worker threads              |
| `tasks`           | A realistic multi-step command mixing spinners and a bar                    |

## TTY vs piped output

Every indicator is TTY-aware. On a terminal you get animation and in-place
repaints; when stdout is a pipe the package degrades gracefully:

- **spinners** print one plain `- <message>` line per message, then a result line;
- **progress bars** stay silent until a single `<message> N/N (100%)` finish line;
- **multi-bars** are silent (log your own lines when not a TTY);
- **animations never spawn** off a TTY.

So the examples still run without crashing when piped — try it:

```sh
zig build run-spinner | cat
```

Zig 0.16 note: the stdout writer is buffered and finishing an indicator does not
flush the process writer, so each example `flush()`es before returning.
