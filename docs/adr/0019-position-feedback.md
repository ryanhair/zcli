# Position feedback: recovering where a node rendered, immediate-mode

Status: accepted

> Increment 1: the `ui.probe` primitive plus its first consumer, mouse
> click-to-focus in the form example. The hardware cursor and anchored popups —
> the other two features this unblocks — are follow-ups on the same primitive.
>
> **Increment 2 (landed): hardware cursor.** A focused `TextInput` reports its
> caret's absolute cell through a `cursor_out: ?*?Point` in its `ViewOpts` (the
> same caller-pointer shape as `probe`, since the caret sits *inside* the field
> at a scroll-dependent column only the widget's render knows) and draws no block
> there. The App gained `cursorAt(?Point)` — place the real terminal cursor at a
> screen cell or hide it — which reuses the hybrid `showCursorAt`/`unplace`
> machinery (already coordinate-general); `frameFullScreen` now `unplace()`s
> before painting so the placed cursor returns to the origin the diff addresses
> against. `App.run` gained an optional **post-frame hook** (`after_frame`, run
> just before blocking on input) — its home use is `app.cursorAt(state.caret)`,
> reading a `Point` the field wrote during render. The reporting channel stayed a
> `ViewOpts` pointer over a `RenderCtx` slot for the same reason increment 1 chose
> a wrapper over a `Node` field: keep `node.zig` free of a cursor concept.

The layout engine (ADR-0013) is immediate-mode: `view(state)` builds a fresh,
anonymous node tree every frame; `measure`+`render` lay it out and paint it; the
tree is discarded. Nothing persists to tell the caller *where a widget ended up
on screen*. Three deferred features all need exactly that:

- **mouse click-to-focus** — map a click at (x, y) to the widget under it,
- **hardware cursor** — place the real terminal cursor at a focused field's caret,
- **anchored popups** — pin a dropdown under the widget it belongs to.

Each needs the rect a given node occupied after layout — the one thing the
immediate-mode tree throws away.

## Decision: a `probe` wrapper that reports its child's rendered rect

`ui.probe(a, out: *Rect, child) !Node` wraps a node, lays it out and paints it
exactly as if the wrapper weren't there, and as a side effect writes the child's
absolute rendered rect into `out`:

```zig
try ui.probe(a, &state.rects[i], try widget.view(a, .{ ... }))
```

A `custom` leaf's `renderFn` already receives its **absolute** `Region.rect`
(surface coordinates, which in full-screen *are* screen coordinates — the surface
fills the viewport from the origin). So the wrapper is tiny: write `out.* =
region.rect`, then render the child into that same region. It copies the child's
sizing fields so the parent measures and places it identically — a rect report,
never a layout change.

Because `view` runs *inside* `frame`, before the next event is read, `out`
reflects the **current** frame — a click is hit-tested against the very layout it
is reacting to, not a frame behind.

### Why the wrapper over the alternatives

- **A `rect_out` field on every `Node`** — one line in `render()`, but adds a
  field to `Node` and threads it through every builder's opts. A large surface
  for a feature only a few nodes use.
- **An id → rect map collected during render (the Dear ImGui approach)** — scales
  to thousands of hit-tested items, but needs node identity and a retained map.
  Overkill for a handful of form widgets.
- **The wrapper** — **zero changes to `Node`, the builders, or the widgets.**
  Purely additive (one function), and it composes: wrap anything whose position
  you want. Its one limit is that probing *N* nodes wraps *N* times; if we ever
  hit-test a large grid, that's when the id-map earns its keep. For forms, wrap.

## Consequences

- **First consumer — click-to-focus.** The form example wraps each field in a
  `probe`, stores the rects, and on a left-click hit-tests the point against them
  to set focus. Pure caller logic on top of the primitive — no widget change. It
  needs the App's `mouse` mode on (the events were already parsed; ADR-0015).
- **`out` is written only when the child paints.** A child clipped to zero size
  never runs its `renderFn`, so `out` keeps its previous value — zero-init or
  reset it if "not visible this frame" must be distinguishable.
- **Full-screen is where this is meaningful.** In hybrid, the live region floats
  in scrollback, so the surface rect isn't a stable screen coordinate; the
  consumers (mouse, cursor, popups) are full-screen features anyway.
- **Hardware cursor landed (increment 2); anchored popups remain.** The cursor
  reuses this position feedback for a point *inside* a widget (the caret) plus
  App plumbing (`cursorAt` + the `run` post-frame hook + `frameFullScreen`'s
  pre-paint `unplace`). *Anchored popups* — the last consumer — probe the
  anchor's rect, then render a popup in a `stack` (ADR-0016) positioned there
  with len-spacers. A composition of what already exists; no core change.
- **No renderer or measure change.** `probe` is a `custom` leaf like `viewport`
  and the widgets — the position feedback is a side effect of the normal render
  pass, tested headlessly (the rect is deterministic) with the live click path
  PTY-validated.
