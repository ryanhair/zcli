# Scrollable viewports: a windowed blit, content rendered in full

Status: accepted

ADR-0013 and ADR-0015 named scrollable viewports as a clean deferral — "a
`custom` leaf first, a first-class node if it earns it." This is that leaf: a
fixed window onto content taller than the space it is granted (a log pane, a
long list, a tall form), with a caller-owned vertical scroll offset.

## The core problem

To scroll, you must render content at its **full natural height**, then show
only a window of it offset by `scroll_y`. But the live surface only has cells
for the *visible* rows — you cannot render 1000 lines into a 20-row surface. The
diff renderer, deliberately, addresses cells relative to the frame origin
(ADR-0015 §2); it has no notion of a content offset.

## Decision: render the child in full into a scratch surface, then blit a window

A `viewport` is a `custom` leaf. Its `renderFn`:

1. measures the child at the viewport width and **unbounded height** → the
   content height,
2. renders the child in full into a **scratch `Surface`** of
   `width × content_h`, allocated from the frame arena,
3. clamps `scroll_y` to `[0, content_h − viewport_h]`,
4. copies rows `[scroll_y .. scroll_y + viewport_h)` of the scratch into the
   viewport region (`Region.copyRows`, the one new surface primitive).

`measure`/`render` are **untouched** — the child renders normally into a real
(taller) surface, so wide graphemes, styles, borders, nested `custom` leaves,
even nested viewports all work for free. The whole feature is one small copy
primitive plus a builder.

### Why this over teaching the renderer/Region about a content offset

The alternative — split `Region` into a coordinate origin (which may sit *above*
the clip, so content scrolls up) and a clip window, and let the child lay out at
`content_h` while painting clipped — is allocation-free and a more general
translation primitive. But it touches `Region`'s core: signed coordinates, every
`writeText`/`fill`/`put` clipping against a separate rect, and the wide-grapheme-
straddles-the-top-edge case. Bigger diff, higher risk, and no consumer yet needs
its generality.

The scratch-surface blit is exactly ADR-0013's "a `custom` leaf first." It keeps
the four-node vocabulary intact (a viewport is a `custom`, not a fifth `Kind`),
and if profiling ever shows the per-frame scratch alloc matters, the offset-clip
Region becomes the first-class-node upgrade **with no change to the `viewport`
API**. That optionality is the reason to start here.

## Consequences

- **Scroll state stays caller-owned** (immediate mode): the app holds `scroll_y`
  and adjusts it on ↑/↓/PageUp/PageDown, matching "no widget owns state." The
  viewport only *clamps* it, so an overshoot (PageDown past the end) rests on the
  last page. A widget that needs "am I at the bottom?" gets a measure helper when
  one is written — deferred until then.
- **Content is fully realized each frame.** Fine for the ordinary
  screenful-or-few; very tall content (a 50k-line log) pays for its full height
  in scratch cells each frame. That is the accepted cost of "custom leaf first,"
  and the exact thing the offset-clip Region would later fix.
- **Vertical scroll only.** Horizontal scroll is rare in TUIs and would double
  the API; deferred until a consumer needs it.
- **No scrollbar indicator** in this increment — a thin thumb column is a cheap
  follow-up on top of the same mechanism.
- **The renderer is untouched.** Like overlays (ADR-0016), the work happens in
  the cell buffer, upstream of the terminal: the blitted window is just cells,
  and the relative diff renderer paints them as usual. Short content leaves the
  rows below it untouched, so a viewport composites over a lower stack layer the
  same way any transparent region does.
- **No PTY validation needed for the primitive** — it adds no terminal I/O.
  Headless layout tests plus vterm golden-frame tests (styled and wide content
  survive the blit; the window tracks `scroll_y`) cover correctness; the PTY only
  smoke-tests the example integration.
