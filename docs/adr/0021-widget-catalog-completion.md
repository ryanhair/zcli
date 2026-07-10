# Completing the widget catalog: Table, Tabs, TextArea, a focus ring, a scrollbar

Status: proposed

ADR-0018 established the widget contract and shipped the form controls
(`TextInput`, `Checkbox`, `Select`, `Button`); ADR-0019 closed the full-screen
deferral list (probe, hardware cursor, anchored popups). The remaining gaps are
data display and multi-line editing: a TUI evaluator with a table of rows has no
**Table**, no **Tabs** to page between views, no **TextArea** for a description
field, focus routing that gets tedious past ~10 widgets, and no scrollbar to
signal that a `viewport`/`Select`/`Table` scrolls. This ADR proposes the arc that
finishes the catalog — five increments, one PR each — and writes down where the
boundary sits (the *Deferred* section) so it's decided once, up front.

Everything here stays inside the ADR-0018 contract: a widget is a plain state
struct the caller embeds in its own `State`, with `view(self, a, opts) !Node`
and `handle(self, key) bool` (returns *consumed*). All state and focus are
caller-owned. No retained widget tree, no widget IDs, no framework loop. Where a
widget must paint something the four-node vocabulary can't express directly, it
does so as a **`custom` leaf** — the `WrapSelectView` / `viewport` / `probe`
precedent (ADR-0017/0018/0019), whose `renderFn` learns the granted width and
absolute `region.rect` that `view` can't. Styling derives from the root
`zcli_theme` at build time (ADR-0020): the `theme` option defaults to
`theme_mod.appTheme()` and tokens resolve through `th.<group>.<token>.resolve(th.palette)`,
so styles are never required at a call site.

## Increment → PR mapping

| # | Increment | PR | Modifies example |
|---|-----------|----|--------------|
| 1 | Table | one PR | `examples/fullscreen.zig` (its fake table → a real one) |
| 2 | Tabs | one PR | `examples/fullscreen.zig` (or a tiny tabs example) |
| 3 | TextArea | one PR | new `examples/textarea.zig` (or extend `form.zig`) |
| 4 | `FocusRing` helper | one PR | `examples/form.zig` (should get visibly shorter) |
| 5 | Scrollbar indicator | one PR | `examples/fullscreen.zig` viewport / Table |

Each increment lands with unit tests (`input_test.zig` pattern: key handling +
window/scroll math), golden/render tests where drawing is nontrivial
(`golden_test.zig`), a runnable/updated example (CI compiles them), a
`packages/ui/README.md` catalog line, and a `CHANGELOG.md` entry under
Unreleased. The website `ui.shtml` widgets section is synced once, at the end of
the arc (per-increment website edits optional).

---

## Increment 1: Table

A read-only data grid — the single highest-value addition. Selection and a scroll
window, ported from `Select`. It renders as a `custom` leaf (`TableView`) because,
like `WrapSelectView`, it needs the granted width to allocate column widths and
truncate cells, and it wants the same paint-its-own-window efficiency `Select`'s
single-line path has (it already knows which row slice is visible).

### State struct

```zig
pub const Table = struct {
    highlighted: usize = 0,    // selected row; caller reads Table.highlighted
    scroll: usize = 0,         // first visible row — persistent, like Select
};
```

Same two persistent fields as `Select` (named identically for consistency — the
selection is `highlighted`, the window top is `scroll`), maintained by the shared
`scrollFor` rule (see below). Rows and columns are caller-owned and passed to
`view` each frame (immediate mode).

### View opts

```zig
pub const Column = struct {
    header: []const u8,
    width: Dim = .fit,     // the EXISTING sizing vocabulary: .fit / .len(n) / .fill(w)
};

pub const ViewOpts = struct {
    focused: bool = false,
    columns: []const Column,
    rows: []const []const []const u8,   // rows[r][c] = cell text
    height: u16 = 10,                   // visible body rows (excludes the header)
    theme: *const Theme = theme_mod.appTheme(),
};
```

**Column widths reuse the existing `Dim` vocabulary — no new words.** `.fit`
sizes to the widest cell in that column (header included), `.len(n)` is a fixed
column, `.fill(weight)` splits leftover width proportionally — exactly what
`node.zig`'s box distribution already does. The natural implementation is to
**build one `row{}` per visible line out of per-cell `text` nodes carrying those
`Dim`s and let the layout engine distribute** (the `Select` overflow-gutter row
is the precedent: `row{ .{ .width = .{ .len = label_w } }, .{ .width = .{ .len = 1 } } }`).
That reuses ADR-0013's column math verbatim and gets `fit`/`len`/`fill` for free.
The `custom` leaf is then thin: it computes the visible row slice, emits the
header row plus one body row per visible line via the builders, and draws the
overflow gutter/highlight — the column sizing is the engine's job, not the
widget's. (`TableView` still owns *rendering* to paint the full-width highlight
band and the gutter cleanly, as `WrapSelectView` does.)

**Rows representation — DECISION: `[]const []const []const u8` (a materialized
slice of rows, each a slice of cell strings).** The handoff says start simple,
and a row callback (`fn(row_idx) []const []const u8`) buys nothing at current
scales: the content is realized in full anyway (ADR-0017's accepted cost), the
caller already holds its data as a slice in virtually every case, and the
callback would fight the immediate-mode "pass the data in each frame" idiom while
adding a closure/context-pointer dance to every call site. Lazy/virtual row
materialization is an explicit non-goal (below); if a consumer ever needs a
100k-row grid, the callback is the clean upgrade **with no `Table` state change**
(same optionality argument ADR-0017 made for the offset-clip `Region`). Start
with the slice.

### Rendering (`TableView` custom leaf)

- **Header row** in `th.prompts.hint` style over a full-width band — a fixed,
  non-scrolling row above the body (like `fullscreen.zig`'s current bold/underline
  header line, but themed and column-aligned).
- **Column truncation** uses the existing width/ANSI-aware machinery: per-cell
  `text` nodes with `wrap = .truncate` truncate with `…` through the engine's
  `writeTruncated` (grapheme-aware `prefixForWidth`, `ctx.unicode` ellipsis) — the
  same path `Select`'s truncation rides. No new truncation code.
- **Selected-row highlight** paints the highlighted body row in
  `th.prompts.selected` across the row band (the `Select` `is_hi` rule:
  the current row stands out whether or not the table is focused; the `›` focus
  marker — or a reverse band — signals focus). Non-highlighted rows are plain.
- **Overflow arrows** in a 1-cell right gutter, exactly as `Select` (ADR-0018
  incr4): dim `↑`/`↓`/`↕` in `th.prompts.hint` when rows are hidden
  above/below the window. Reuse the gutter-column idiom so the body still
  measures to its intrinsic width.

### Keys

`↑`/`↓` move the selection by one; `home`/`end` jump to first/last;
**`PgUp`/`PgDn`** move by `height` rows. `handle` mirrors `Select.handle`'s
signature so the highlight and scroll stay in step with what `view` renders:

```zig
pub fn handle(self: *Table, key: Key, row_count: usize, visible: u16) bool
```

It consumes `up`/`down`/`home`/`end` and (new vs `Select`) `pageup`/`pagedown`;
everything else bubbles (Tab/Enter navigate; the caller reads the choice as
`rows[table.highlighted]`). After a move it calls the **shared** `scrollFor` to
keep the highlight in the window.

> **Key-enum note.** `terminal.Key` today has `up/down/home/end` but **no
> `pageup`/`pagedown`** (see `packages/terminal/src/key.zig`). ADR-0018 already
> set the precedent that a widget need may add one `Key` variant (it added
> `.back_tab`, "the one change outside `packages/ui`"). Increment 1 adds
> `.pageup` and `.pagedown` to the parser (recognizing `CSI 5~` / `CSI 6~`) —
> the one out-of-`ui` change here, shared by Table, TextArea (incr 3), and any
> `viewport` consumer that wants paging. If that turns out to widen scope
> undesirably, the fallback is to bind paging to `Ctrl-U`/`Ctrl-D` (already
> representable as `.ctrl`) and defer the parser change; the ADR's preference is
> the real PgUp/PgDn keys.

### Scroll-window reuse

`scrollFor(scroll, hi, visible, count)` in `input.zig` is already the exact
persistent-scroll rule Table needs (it slides the window the minimum to keep the
cursor visible, clamped to the content). **Promote it** from `Select`-private to
a shared helper both widgets call — no logic change, just visibility. (`Select`'s
`growWindow` is the *wrapped* variant; Table rows are single-line, so `scrollFor`
is the right one, same as `Select`'s single-line path.)

### Example

`examples/fullscreen.zig` currently fakes a process table with hand-formatted
`text` rows in a `viewport` plus manual `keepSelectionVisible`. Rewriting it as a
real `Table` (PID/CPU%/MEM%/COMMAND columns via `Column` specs) is both the proof
and the demo — the manual scroll bookkeeping disappears.

### Theme tokens used

`th.prompts.selected` (highlighted row), `th.prompts.hint` (header + overflow
arrows), `th.prompts.marker`/`›` (focus marker). All existing `PromptTheme`
tokens — no new tokens, consistent with ADR-0018's "widgets share the prompt
vocabulary" and ADR-0020's derive-from-`zcli_theme` rule.

---

## Increment 2: Tabs

Mostly composition; cheap. The widget is **only the tab-bar row** — a horizontal
strip of styled labels with the active one highlighted. It does **not** own the
content panes: the caller switches what it renders below the bar based on the
`active` index it owns (immediate mode — the tab bar is stateless chrome over a
caller value, like `Button` is a stateless action).

### State / opts

Focus/selection is caller-owned — there is no persistent widget state at all, so
`Tabs` can be a zero-field struct (or a bare namespace of `view`/`handle`),
matching `Button`. The active index is passed into `view` and `handle`:

```zig
pub const ViewOpts = struct {
    focused: bool = false,
    labels: []const []const u8,
    active: usize,
    theme: *const Theme = theme_mod.appTheme(),
};

// caller owns `active` and passes the count so the widget can wrap/clamp:
pub fn handle(self: *Tabs, key: Key, active: *usize, count: usize) bool
```

`handle` takes a `*usize` to the caller's active index (the caller *owns* it; the
widget just advances it) — parallel to how `Select.handle` takes `count`/`visible`
so state stays in step with render. (An alternative is returning the new index; a
pointer keeps the `handle → bool consumed` shape uniform.)

### Rendering

A `row{}` of `text` nodes, one per label, with a gap or separator between them.
The active label uses `th.prompts.selected`; inactive labels are plain (or
`th.prompts.hint` for a dimmer look). No `custom` leaf needed — it's a plain
builder composition, so `Tabs.view` can be built from `ui.zig` builders the way
`Checkbox` is built from node literals. Optionally underline the active tab.

### Keys

`←`/`→` move the active tab (wrapping via the count), consumed. Optionally number
keys `1`-`9` jump directly (a `.char` in `'1'..'9'` selecting that tab if it
exists). **`Tab` stays reserved for the focus ring** — Tabs never consumes it, so
the ring can still move focus off the tab bar. Everything else bubbles.

### Theme tokens

`th.prompts.selected` (active tab), `th.prompts.hint` (inactive/muted) — existing
tokens only.

---

## Increment 3: TextArea

The hardest one — scoped tightly, kept consistent with `TextInput`. Caller-owned
buffer, codepoint-granular editing (grapheme clusters stay deferred exactly as
ADR-0018 defers them for `TextInput`), a `(row, col)`-shaped cursor, vertical
scroll when content exceeds the visible height, and soft wrap via the existing
grapheme/ANSI-aware wrap machinery (`terminal.wrapForEach`/`wrapCount`, the same
code `Select`'s wrap path and the prompts use).

### State struct

```zig
pub const TextArea = struct {
    buffer: []u8,          // caller-owned storage, like TextInput (capacity = caller's)
    len: usize = 0,
    cursor: usize = 0,     // insertion point: a byte offset (codepoint boundary),
                           // like TextInput — the single source of truth
    scroll_row: u16 = 0,   // first visible visual row — persistent
};
```

**The cursor stays a byte offset internally**, exactly like `TextInput`, so
insert/delete/boundary logic is shared verbatim (`prevBoundary`/`nextBoundary`,
`insert`/`deleteBack`/`deleteForward` generalize to "buffer with embedded `\n`s").
The `(row, col)` the handoff calls for is the *derived render/motion* view of that
offset: vertical arrows and PgUp/PgDn map to it, and the caret's `(row, col)` is
what render reports for the hardware cursor. Deriving `(row, col)` from the offset
each frame (not storing it) keeps a single source of truth and avoids the
row/col-vs-bytes desync bugs a stored pair invites — the same reasoning
`TextInput` uses to derive its horizontal scroll from `cursor` alone.

### Rendering (`TextAreaView` custom leaf)

A `custom` leaf, because soft wrap needs the granted width (which `view` doesn't
know) and the caret's absolute cell must be reported for the hardware cursor. Its
`renderFn`:

1. soft-wraps `value()` at the granted width via `wrapForEach` (grapheme/ANSI
   aware), producing visual rows — but wrapping must respect hard `\n`s
   (paragraph breaks), so it wraps *each* `\n`-delimited line and concatenates
   the visual-row lists (a thin wrapper over `wrapForEach`, not new wrap logic);
2. computes the caret's `(visual_row, col)` from `cursor` against that same wrap;
3. clamps `scroll_row` to keep the caret visible (the `scrollFor` rule, in visual
   rows) and paints the visible window of visual rows into `region`;
4. reports the caret via `cursor_out` (below) and draws no block there.

Vertical scroll is a visual-row window over the wrapped content — the same
"render/measure a window, keep the cursor in view" shape as `Select`'s wrap path,
minus the per-option grouping. (It could paint-to-scratch-and-blit via
`Region.copyRows` like `viewport`, but painting only the visible window directly
is cheaper and matches `Select`'s "I already know the visible slice" rationale.)

### View opts + hardware cursor

```zig
pub const ViewOpts = struct {
    focused: bool = false,
    placeholder: []const u8 = "",
    width: Dim = .{ .fill = 1 },
    height: u16 = 6,                 // visible visual rows
    theme: *const Theme = theme_mod.appTheme(),
    cursor_out: ?*?Point = null,     // ADR-0019 incr2 — same shape as TextInput
};
```

The **hardware cursor** reuses ADR-0019 incr2 exactly: when `cursor_out` is set
and the field is focused, render writes the caret's absolute cell
(`region.rect.x + col`, `region.rect.y + visual_row - scroll_row`) into it and
draws no block; the caller's `after_frame` hook calls `app.cursorAt(state.caret)`.
This is the identical channel `form.zig` already uses for `TextInput`, so a
TextArea drops into the same loop with no new plumbing — the caret is real, and
across multiple lines it's the only sane option (a reverse-video block caret on a
wrapped multi-line field reads poorly).

### Keys

- `char` → insert; `backspace`/`delete` → delete a codepoint;
- `left`/`right` → codepoint motion (across `\n` boundaries too);
- `up`/`down` → move one visual row, preserving the target column where possible
  (derived from the wrap);
- `home`/`end` → start/end of the current visual row;
- `enter` → insert a newline (**TextArea consumes Enter** — the multi-line
  distinction from `TextInput`/forms, where Enter is submit/navigation);
- `pageup`/`pagedown` → move by `height` visual rows *if cheap* (they ride the
  same `.pageup`/`.pagedown` parser variant increment 1 adds; if that variant is
  deferred, so is paging here — arrows still work).

All editing keys are consumed (they belong to the field, per ADR-0018);
unconsumed keys (Tab/Shift-Tab/Esc) bubble to navigation.

### NOT in scope (this increment)

Undo, selection ranges, clipboard, syntax highlighting — see *Deferred*.

### Theme tokens

`th.prompts.hint` (placeholder), the reverse caret style only as a fallback when
`cursor_out` is null (matching `TextInput`). No new tokens.

---

## Increment 4: focus-ring helper

Manual `switch (state.focus) { .a => a.handle(key), ... }` dispatch (ADR-0018)
scales badly past ~10 widgets. The fix must **not** introduce a framework loop or
a widget registry — that is the exact line ADR-0018 drew (focus is caller-owned,
routing is an explicit switch, "a library-managed focus registry would need widget
identity, exactly what this avoids"). So the helper is **sugar over the existing
switch, not a layer**: the caller can bypass it entirely, and it introduces no
retained state.

### Chosen comptime design: extras-tuple dispatch

`FocusRing(State)` inspects `State`'s fields at comptime and identifies the
**widget fields** — those whose type has a `handle` decl (a `@hasDecl(F, "handle")`
duck-typed check, the same "convention not interface" stance ADR-0018 takes for
`view`/`handle`). It collects those field names in declaration order — that list
*is* the ring — and reifies a named `Focus` enum from them, so the caller's focus
value is a real `state.focus == .submit` enum, not a bare `usize` index.

```zig
pub fn FocusRing(comptime State: type) type {
    // comptime: `widget_field_names` = State's fields whose type has a `handle`
    // decl, in declaration order. That list is the ring.
    return struct {
        // A named enum generated from the field names, e.g.
        // `enum { user, pass, remember, submit }` — the caller's focus type.
        pub const Focus = @Enum(Tag, .exhaustive, widget_field_names, values);

        pub fn next(f: Focus) Focus { ... } // wrapping over the ring length
        pub fn prev(f: Focus) Focus { ... }

        pub fn dispatch(state: *State, f: Focus, key: Key, extras: anytype) bool {
            inline for (widget_field_names, 0..) |name, i| {
                if (@intFromEnum(f) == i) {
                    const w = &@field(state, name);
                    const base = .{ w, key };
                    const args = if (@hasField(@TypeOf(extras), name))
                        base ++ @field(extras, name) // multi-arg widget
                    else
                        base; // plain handle(key)
                    return @call(.auto, @TypeOf(w.*).handle, args);
                }
            }
            unreachable;
        }
    };
}
```

The helper provides:

- `next(f)` / `prev(f)` — wrapping increment/decrement over the ring length
  (thin generalizations of the existing `focusNext`/`focusPrev`, which already do
  exactly this over an enum's field count), now typed as the derived `Focus`;
- `dispatch(state, f, key, extras) bool` — full handoff: routes `key` to the
  focused widget's `handle` and returns *consumed*. An `inline for` over the ring
  selects the matching field, borrows `&@field(state, name)`, and `@call`s its
  `handle` with a comptime-concatenated argument tuple. Everything is comptime
  (`inline for` + tuple `++` + `@call`) — no vtable, no dynamic dispatch, codegen
  identical to the hand-written switch.

This keeps the original **handoff** requirement (a `dispatch(key) → bool` that
routes to the focused widget) — the N-arm switch, the part that actually scales
badly, moves into the helper, not just the ring ordering.

**The arity problem, handled, not dropped.** `handle` signatures are heterogeneous:
`TextInput.handle(key)` vs `Select.handle(key, count, visible)` vs
`Tabs.handle(key, active, count)`. The **extras tuple** solves it: widgets with a
plain `handle(key)` need no entry; a multi-arg widget gets its extra args as a
tuple keyed by field name, concatenated onto `.{ w, key }` before the `@call`.
The whole hand-written switch collapses to:

```zig
const Ring = ui.widgets.FocusRing(State);
const consumed = Ring.dispatch(&state, state.focus, key, .{
    .list = .{ options.len, 8 }, // Select's extra (count, visible) args
});
```

One nuance the sketch must respect: because `state.focus` is a *runtime* value,
the `inline for` compiles every arm, so `extras` describes the *widgets* (each
multi-arg field's extra args), not just the currently-focused one — the entry for
a multi-arg field must be present even on a frame where a different widget is
focused. Only the matching arm actually runs. (Verified against 0.16: `@Enum`
reifies the named enum, tuple `++` concatenates `.{w, key}` with the keyed
extras, and `@call(.auto, T.handle, args)` dispatches — codegen matches the
switch.)

**Button caveat.** `Button.handle`'s `true` means *activated*, not merely
*consumed* (ADR-0018 incr3). So a caller that routes a Button through `dispatch`
runs the button's action whenever `consumed and state.focus == .submit` — the
ring doesn't change that contract; it's the same "consumed ⇒ activated for a
Button" the hand-written switch already had.

### Fallbacks

If the comptime machinery proves not worth it in practice, the **simplification**
is *ring order only, caller keeps the switch*: the helper owns only the ring
`Focus` enum and `next`/`prev`/index mapping (the tedious, error-prone part), and
the caller keeps a small `switch (state.focus)` for the handful of widgets that
take extra args. This still deletes the focus-ordering boilerplate without the
extras-tuple reflection.

The **last resort** is a **runtime slice-of-vtables**:
`[]const struct { handle: *const fn(*anyopaque, Key) bool }` the caller populates
once. It's a registry-lite, so it reintroduces a hint of the widget identity
ADR-0018 avoided — the escape hatch only if both comptime designs fight the
language. (The uniform-`handle(key)`-adapter route — forcing every widget to grow
a `handle(key) bool` that reads its counts from a borrowed slice — stays
**rejected**: it forces an API change on shipped widgets.)

### Scope

Sugar, ≤ ~100 lines, no framework loop, no registry, fully bypassable. Prove it
by refactoring `examples/form.zig` — with full dispatch the example loses *both*
the `Field` enum (now the derived `Focus`) *and* the hand-written
`switch (state.focus)` dispatch, plus the `focusNext`/`focusPrev` + `field_count`
threading, collapsing to a struct-derived ring and a single `Ring.dispatch` call.

---

## Increment 5: scrollbar indicator

ADR-0017 flagged this as a cheap follow-up: "a thin thumb column is a cheap
follow-up on top of the same mechanism." An optional vertical thumb column
showing scroll position/proportion, for `ui.viewport` and the `Select`/`Table`
scroll windows.

### Shape

An opt-in field on the existing opts (`scrollbar: bool = false` on `ViewportOpts`,
and on `Select`/`Table` `ViewOpts`). When on, the widget reserves a 1-cell right
column (the same gutter idiom `Select`'s overflow arrows already use) and paints a
thumb: `track` cells in a dim style, `thumb` cells in a brighter style, thumb
length ∝ `visible/total` and thumb position ∝ `scroll/(total − visible)`. The math
is `content_h` and `scroll_y`, both already known at render (viewport measures the
content; `Select`/`Table` know count/window). Theme-derived: thumb =
`th.surface.border` (or a dedicated derived style), track = `th.prompts.hint` —
existing tokens, per ADR-0020.

### DECISION: off by default, opt-in.

Not on-when-overflow. Two reasons. **(1) It changes layout** — reserving a gutter
column shrinks the content by one cell, and silently doing that only sometimes
(when content happens to overflow) makes a widget's content width jitter as data
grows past the fold, the exact instability ADR-0018 incr4 fixed for `Select`'s
label column ("so the width doesn't jitter as you scroll"). An explicit opt-in
gives a *stable* width regardless of content. **(2)** `Select`/`Table` already
carry dim `↑`/`↓`/`↕` overflow arrows in their gutter, which signal "this
scrolls" without a permanent column; the scrollbar is the richer, opt-in upgrade
for callers who want a proportional indicator (a long log `viewport`), not a
default every list pays for. `viewport` has no arrows, so it's the primary
consumer — but even there, opt-in keeps its width predictable. (This mildly
diverges from ADR-0018's arrows being always-on; justified because arrows are
zero-width-cost drawn in an already-reserved gutter, whereas a scrollbar *reserves*
the column.)

---

## Deferred (non-goals)

Written down here so the boundary is decided once. These are out of scope for the
whole arc; each has a clean upgrade path if a consumer ever needs it.

- **Lazy / virtual viewport rendering.** Content is rendered in full (ADR-0017's
  accepted cost); Table rows likewise materialize fully. Fine at current scales;
  the row-callback / offset-clip `Region` upgrades exist if a huge grid/log ever
  needs them, with no widget-API change.
- **Horizontal scrolling.** Vertical only, everywhere (viewport, Table, TextArea).
  Horizontal scroll is rare in TUIs and would double each API (ADR-0017); Table
  columns truncate rather than scroll sideways.
- **Grapheme-cluster editing.** TextArea edits by codepoint, exactly as
  `TextInput` does (ADR-0018) — combining marks and ZWJ emoji stay deferred,
  consistently across both editors.
- **Retained component tree, widget IDs, automatic focus management beyond the
  ring helper.** The `FocusRing` helper is sugar over the caller-owned switch; it
  is the *only* focus automation, and it introduces no registry, identity, or
  framework loop (ADR-0018's line).
- **Table cell editing, column sorting, column filtering.** Table is a read-only
  data grid: selection + scroll only. Editing/sorting/filtering are caller logic
  on top (re-pass sorted/filtered rows each frame), not widget features.

## Consequences

- **One shared scroll helper.** `scrollFor` (already in `input.zig`) is promoted
  from `Select`-private to a helper `Select` and `Table` both call — the
  single persistent-scroll rule, defined once.
- **One or two new `terminal.Key` variants** (`.pageup`/`.pagedown`), the arc's
  only change outside `packages/ui` — the same kind of small, justified
  parser addition ADR-0018 made for `.back_tab`. Fallback: `Ctrl-U`/`Ctrl-D`.
- **No renderer, `measure`, `Node`, or `RenderCtx` change.** Every new widget is
  either a plain builder composition (Tabs) or a `custom` leaf (Table, TextArea) —
  the escape hatch ADR-0013 reserved and ADR-0017/0018/0019 have used four times.
  The layout core stays theme-free and styles stay plain data (ADR-0020).
- **The catalog covers data display, paging, and multi-line input** after this
  arc — the three gaps a TUI evaluator hits — with the focus ring removing the
  boilerplate that made large forms tedious and the scrollbar giving `viewport`
  the affordance it lacked. Further work would be new widgets, not gaps in these.
