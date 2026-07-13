# progress

Progress indicators for Zig CLIs: animated spinners for indeterminate work and progress bars for known totals. Output adapts automatically — animations and cursor control on a TTY, plain printed lines when piped — and completion symbols degrade from Unicode to ASCII on limited terminals.

## Features

- **Spinners**: nine styles (`dots`, `dots2`, `dots3`, `line`, `arrow`, `bounce`, `clock`, `moon`, `simple`), each with a tuned frame interval
- **Progress bars**: percentage, current/total, ETA, elapsed time, and rate — all opt-in via `ProgressBarConfig`
- **Multi-bars**: stacked labeled bars for parallel work, thread-safe updates
- **TTY-aware**: piped output (pipes, CI logs) degrades to plain lines — spinners print one line per message, bars a single finish line
- **Result symbols**: `succeed`/`fail`/`warn`/`info` finish states with themed colors and Unicode→ASCII fallback
- **Engine-rendered**: frames run on the [`ui`](../ui/) layout engine — diffed repaints, resize re-layout, and cursor hygiene are the engine's job; finish results are emitted as static lines that flow into scrollback

## Installation

progress ships with the [zcli](../../README.md) framework (`zcli_dep.module("progress")`), or standalone:

```zig
// build.zig.zon
.dependencies = .{
    .progress = .{ .path = "path/to/zcli/packages/progress" },
},
```

```zig
// build.zig
const progress_dep = b.dependency("progress", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("progress", progress_dep.module("progress"));
```

## Quick start

The import IS the type: build one `Progress` bundling `writer`, `io`,
`allocator`, and `theme`, and the three constructors are methods on it.

```zig
const Progress = @import("progress");

const p: Progress = .{ .writer = writer, .io = io, .allocator = allocator };

// Spinner — indeterminate work
var spinner = try p.spinner(.{ .style = .dots });
spinner.start("Connecting to server...");
spinner.setMessage("Uploading changes...");
spinner.succeed("Synced successfully"); // or .fail() / .warn() / .info() / .stop()

// Progress bar — known total
var bar = try p.progressBar(.{
    .total = items.len,
    .show_eta = true,
});
for (items, 0..) |item, i| {
    process(item);
    bar.update(i + 1, null);
}
bar.finish(); // the final frame persists on screen

// Multi-bar — parallel work (updates may come from worker threads)
var mb = try p.multiBar(.{});
defer mb.deinit();
const api = try mb.add("api.tar.gz", total_bytes);
mb.set(api, downloaded);
mb.finish();
```

## Examples

Runnable, focused examples live in [`examples/`](examples/) — one per indicator
plus a multi-step flow. Build them all with `zig build examples`, or run one:

```sh
zig build run-spinner       # or: spinner_styles, bar, multi_bar, tasks
```

| Example                                        | Demonstrates                                                        |
| ---------------------------------------------- | ------------------------------------------------------------------ |
| [`spinner`](examples/spinner.zig)              | A self-animating spinner through phases → `succeed`                |
| [`spinner_styles`](examples/spinner_styles.zig)| All nine styles + every finish state (`succeed`/`fail`/`warn`/`info`/`persist`/`stop`) |
| [`bar`](examples/bar.zig)                      | A caller-driven bar with percentage, ETA, elapsed, and rate stats  |
| [`multi_bar`](examples/multi_bar.zig)          | Stacked labelled bars updated concurrently from worker threads     |
| [`tasks`](examples/tasks.zig)                  | A realistic multi-step command mixing spinners and a bar           |

They animate on a TTY and degrade to plain lines when piped, so
`zig build run-spinner | cat` still works. See
[`examples/README.md`](examples/README.md) for details.

See also [examples/tasks](../../examples/tasks/) (`sync`, `import` commands) for
these running inside a real zcli CLI.

## Theming

Spinners animate in the theme's `progress.spinner` token (accent by default),
result symbols render through the palette's `success`/`err`/`warning`/`info`
roles, and bars color their fill/track via `bar_fill`/`bar_empty` on TTYs
(piped output stays plain). The bundle carries a `ThemeContext`, so every
indicator follows an app theme and the detected capabilities (including
`NO_COLOR` and true color):

```zig
// In a zcli command — context.progress() pre-wires the app theme, io,
// allocator, and stdout:
var spinner = try context.progress().spinner(.{});
```

Standalone, the bundle's `theme` field defaults to `ThemeContext.fallback` —
the default theme at ANSI-16. Token defaults are defined in
[`theme`](../theme/)'s `ProgressTheme`.

## Dependencies

- [`ui`](../ui/) — the layout engine that renders every frame
- [`theme`](../theme/) — colors for the spinner and finish symbols
- [`terminal`](../terminal/) — TTY detection and Unicode/ASCII symbol fallback
