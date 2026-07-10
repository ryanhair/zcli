# Focusable widgets: state structs with `view` + `handle`, caller-owned focus

Status: accepted

> Increment 1 of the widget library: the focus/routing model plus `TextInput`
> and `Checkbox`. `Select` and a `Button` are follow-ups on the same contract.
>
> **Increment 2 (landed): `Select`.** A single-select scrollable list on the
> same `view`/`handle`/`consumed` contract — it holds `highlighted` + a
> persistent `scroll`, consumes ↑/↓/Home/End, and bubbles Enter/Tab/Esc (the
> caller reads `options[select.highlighted]`). One refinement to the plan below:
> `Select` **renders its own visible window directly rather than wrapping a
> `viewport`.** It already computes which slice is visible (to place the
> highlight and scroll it into view), so re-rendering every option into a
> viewport's scratch surface would be wasted work; the `viewport` is the right
> tool only once options become multi-line (deferred). Options are single-line;
> overflow indicators (a dim ↑/↓) are the next small follow-up.
>
> **Increment 3 (landed): `Button`.** A stateless action control (`[ Label ]`)
> activated by Enter/Space. Being stateless (a terminal has no key-up, so no
> "pressed" phase), its `handle` returns whether the key *activated* it — the
> same routing role as the editors' `consumed` (`true` = "this key is mine, not
> navigation"), but for an action widget "mine" means "fired." The caller runs
> the action on a `true` return in its focus arm. This is why a `Button` can't
> share the editors' routing arm in the form example: an editor's consumed key
> *invalidates* a prior submit, whereas the button's *is* the submit.
>
> **Increment 4 (landed): `Select` polish — truncation + overflow arrows.** Long
> option labels now truncate with `…` (the widest option sets a fixed label
> column, so the width doesn't jitter as you scroll, and truncation only bites
> when the granted width can't hold it). A dim ↑/↓ shows in a 1-cell right gutter
> when options are hidden above/below the window (`↕` when a one-row window has
> both). This diverges from `prompts`, which omits arrows — justified because a
> `Select` is *embedded* in a larger full-screen UI, where "this scrolls" isn't
> obvious. The gutter is a fixed-width column (`row{ label(len), gutter(len 1) }`)
> rather than a `fill` label, so the row still measures to its intrinsic width.
> Deferred: full multi-line/wrapped options (a physical-row windowing rewrite,
> like `prompts`' `list_render` — no full-screen consumer needs it yet).
>
> **Increment 5 (landed): `Select` multi-line / wrapped options.** Opt in with
> `wrap = true`: options that overflow the field wrap to several physical rows
> (a hang indent under the label — the continuation lines' marker cells stay
> blank), and `height` becomes a *physical-row budget*. The visible window is
> chosen by growing *whole options* out from the cursor until the budget is used
> (`growWindow`, the ui-side mirror of `prompts`' `list_render.viewport`), so the
> wrap path is cursor-anchored like a `prompts` list rather than persistent-scroll
> like the single-line path. That difference is forced, not chosen: persistent
> scroll needs each option's wrapped height, which needs the granted width, which
> `handle` never sees — so `handle` is unchanged and the wrap window derives from
> `highlighted` alone each frame. Rendered by a custom leaf (`WrapSelectView`),
> because only a leaf's `renderFn` learns the width `view` can't; this reverses
> increment 4's "render own window, skip the scratch surface" rationale, which
> was explicitly premised on single-line (row index == option index). Overflow
> arrows carry over in physical-row terms (↑ on the first painted row, ↓ on the
> last, `↕` when the whole window is one row). The single-line path — truncation,
> persistent scroll, arrows — is untouched; `wrap` defaults to `false`. The one
> genuinely reusable primitive (paint-to-scratch → copy a visible row slice) was
> already factored out as `Region.copyRows` (ADR-0017); `viewport` and this leaf
> are two thin peers over it, so `viewport` is left alone rather than overloaded
> with cursor-following list logic for an audience of one.

ADR-0013/0015 named a focusable widget library as a clean deferral. This is the
first increment, and it settles the one hard question: how do interactive,
*stateful* widgets live on an engine that is deliberately immediate-mode
(stateless nodes, caller-owned state, tree rebuilt every frame, "a thin event
source, not a framework loop" — ADR-0015 §3).

## Decision: a widget is a state struct with `view` + `handle`

A widget is a plain struct the caller embeds in its own `State`. Two methods, by
convention (not an enforced interface):

- `view(self, a, opts) !Node` — render from current state; `opts.focused` tells
  it to draw its caret/highlight. Immediate: it returns a `Node` like any
  component.
- `handle(self, key) bool` — mutate state on a key, returning whether it was
  **consumed**.

That bool is the entire routing model. A widget eats the keys it uses (a
`TextInput` eats char/←/→/Backspace/Home/End) and lets the rest bubble. The loop
gives the focused widget first crack, and treats an *unconsumed* key as
form-level navigation:

```zig
const consumed = switch (state.focus) {
    .user => state.user.handle(key),
    .pass => state.pass.handle(key),
    .remember => state.remember.handle(key),
};
if (consumed) return .keep;
switch (key) {                                   // unconsumed → navigation
    .tab      => state.focus = ui.widgets.focusNext(Field, state.focus),
    .back_tab => state.focus = ui.widgets.focusPrev(Field, state.focus),
    .enter    => submit(state),
    .escape   => return .quit,
    else => {},
}
```

State stays caller-owned (the widget is a field in `State`), rendering stays
immediate, behavior is a pure `handle`. No retained widget tree, no ID store, no
framework loop — the loop is still the plain `App.run`.

**Rejected:** an ImGui-style immediate-mode ID store (a retained context + ID
management — a different paradigm) and a retained widget tree that owns
focus/routing (a framework loop, against ADR-0015 §3).

## Focus is caller-owned; the library adds only a ring helper

Focus is a value the app owns — here a `Field` enum. Routing is an explicit
`switch`, inherent to heterogeneous, type-safe widgets (no dynamic dispatch, no
IDs). The library contributes only `focusNext`/`focusPrev` (wrap-around over the
app's focus enum). A library-managed focus *registry* would need widget
identity — exactly what this avoids.

## Consequences and scoped-out edges

- **Shift-Tab needed a terminal change.** `terminal`'s `Key` had no Shift-Tab
  (and non-char keys carry no modifiers), so a `.back_tab` variant was added to
  the parser (recognizing `CSI Z`). It is the one change outside `packages/ui`,
  and reverse focus navigation is standard form UX.
- **The caret is a styled cell, not the hardware cursor.** Showing the real
  cursor would require a focused widget to know its own laid-out screen position
  — the same "layout doesn't expose measured positions" gap that blocks anchored
  popups. The caret is a reverse-video cell instead (pure surface content). A
  hardware cursor is a future enhancement bundled with that position-feedback
  work.
- **Editing is codepoint-granular.** Insert/Backspace/Delete/←/→ operate on whole
  UTF-8 codepoints over a caller-provided buffer (allocation-free; capacity is
  the caller's). Full grapheme-cluster editing (combining marks, ZWJ emoji) is a
  later refinement.
- **Keyboard only.** Click-to-focus and click-to-position-caret need hit-testing
  (map (x,y) → widget), which again needs exposed widget rects. Deferred with the
  same position-feedback dependency.
- **Shared theme with `prompts`.** Widgets style through the existing
  `PromptTheme` tokens (cursor/selected/marker/hint). `prompts` is the
  cooked-mode, one-shot, line-oriented interactive layer; this widget library is
  its full-screen, persistent, node-tree counterpart. They are parallel and
  share the vocabulary — `prompts` is neither merged nor replaced.
- **Next:** the widget catalog now covers the common form controls
  (`TextInput`/`Checkbox`/`Select`/`Button`), with `Select` truncation + overflow
  arrows (increment 4) and multi-line/wrapped options (increment 5) both landed —
  the `Select` capability set is complete. Mouse click-to-focus and the hardware
  cursor also landed (ADR-0019). The library-wide deferrals that remained are
  closed; further work is new widgets, not gaps in the existing ones.
