# Overlays: z-layers by surface-compositing, no absolute addressing

Status: accepted

ADR-0013 and ADR-0015 both named overlays / z-layers as a clean deferral — "a
fifth node variant or an absolute-addressed overlay pass" — and both tied it to
the one piece of machinery the layout engine deliberately does *not* have: an
absolute-`CUP` diff renderer. The live region floats in scrollback, so the
renderer (`diff.zig`) addresses cells relative to the frame's top-left and never
with `CUP`; ADR-0015 §2 spelled out that absolute addressing buys "cheap
out-of-flow drawing (overlays/popups)" and deferred the renderer rewrite until a
feature needed it.

Overlays are that feature. This ADR records how they landed — and why the
renderer rewrite turned out **not** to be needed after all.

## The realization: compositing happens in the cell buffer, not on the terminal

An overlay draws out of flow: a modal in the middle of the screen, a toast in a
corner, a dim over content. "Out of flow" reads like it needs absolute
addressing. It does — but only *within the surface*, which is plain array
indexing (`Surface.idx`), not on the terminal.

Every frame already renders into one back `Surface`, then the diff renderer
compares it against the front surface and emits the minimal relative byte stream.
An overlay is just *more cells painted into that back surface, on top of the base
tree, before the diff runs*. The diff then diffs the **final composite** and
emits its usual relative moves; it never learns an overlay existed.

So overlays add **zero terminal I/O, zero new escape sequences, and no `diff.zig`
change**. The absolute-`CUP` rewrite ADR-0015 deferred stays deferred — correctly,
because overlays don't need it. The only place addressing had to become absolute
was inside the cell buffer, where it was already trivial.

## Decisions

### 1. A `stack` is a third box arrangement, not a fifth node kind

`Direction` gains `stack` alongside `row`/`column`. A `row`/`column` distributes
its main axis among children; a `stack` overlaps them in one region — declaration
order is z-order, later children composite over earlier ones. Measure maxes both
axes (a stack is as big as its largest layer) where a flow box sums its main axis.

Making it a `Direction` rather than a new `Kind` means a stack reuses the entire
`Box` struct and its chrome — border, padding, background, the inner-region math —
so a bordered modal container or a padded overlay panel is just a stack with the
`BoxOpts` every other box takes. A fifth `Kind` would have re-implemented that
chrome. "Direction" stretches slightly to mean "arrangement," which is the honest
generalization: stacking is a third way to arrange children.

### 2. Each layer fills the stack; position with composition, not new fields

A stack grants every child the **full** inner region — it does not size or place
layers. A bare layer therefore fills the stack. To float a smaller layer (a
modal), wrap it in the existing layout vocabulary: `ui.center` is
`column{ spacer, row{ spacer, child, spacer }, spacer }`, which sizes the child to
its content and pushes it to the middle with transparent spacers. Corners, edges,
and margins fall out of the same spacer/`align_self`/`len` toolkit.

This adds **no positioning primitive and no new node fields** — 2D placement is
composition, consistent with how the engine already right-aligns (a leading
spacer) and centers on the cross axis (`align_self`).

### 3. A style-less box is transparent

Compositing needs a notion of "this layer didn't touch this cell, so the layer
beneath shows through." The engine gets it for free from one rule: **a box paints
its background only when it has a style.** `renderBox` fills its region only when
`b.style` is non-default; a style-less box (a `center` scaffold, a plain
container) paints nothing and lets lower layers show through its gaps, while a box
with a background is opaque and erases the base beneath it. Spacers already paint
nothing; text paints only its glyphs.

This is invisible to flow layout — the back surface is cleared every frame, so a
style-less box skipping its blank-fill paints the same blanks it would have. It
only changes behavior *under a stack*, where an earlier layer has already painted.
No transparent-cell sentinel, no separate compositing pass, no `Cell` change.

## Consequences

- **The renderer is untouched.** No `CUP`, no absolute addressing, no second paint
  pass. Overlays ride the existing relative diff, so they work byte-for-byte the
  same in hybrid and full-screen — compositing is upstream of the mode split.
- **No PTY validation needed.** Overlays add no terminal I/O, so the headless
  layout tests plus vterm golden-frame tests (compositing survives the real diff
  renderer; closing an overlay repaints the base) cover them fully.
- **Opacity is `.style`, not alpha.** A layer is transparent (no style),
  glyph-transparent (text — gaps show through), or opaque (a background). There is
  no partial transparency; a dim-the-background overlay is a full-region layer
  whose style is the dim, not an alpha blend.
- **Anchored popups are the next deferral, with the same clean home.** A dropdown
  pinned to a specific widget's computed (x, y) needs layout to expose measured
  positions or an anchor system — genuinely more than a stack, and with no
  consumer yet. `stack` + composition covers modals, toasts, and full-region
  overlays (the bread and butter); anchored popups are a follow-up when a consumer
  needs one.
- **`emit`/scrollback is unaffected.** Stacks are a node-tree feature; they change
  neither the static stream nor the live-region bookkeeping.
