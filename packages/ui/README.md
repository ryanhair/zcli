# ui

The terminal-native layout engine behind zcli's CLI/TUI hybrid ([ADR-0013](../../docs/adr/0013-terminal-native-layout-engine.md)).

> **Status: pre-stabilization.** Built through step 2 of the ADR's build order
> (cell surface + diff renderer, node tree + layout). The `App` loop
> (static/live frame model, resize) is next; until it lands this package is
> not exported on the zcli umbrella and its API may change freely.

## The model

Output splits into a **static** stream that flows into scrollback and a
**live region** at the bottom edge that repaints in place. The live region is
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
```

Builders copy child slices into the arena, so component functions compose
without dangling-temporary hazards. Styles are `theme.Style` values on the
nodes; the diff renderer emits them capability-aware (`no_color` through
true color). Text measurement is `terminal.wrap` — the same grapheme-aware
wrapper paints and measures, so layout and rendering always agree.

Note: the default `.wrap` mode word-wraps and drops break spaces. Labels with
significant whitespace (padded numbers, aligned columns) want `.clip` or
`.truncate` via `ui.textOpts`.

## Try it

```sh
zig build run-demo   # animated frame; needs a real terminal
zig build test       # pure layout tests + vterm golden-frame tests
```

The demo (`examples/demo.zig`) also documents what the coming `App` loop will
own: reserving the live region's rows, cursor parking/restore, and surface
double-buffering.
