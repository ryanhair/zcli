# ui

The terminal-native layout engine behind zcli's CLI/TUI hybrid ([ADR-0013](../../docs/adr/0013-terminal-native-layout-engine.md)).

> **Status: shipped.** ADR-0013 is accepted and both interactive packages
> (`progress`, `prompts`) render on this engine. Exposed on the zcli umbrella
> as `zcli.ui`; in a command, `context.ui()` returns a pre-wired `App`.

## The model

Output splits into a **static** stream that flows into scrollback and a
**live region** that repaints in place just above it — a full layout area,
from a single line up to the whole viewport, positioned above committed
scrollback rather than a fixed bottom strip. Like Ink's static/dynamic split,
it shares the terminal instead of taking it over (no alternate screen buffer),
so your scrollback survives. The live region is
immediate-mode: a component is any function returning a `Node`; the tree is
rebuilt into a frame arena every frame, measured (constraints down, sizes
up), painted onto a cell `Surface`, and diffed — only changed cells reach the
terminal.

Four nodes: `box` (the only container), `text`, `spacer`, and `custom` (the
escape hatch for cell-level drawing). Three sizing words: `fit`, `len(n)`,
`fill(weight)`. Right-alignment is a spacer; percentages are fill weights.

```zig
fn statusLine(a: std.mem.Allocator, s: *const State) !ui.Node {
    return ui.row(a, .{ .gap = 1 }, &.{
        ui.text(.{ .bold = true }, spinnerGlyph(s.tick)), // animation = your state
        ui.text(.{}, s.message),
        ui.spacer(),
        ui.text(.{ .dim = true }, s.elapsed),
    });
}

var app = try ui.App.init(gpa, writer, .{});
defer app.deinit(); // cursor restored, final frame left in scrollback

try app.emit("✓ built {s}", .{name});               // static → scrollback
try app.frame(try statusLine(app.arena(), &state)); // live → diffed repaint
```

`App` owns the frame arena (`app.arena()`, reset when `frame()` returns),
the live region's rows, the cursor (hidden while a region is up, parked at
the region's top-left between calls), and the double-buffered surfaces.
`emit` is line-oriented and the only way to write while a region is up. The
live region re-measures against the terminal on every frame, so it re-lays
out on resize; its height clamps to the viewport and clips from the bottom.

Builders copy child slices into the arena, so component functions compose
without dangling-temporary hazards. Styles are `theme.Style` values on the
nodes; the diff renderer emits them capability-aware (`no_color` through
true color). Text measurement is `terminal.wrap` — the same grapheme-aware
wrapper paints and measures, so layout and rendering always agree.

Note: the default `.wrap` mode word-wraps and drops break spaces. Labels with
significant whitespace (padded numbers, aligned columns) want `.clip` or
`.truncate` via `ui.textOpts`.

## Widgets

`ui.widgets` is the progress vocabulary as component functions — a spinner
is a `text` node, a bar is one `custom` leaf, a multi-bar is a column of
rows. No widget owns a repaint loop or state: animation is your tick,
progress is your fraction, the frame diff does the rest. Styling flows
through the theme's `ProgressTheme` tokens (the same ones the progress
package consumes), so a future migration keeps its look.

```zig
try ui.row(a, .{ .gap = 1 }, &.{
    ui.widgets.spinner(.{}, state.tick),
    try ui.widgets.multiBar(a, .{}, &.{
        .{ .label = "api", .fraction = 0.6 },
        .{ .label = "assets", .fraction = 0.9 },
    }),
});
```

## Try it

```sh
zig build run-demo     # deploy-style task frame; needs a real terminal
zig build run-hybrid   # the Claude-Code shape: streaming prose + live multi-bar
zig build test         # pure layout tests + vterm golden-frame tests
```

Resize the terminal while either runs: the live frame re-lays-out and the
visible static tail rewraps with it.
