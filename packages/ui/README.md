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

pub const panic = ui.panic; // in your root source file — see below

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

Every `App` — hybrid included — hides the cursor and, for a prompt, rides the
caller's raw mode. A panic runs no `defer`, so `app.deinit()` never fires and
the terminal is left stranded. Install the restore panic hook in your root
source file: `pub const panic = zcli.ui.panic;` (standalone: `= ui.panic;`).
It is **required** and compile-time-enforced at `App.init` — a forgotten hook
is a build error, not a wedged terminal. zcli's `prompts` and `progress`
re-export it (`Prompts.panic` / `Progress.panic`) for standalone use.

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

## Full-screen mode

The hybrid shares the screen; a full-screen TUI takes it over on the same
engine ([ADR-0015](../../docs/adr/0015-full-screen-tui-mode.md)). `context.uiFullScreen()`
(or `ui.App.initFullScreen`) enters the alternate screen and raw mode, grants
the frame the whole viewport, and drives a `view → nextEvent → update` loop
(`app.run` owns it for you, with an optional tick clock). `emit` is an error —
there's no scrollback to flow into. The panic hook (required for every `App`,
above) matters most here: a wedged alt-screen needs `reset`, not merely a lost
cursor. On exit the shell comes back exactly as it was; the final frame does
not persist.

Interactive widgets for full-screen forms and menus live in `ui.widgets`
alongside the progress ones ([ADR-0018](../../docs/adr/0018-focusable-widgets.md)):
`TextInput` (optional password `mask`), `TextArea` (a multi-line field over a
caller-owned buffer: soft wrap at the granted width, visual-row ↑/↓ and Home/End,
Enter inserts a newline, PgUp/PgDn paging, vertical scroll, and the real hardware
cursor via `cursor_out` — [ADR-0021](../../docs/adr/0021-widget-catalog-completion.md)),
`Checkbox`, `Select` (scrolling window, truncation, optional multi-line `wrap`,
optional `scrollbar`), `Table` (a read-only data grid with `Dim`-sized columns,
selection, a scroll window, PgUp/PgDn paging, truncation, and an optional
`scrollbar`
— [ADR-0021](../../docs/adr/0021-widget-catalog-completion.md)), `Tabs` (a stateless
tab-bar row with ←/→ and number-key selection over a caller-owned active index —
[ADR-0021](../../docs/adr/0021-widget-catalog-completion.md)), and `Button`.
Each is a plain struct you embed in your state with a `view(a, opts) !Node` +
`handle(key) bool` contract; focus is caller-owned (an enum), and an unconsumed key is form-level
navigation. For routing, `focusNext`/`focusPrev` wrap over a hand-written focus
enum, or `FocusRing(State)` derives the whole ring from `State`'s widget fields
(any field whose type has a `handle` method) — a reified `Focus` enum,
`next`/`prev`, and a `dispatch(state, focus, key, extras)` that routes to the
focused widget (`extras` supplies the multi-arg widgets' extra args; it must
cover every multi-arg widget since dispatch compiles all arms). It's sugar over
the switch — no framework loop, fully bypassable
([ADR-0021](../../docs/adr/0021-widget-catalog-completion.md); `examples/form.zig`).
Overlays (`stack` + `center`, [ADR-0016](../../docs/adr/0016-overlays-z-layers.md)),
scrolling panes (`viewport`, [ADR-0017](../../docs/adr/0017-scrollable-viewports.md);
opt-in proportional `scrollbar`, [ADR-0021](../../docs/adr/0021-widget-catalog-completion.md)),
and anchored popups (`probe` + `positioned` / `anchored`, [ADR-0019](../../docs/adr/0019-position-feedback.md))
are all composition on the same tree. The `scrollbar` opt is off by default
everywhere — it reserves a 1-cell gutter (dim track, brighter thumb proportional
to the visible fraction), so a caller opts in only where a stable indicator earns
the column; on `Select`/`Table` it replaces the overflow arrows in that gutter.

## Try it

```sh
zig build run-demo        # hybrid: deploy-style task frame; needs a real terminal
zig build run-hybrid      # hybrid: the Claude-Code shape — streaming prose + live multi-bar
zig build run-fullscreen  # full-screen: a top-style dashboard — Table, tick, overlay, mouse
zig build run-form        # full-screen: focusable form — text fields, select, checkbox, button
zig build run-textarea    # full-screen: multi-line editor — soft wrap, scroll, real caret
zig build run-popup       # full-screen: anchored dropdowns that flip above / clamp on screen
zig build test            # pure layout tests + vterm golden-frame tests
```

Resize the terminal while a hybrid example runs: the live frame re-lays-out and
the visible static tail rewraps with it.
