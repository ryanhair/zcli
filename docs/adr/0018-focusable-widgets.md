# Focusable widgets: state structs with `view` + `handle`, caller-owned focus

Status: accepted

> Increment 1 of the widget library: the focus/routing model plus `TextInput`
> and `Checkbox`. `Select` (a list over a `viewport`) and a `Button` are
> follow-ups on the same contract.

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
- **Next:** `Select` (a list rendered inside a `viewport`, ADR-0017 — it owns
  `highlighted` + `scroll` and scrolls the selection into view) and a `Button`,
  both on this same `view`/`handle`/`consumed` contract.
