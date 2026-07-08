# terminal

Cross-platform terminal primitives for interactive Zig CLIs: raw mode, event-driven key reading with ANSI escape parsing, window size and resize detection, and grapheme-aware display-width measurement and wrapping. This is the foundation [`prompts`](../prompts/) and [`progress`](../progress/) are built on.

## Features

- **Raw mode**: `enableRawMode(handle)` returns a `RawMode` whose `disable()` restores the terminal exactly; `setEcho` toggles echo for password input
- **Key reading**: `readKey` assembles multibyte UTF-8 and ANSI escape sequences into a single `Key` union (`.char`, arrows, `.enter`, `.backspace`, `.ctrl`, …); `readKeyOpt` disambiguates a lone Escape from escape sequences with a 75 ms poll
- **Resize events**: `ResizeWatcher` hooks SIGWINCH on POSIX (console-size polling on Windows); `readEvent` multiplexes keys and resizes into one blocking call
- **Width & wrapping**: `displayWidth` handles CJK double-width, emoji (ZWJ sequences, flags, modifiers), combining marks, and skips ANSI sequences; `wrapToWidth` / `wrapForEach` / `wrapCount` wrap to a column budget (allocating, streaming, and counting variants)
- **Grapheme editing**: `trailingGraphemeLen` and `graphemeCount` make backspace/cursor logic correct for user-perceived characters
- **Portability**: libc-free on POSIX (`std.posix` directly — static musl builds work); on Windows, virtual-terminal mode makes the console speak the same ANSI dialect, so the escape parsing is fully shared
- **Helpers**: `symbols.*` Unicode/ASCII indicator pairs, `isTty` / `isStdinTty` / `isStdoutTty`, `unicodeSupported(environ)` — cursor and screen escapes live in the [`ui`](../ui/) engine, which owns all repainting

## Installation

terminal ships with the [zcli](../../README.md) framework (`zcli_dep.module("terminal")`), or standalone:

```zig
// build.zig.zon
.dependencies = .{
    .terminal = .{ .path = "path/to/zcli/packages/terminal" },
},
```

```zig
// build.zig
const terminal_dep = b.dependency("terminal", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("terminal", terminal_dep.module("terminal"));
```

## Quick start

An interactive read loop that survives resizes (this is how prompts's prompts are built — rendering goes through the `ui` engine, which owns the cursor):

```zig
const terminal = @import("terminal");

const stdin = std.Io.File.stdin().handle;
const raw = try terminal.enableRawMode(stdin);
var watcher = terminal.ResizeWatcher.init();
defer {
    watcher.deinit();
    raw.disable();
}

while (true) {
    switch (try terminal.readEvent(reader, stdin, &watcher)) {
        .resize => rerender(terminal.getWindowSize(stdin)),
        .key => |k| switch (k) {
            .up => moveUp(),
            .enter => return submit(),
            .char => |c| insert(c),
            else => {},
        },
    }
}
```

## Dependencies

- [`zg`](https://codeberg.org/atman/zg) — grapheme iteration and Unicode display-width data (used by the wrapping/width API)
