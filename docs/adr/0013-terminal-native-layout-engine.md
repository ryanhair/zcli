# Terminal-native layout engine: an immediate-mode UI core for the CLI/TUI hybrid

Status: accepted

The line between CLI and TUI has blurred. The tools defining the category (Claude Code
and the agent CLIs, most built on ink.js) feel like CLIs — output flows into scrollback
over time — but carry a live, animated frame at the bottom edge. zcli's interactive
packages already live in that space, but each widget owns its own ad-hoc repaint loop:
`progress` and `prompts` both hand-roll `\r\x1b[K` line rewrites, cursor hide/show, and
flush discipline. That means N independent paint paths, a recurring class of
coordination bugs (the flush-before-read family), and no way to *compose* — a spinner,
a multi-bar, and a status line cannot share one frame without manual cursor math.

Ink is the proof of the target authoring model: its user-facing vocabulary is
essentially two primitives (`Box`, `Text`) plus sugar (`Spacer`, `Static`), and all
perceived power is composition. But neither of Ink's engine choices transfers:

1. **Yoga is a general flexbox engine** (C++/WASM) solving problems a terminal doesn't
   have — fractional pixel rounding, baseline alignment across font metrics, aspect
   ratios, incremental relayout with dirty tracking. A terminal is an integer cell
   grid, one "font", and tiny: a 250×70 window is ~17k cells, so re-running layout
   from scratch every frame costs microseconds. The weight buys generality we can't
   use.
2. **React exists because JavaScript can't cheaply rebuild a tree every frame**, so Ink
   needs a reconciler and retained component state. Zig has arenas. Rebuilding the
   whole node tree per frame into a frame arena is cheaper than reconciling it.

libvaxis, the mature Zig TUI library, was evaluated seriously (and its cell-buffer +
internal-diff architecture is the right reference for our render layer). Its power is
retained-widget shaped and priced accordingly: building something simple takes a lot of
code, and its center of gravity is the full-screen app. zcli's center of gravity is
CLI-first with TUI moments, and the authoring bar is "a progress frame in ten lines."

The historically hard part of any layout engine — measuring wrapped text — already
exists in `packages/terminal/src/wrap.zig` (grapheme- and ANSI-aware via zg:
`displayWidth`, `wrapToWidth`, `wrapCount`), and `vterm` provides a cell model and a
headless terminal for golden-frame testing. The remaining work is genuinely small.

## Decision

**Build a terminal-native UI core — a new package layered on `terminal` and the
`vterm` cell model — defined by five interlocking choices.**

### 1. The frame model: static/live split

This, not the layout algorithm, is what produces the CLI/TUI hybrid feel. Output is
split into a **static** stream — emitted once, flows into scrollback — and a **live
region** at the bottom edge, erased and redrawn on every frame:

```zig
try app.emit("✓ built {s}\n", .{name});   // static → flows into scrollback
try app.frame(try statusFrame(a, t, s));  // live → measured, diffed, repainted
```

`emit` erases the live region, prints above it, repaints it (Ink's `<Static>`
mechanics). The live region is clamped to the viewport height and **clips rather than
scrolls** — scrollback can never be reflowed, so content taller than the terminal is a
design error we make impossible, not a pathology we corrupt scrollback with (Ink's
most notorious failure). Default clip is from the bottom. A full-screen TUI is not a
separate mode: it is a root box with `height = fill` (plus alt-screen), and the static
stream simply goes unused.

**Resize is a three-tier model**, tiered by write authority, not by cost. Reflowing a
screenful of this layout is microseconds; the binding constraint everywhere below is
what the terminal lets an application write, never compute — which is also why no
background/off-thread reflow exists in this design (see Considered Options):

1. **Live region** — full re-layout at the new size. Unconditional.
2. **Visible static tail** — repainted, reflowed at the new width. `emit` retains
   recently emitted blocks in **source form** (source text or node tree, not rendered
   cells) and tracks the rows each occupies; a block leaves retention once it has
   fully scrolled above the viewport, so retention stays bounded at about one
   screenful regardless of session length. On resize, one synchronized write erases
   from the tail's top edge down (cursor-up over the larger of the tail's old and new
   footprints, then `CSI 0 J` — viewport only: never scrollback, and never content
   above the tail), re-emits the retained tail so it rewraps at the new width, and
   repaints the live region below it. Synchronous and single-threaded: the user
   immediately sees a fully consistent screen at the new width.
3. **Scrollback** — immutable, by terminal authority rather than by our choice. No
   escape sequence exists to rewrite a line that has scrolled off; content there keeps
   the wrap width it was emitted at. The old-wrap seam sits exactly at the top of the
   viewport, invisible until the user scrolls up.

Because a resize invalidates every saved cursor position (terminals disagree about how
existing rows move), the tail and live region are addressed **relative to the bottom
edge** — the one anchor whose semantics survive resize across terminals.

### 2. Immediate mode: a component is a function

The tree is rebuilt every frame into a per-frame arena, laid out, painted, and
discarded. There are no retained widgets, no reconciler, no framework-held state — a
component is any function returning a `Node`, and all state (including animation, e.g.
a spinner's tick) lives in the caller's own structs:

```zig
fn statusFrame(a: Allocator, t: *const Theme, s: *const State) !Node {
    return ui.column(a, .{ .border = .rounded, .padding = 1 }, &.{
        try taskList(a, t, s),
        ui.row(a, .{ .gap = 1 }, &.{
            ui.text(t.accent, spinnerGlyph(s.tick)),
            ui.text(t.body, s.status_line),
            ui.spacer(),
            ui.text(t.dim, s.elapsed),
        }),
    });
}
```

Builders take the arena and **copy child slices into it**. This is the API keystone,
not a convenience: a `&.{...}` child literal is a stack temporary, so a component
function returning a `Node` whose children point into its own frame would dangle. The
arena copy makes component functions safely composable, and it resets every frame.

### 3. The layout protocol: constraints down, sizes up, clipping enforced

The entire contract is two functions per node:

```zig
pub const Size   = struct { w: u16, h: u16 };
pub const Limits = struct { max_w: u16, max_h: u16 }; // min implicit 0

measure(node, limits) Size    // returned size NEVER exceeds limits
render(node, surface) void    // surface is exactly the granted rect
```

Parents constrain children; children answer "what size do I want, given at most this
much" (a text's minimum width is 1 — it wraps or clips; fixed-size leaves refuse to
shrink internally but still clamp the returned value); parents position. "Children
stick to constraints" is enforced structurally, not by convention: `render` receives a
clipped sub-surface of the cell buffer, so a misbehaving node physically cannot paint
outside its rect. Overflow policy is one global rule — clamp and clip.

### 4. The node vocabulary: four variants

```zig
pub const Node = union(enum) {
    box:    Box,     // the only container: dir (.row/.column), gap, padding, border
    text:   Text,    // styled spans; wrap mode .wrap / .truncate / .clip
    spacer: void,    // sugar for an empty fill(1)
    custom: Custom,  // escape hatch: context ptr + measure/render fn ptrs
};
```

`row()`/`column()` are sugar over `box`. Everything else — spinner, progress bar,
prompt line, table, markdown block — is a component function composing these, or a
`custom` leaf when it truly needs cell-level drawing. `custom` receives a `*RenderCtx`
(theme, io, unicode capability) and is the pressure valve that keeps the core small:
libvaxis-grade widgets can exist as leaves without the core learning about them.

### 5. The sizing vocabulary: three words, one pass, no solver

```zig
pub const Dim = union(enum) { fit, len: u16, fill: u16 };
// plus optional .min / .max clamps for the rare cases that need them
```

Sizing lives on the node (children self-describe, Ink-style) rather than in parent
constraint lists (ratatui-style). Distribution inside a box is a single deterministic
pass: subtract border/padding/gaps; grant `len` children their cells; measure `fit`
children **in declaration order** against the remaining budget (order-dependent by
design, documented); split the remainder among `fill` children by weight with
largest-remainder rounding so rows always sum exactly. Cross axis stretches by
default, with `align: .start/.center/.end` otherwise.

This vocabulary deliberately deletes flexbox surface: the `justify-content`/
`align-items` matrix collapses into `spacer`, and `percent` is subsumed by fill
weights. Defaults make the common case zero-config: column children default to
`width = fill, height = fit`; row children default to `fit`; text defaults to wrap.

### Rendering

The live region renders into a cell buffer (the `vterm` cell model), is diffed against
the previous frame, and emits minimal updates wrapped in synchronized output
(DECSET 2026) to eliminate flicker. `vterm` doubles as the golden-frame test harness;
measure/layout are pure functions over `Limits`, unit-testable with no terminal.

## Considered Options

- **Bind or port Yoga** — rejected: WASM/C++ dependency against a libc-free static
  identity, and the engine's weight (fractional units, baselines, incremental
  relayout) solves non-problems on an integer cell grid.
- **Adopt libvaxis, or build a retained widget system in its image** — rejected for
  the core: excellent for full-screen apps, but the retained-widget model carries
  authoring weight that fights the "progress frame in ten lines" bar, and its event
  plumbing presumes the TUI is the app. Its cell/diff render layer remains the design
  reference.
- **A constraint solver (cassowary, as in ratatui)** — rejected: a general solver for
  a vocabulary (`fit`/`len`/`fill`) a few hundred lines of direct distribution can
  satisfy deterministically. Solvers also make layout results harder to predict.
- **Full flexbox vocabulary (justify/align matrix, percent, wrap)** — rejected:
  `spacer` and fill weights express the same layouts with less API; every word added
  to the sizing vocabulary is paid for in every component that must consider it.
- **Status quo: per-widget repaint loops** — rejected: this is the bug factory the
  engine exists to close (flush-before-read coordination, no composition into a
  shared frame, N paint paths to make Windows-safe separately).
- **Background (off-thread) reflow of non-visible static content on resize** —
  rejected as impossible, not as too slow: content above the viewport lives in the
  terminal's scrollback, which no escape sequence can rewrite. A recalculated result
  would have nowhere to be written. The salvageable insight — "repaint what's visible
  immediately" — is adopted as tier 2 of the resize model, and it needs no thread:
  the visible tail is a screenful, and reflowing it is microseconds.
- **Own the scrollback entirely (alt-screen + app-managed scrolling)** — rejected:
  the only path to full-history reflow, but it forfeits native selection/copy,
  mouse-wheel scrolling, terminal search, tmux copy-mode, and output persisting after
  exit — the CLI half of the hybrid. A full-screen app that wants this can still
  build its own scrolling viewport as a `custom` leaf.

## Consequences

- **One paint path.** `progress` and `prompts` migrate from hand-rolled line rewrites
  to component functions over the core; the flush-before-read bug class and cursor
  hide/show bookkeeping dissolve into `frame()`. Migration is incremental — the old
  rendering keeps working until each package is ported.
- **`emit` retains until scroll-off.** The visible-tail repaint means static blocks
  are kept in source form until they leave the viewport — an internal contract change
  to `App` (blocks must be arena-copied at emit, not just written), but no API change.
  When live content is promoted to static remains API-visible (`emit`), and the
  resize watching in `prompts` moves into the app loop.
- **The resize seam is accepted and terminal-dependent.** Deep scrollback keeps its
  old wrap width (invisible until the user scrolls up). Worse, terminals that reflow
  on their own (Kitty, iTerm2, Windows Terminal) rewrap the viewport *before* we
  repaint — a width shrink can push rewrapped rows into scrollback, stranding a
  duplicate of content we then re-emit. Every hybrid pays this tax (Ink apps and
  Claude Code show the same artifact); source-form retention means our repainted tail
  is at least *correctly* rewrapped rather than terminal-guessed.
- **State stays with the user.** No framework-held component state means no state
  lifecycle to learn or leak; the cost is that callers own their tick counters and
  selection indices, which is idiomatic Zig anyway.
- **The arena is load-bearing.** Frame builds allocate freely and reset wholesale;
  component signatures thread `Allocator` first, per the ADR-0001 arena convention.
- **Order-dependence is documented, not solved.** `fit` measured in declaration order
  means sibling order can change distribution. Accepted for predictability and
  single-pass simplicity.
- **Windows must degrade gracefully.** Synchronized output support differs between
  Windows Terminal and the legacy console; the diff renderer treats DECSET 2026 as an
  optimization, never a correctness dependency. The existing ConPTY e2e harness
  covers the interactive path.
- **Explicit non-goals with clean later homes:** overlays/z-layers (a fifth node
  variant if ever needed), focus management and event routing (a layer above the
  tree), scrollable viewports (a `custom` leaf first), incremental relayout (unneeded
  at terminal sizes). None forces a core redesign; none blocks v1 of the engine.
- **Estimated size:** the surface/diff layer plus measure/layout for the four-node
  vocabulary is on the order of 1.5–2k lines including tests — the historically hard
  part (text measurement) already ships in `terminal.wrap`.
- **Build order:** (1) cell surface + diff renderer, golden-frame tested via `vterm`;
  (2) `measure`/`render` for box/text/spacer as pure functions; (3) app loop with
  static/live, arena, resize, sync output; (4) port two real consumers — multi-bar
  `progress` and a Claude-Code-shaped demo (streaming text above, animated bordered
  frame below) — to validate the vocabulary before `prompts` migrates.
