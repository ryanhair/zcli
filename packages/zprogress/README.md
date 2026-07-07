# zprogress

Progress indicators for Zig CLIs: animated spinners for indeterminate work and progress bars for known totals. Output adapts automatically — animations and cursor control on a TTY, plain printed lines when piped — and completion symbols degrade from Unicode to ASCII on limited terminals.

## Features

- **Spinners**: nine styles (`dots`, `dots2`, `dots3`, `line`, `arrow`, `bounce`, `clock`, `moon`, `simple`), each with a tuned frame interval
- **Progress bars**: percentage, current/total, ETA, elapsed time, and rate — all opt-in via `ProgressBarConfig`
- **TTY-aware**: non-TTY output (pipes, CI logs) gets static lines instead of control codes
- **Result symbols**: `succeed`/`fail`/`warn`/`info` finish states with themed colors and Unicode→ASCII fallback
- **Cursor hygiene**: the cursor is hidden while a spinner runs and restored on any finish path (configurable)

## Installation

zprogress ships with the [zcli](../../README.md) framework (`zcli_dep.module("zprogress")`), or standalone:

```zig
// build.zig.zon
.dependencies = .{
    .zprogress = .{ .path = "path/to/zcli/packages/zprogress" },
},
```

```zig
// build.zig
const zprogress_dep = b.dependency("zprogress", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zprogress", zprogress_dep.module("zprogress"));
```

## Quick start

```zig
const zprogress = @import("zprogress");

// Spinner — indeterminate work
var spinner = zprogress.spinner(io, .{ .style = .dots });
spinner.start("Connecting to server...");
spinner.setText("Uploading changes...");
spinner.succeed("Synced successfully"); // or .fail() / .warn() / .info() / .stop()

// Progress bar — known total
var bar = zprogress.progressBar(io, .{
    .total = items.len,
    .show_eta = true,
});
for (items, 0..) |item, i| {
    process(item);
    bar.update(i + 1, null);
}
bar.finish();
```

See [examples/tasks](../../examples/tasks/) (`sync`, `import` commands) for these running in a real CLI.

## Dependencies

- [`ztheme`](../ztheme/) — colors for the spinner and finish symbols
- [`terminal`](../terminal/) — TTY detection and Unicode/ASCII symbol fallback
