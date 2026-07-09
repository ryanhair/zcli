# Full-screen mode: opt-in alt-screen TUI on the same layout engine

Status: accepted

> Shipped across PRs #180 (steps 1/2/4), #181 (deadline-scheduled tick), and
> #182 (step 3 teardown). One deviation from the text below: there is no
> generated `main.zig` (apps author their own entry point), so the panic hook
> ships as a one-line opt-in — `pub const panic = zcli.ui.panic;` — enforced at
> compile time for full-screen apps via `App.initFullScreen`, rather than
> emitted by codegen. `mode` also became a constructor split
> (`init`/`initFullScreen`, `context.ui`/`context.uiFullScreen`) instead of a
> runtime `Options.mode` flag, to make that compile-time check possible.

The layout engine (ADR-0013) was built CLI-first: a static stream flowing into
scrollback plus a live region pinned above it. But the engine that paints the
live region is already a general terminal UI core — measure/render over
box/text/spacer/custom, `fit`/`len`/`fill` sizing, a cell surface, a diff
renderer, capability-aware styling. Sizing a root `fill` already stretches a
frame to the whole viewport (`app.zig`), so the engine *already paints a full
screen*. What it does not yet do is **take the screen over** (leave the user's
shell untouched underneath, restored on exit) or **read input** — the two things
that separate "a live frame that happens to fill the terminal" from "a TUI."

ADR-0013 anticipated this exactly: it names full-screen as "a root box with
`height = fill` (plus alt-screen), and the static stream simply goes unused," and
lists "focus management and event routing (a layer above the tree)" among the
non-goals with clean later homes. This ADR cashes in those two parentheticals.
The goal is deliberately narrow: **the smallest increment that makes "zcli.ui is
a TUI too" true**, reusing the layout/measure/render/diff core *unchanged*. It is
not an attempt to reach ratatui/libvaxis parity — that is the long tail of
overlays, mouse, scroll viewports, and a focusable widget library, all left for
later and none of which this increment forecloses.

## Decision

**Add an opt-in full-screen mode to `App` and a thin input-driven event source,
reusing the existing layout engine with no changes to `node`/`measure`/`render`.
Full-screen is a mode flag, not a fork.**

### 1. Full-screen is a mode, not a second engine

`App.Options` gains `mode: enum { hybrid, full_screen } = .hybrid`, and
`context.ui()` gains an options parameter to select it. In `full_screen`:

- **Enter/exit the alternate screen buffer** (`DECSET ?1049h` on `init`,
  `?1049l` on `deinit`). The shell's screen *and its scrollback* are saved on
  enter and restored on exit — the whole point, and the thing that distinguishes
  this from the hybrid's share-the-screen model (ADR-0013).
- **The static stream goes unused.** There is no scrollback to flow into, so
  `emit` is a runtime error in full-screen mode: the frame *is* the whole
  screen. (Mode is a runtime option, so this cannot be a compile error without
  forking the type — see Considered Options.) No row reservation (the
  alt-screen buffer starts blank), and no held-back row — the frame is granted
  the full viewport height, not `height − 1`.
- **The root is granted the whole viewport.** A full-screen app sizes its root
  `width = fill, height = fill`; the mode grants the full terminal rect as the
  measure `Limits`. Everything below the root is the same layout protocol as the
  hybrid live region.

Everything else — the arena-per-frame discipline, the diff renderer, synchronized
output, capability degradation — is identical. This is the load-bearing claim of
the ADR: full-screen reuses the engine, it does not reimplement it.

### 2. Relative addressing still works; the App re-anchors, absolute `CUP` stays deferred

The diff renderer addresses cells relative to the frame's top-left, never with
absolute `CUP` (`diff.zig`); its contract is that the caller parks the cursor at
the region's top-left between paints. Full-screen keeps that contract but must
do the parking explicitly at two moments the hybrid never faces:

- **On entry.** `?1049h` clears the alt buffer but does *not* home the cursor —
  its position carries over from the main screen. The App anchors to the origin
  before the first paint.
- **After a resize.** Terminals move or clamp the cursor arbitrarily when the
  window resizes, so the parked position is invalidated; the App re-anchors and
  forces a full repaint (`front_valid = false`) before the next diff.

Both are one relative sequence — `CR` plus a viewport-height `CUU`, which clamps
at the top row — so the renderer stays CUP-free and shared byte-for-byte between
the two modes. Absolute addressing buys two things — cheap out-of-flow drawing
(overlays/popups) and resync-from-anywhere robustness — and both belong to
features deferred below.

### 3. A thin event source, not a framework loop

The `terminal` package already has every input primitive: raw mode, `readEvent`
(keys + SIGWINCH resize), the `Key` union, lone-Esc disambiguation. `prompts`
already drives a read→re-render loop with them. Full-screen mode generalizes the
*ownership*, not the mechanism: the `App` enables raw mode for the session (not
per-widget) and exposes

```zig
pub fn nextEvent(self: *App, timeout_ms: ?u32) !?Event   // key | resize (| mouse, later)
```

`null` blocks indefinitely; a timeout returns `null` when it expires, which is
what lets an app repaint on a tick with no input — a `top`-style refresh is
`nextEvent(250) orelse continue`, not a background thread. (The plumbing already
exists: `waitReadable` takes a timeout and the resize watcher polls on an
interval.) `nextEvent` flushes the App's writer before blocking — the
flush-before-read discipline `prompts` already learned, enforced in one place.

The caller writes its own loop and `view`, consistent with ADR-0013's "state
stays with the user" — the same reason ticks and selection indices already live
in caller structs:

```zig
var app = try context.ui(.{ .mode = .full_screen });
defer app.deinit();                     // leaves alt-screen, cooked mode, cursor shown
while (running) {
    try app.frame(try view(app.arena(), &state));
    const ev = try app.nextEvent(250) orelse {
        tick(&state);                   // timeout: animate, refresh stats
        continue;
    };
    switch (ev) {
        .key => |k| update(&state, k),  // caller owns state + focus routing;
                                        // Ctrl-C arrives HERE, as a key (choice 5)
        .resize => {},                  // next frame re-anchors and re-measures
    }
}
```

We deliberately do **not** ship an Elm-style `app.run(state, update, view)`
driver in this increment. It is pure sugar over the loop above and can be added
later without changing anything here; leading with the explicit loop keeps the
immediate-mode model honest and the surface minimal.

### 4. Resize is *simpler* full-screen than hybrid

The hybrid's three-tier resize (ADR-0013) exists because it shares the screen
with scrollback it cannot reflow. Full-screen owns the whole buffer, so a resize
is just: re-anchor the cursor (choice 2), re-measure the root against the new
viewport, and repaint the frame in full. There is no tail to retain, no
scrollback seam, no reflow-duplication artifact — the entire tier-2/tier-3
apparatus is inapplicable. A `fill`×`fill` root measures to the new viewport, so
the size change alone already forces the full repaint; the re-anchor is the one
resize-specific step, because the parked cursor is the only state the terminal
can silently invalidate.

### 5. Teardown: who catches what

In the hybrid, a botched exit leaves the cursor hidden — annoying. In
full-screen, a botched exit strands the user *inside the alternate screen, in raw
mode, with no cursor* — a wedged terminal needing `reset`. So full-screen makes
robust teardown a **requirement**, not the optional cleanup noted as an open
thread against the hybrid. There are three distinct exit paths, and they are
caught by three different mechanisms:

- **Ctrl-C is a key, not a signal.** Raw mode clears `ISIG` (POSIX) /
  `ENABLE_PROCESSED_INPUT` (Windows), so during a full-screen session Ctrl-C
  arrives as a `.key` event through `nextEvent`. The common interrupt path is
  therefore the ordinary one: the caller's loop exits and `deinit` restores in
  strict reverse order (show cursor → leave alt-screen → disable raw mode). No
  handler is involved, and no framework policy either — whether Ctrl-C quits,
  cancels, or is ignored is the caller's `update`.
- **Signal handlers cover external termination only** — `SIGTERM`/`SIGINT` from
  a `kill`, and the console-ctrl/close events via `SetConsoleCtrlHandler` on
  Windows. The handler must be async-signal-safe: it cannot touch the App's
  buffered writer or any allocator. Restore state lives in a process global
  (the pattern the SIGWINCH watcher's `resize_pending` already uses) — the
  saved termios/console modes plus a precomputed restore escape string, written
  with a raw `write(2)` to the tty before the process dies.
- **Panics restore via the root module, because Zig has no runtime panic hook.**
  Panic handling is a root-module declaration, so `packages/ui` cannot install
  it. zcli owns the generated entry point, so the framework emits a panic
  wrapper in generated `main.zig` that runs the same global restore before the
  default handler prints (a small codegen change in `core`, part of this
  increment). Standalone consumers of `packages/ui` outside a zcli app declare
  it themselves; `ui` exports the restore function to make that one line.

The same global restore closes the standing cleanup gap for the hybrid too:
there, cooked mode means Ctrl-C *is* `SIGINT`, and the hybrid's restore is the
alt-screen restore minus one step.

## Considered Options

- **Keep pointing full-screen users at libvaxis / ratatui-in-Zig.** The honest
  status quo, and still the right answer for a heavy full-screen app with rich
  widgets. Rejected as the *only* answer: the engine already paints a full
  viewport, so the gap to a usable TUI is a mode flag and an event source, not a
  second dependency with its own layout model and authoring weight. A zcli author
  writing a `top`-style or wizard-style screen should not have to leave the
  framework and relearn a widget tree.
- **A separate `FullScreenApp` type instead of a mode flag.** A distinct type
  would make `emit` unrepresentable at compile time rather than a runtime error.
  Rejected: it forks the API surface the mode-flag bet exists to keep whole —
  every component function, test harness, and doc would need to speak both
  types to save one runtime check on a method full-screen code has no reason to
  call.
- **Do the absolute-addressing renderer rewrite now.** Deferred: relative
  addressing already paints a correct full screen (with the App-level re-anchor
  of choice 2), so absolute `CUP` is only required by the deferred features
  (overlays, resync). Rewriting the renderer before there is a consumer for it
  is speculative and would fork the one paint path the engine exists to unify.
- **Ship a retained focus/event-routing system and a widget library now.**
  Rejected for this increment: focus is state, and ADR-0013's immediate-mode bet
  is that state lives with the caller — a `top` clone or a form routes keys to
  the "focused" pane by holding an index in its own struct, exactly like a
  spinner holds a tick. A framework focus layer, overlays, and a widget catalog
  are real work with clean later homes (below); none is needed to *be* a TUI.
- **An Elm/Ink `run(update, view)` driver as the primary API.** Deferred to
  optional sugar (choice 3): opinionated about your main loop and state
  threading, and easy to add on top of `nextEvent` once the loop shape has proven
  out in real use.
- **A blocking-only `nextEvent`, ticks via a timer thread.** Rejected: the
  first real consumer (the `top`-style example below) needs a tick, and a
  thread-plus-wakeup apparatus to deliver one is strictly more machinery than a
  timeout parameter on a poll that already has one internally.
- **Do nothing — hybrid only.** Rejected: "how far from a full TUI?" is a
  recurring question precisely because the engine looks like it should already do
  it. The distance is small enough that leaving it unbuilt is a gap, not a
  boundary.

## Consequences

- **One engine, two modes.** `node`/`measure`/`render`/`diff` are untouched;
  full-screen is `Options.mode` plus alt-screen enter/exit, dropped row
  reservation, full-height limits, the entry/resize re-anchor, session-owned raw
  mode, and `nextEvent`. The mode flag and event source are small — the layout
  half already ships. The real work is teardown: an async-signal-safe restore
  path on two platforms plus the panic hook in generated `main.zig`, and that is
  where the estimate should be spent.
- **`context.ui()` gains an options parameter** (it currently takes none) —
  a breaking signature change, per project policy. The `app.zig` comment claiming
  full-screen "is not a separate mode" is updated to point here.
- **`emit` is unavailable in full-screen mode.** There is no scrollback to
  receive it; calling it is a runtime error. Code that wants both a scrollback
  log and a live frame is, by definition, the hybrid — use `.hybrid`.
- **The final frame does not persist.** Leaving the alt-screen restores the
  shell exactly as it was — that is the feature — so full-screen `deinit`
  inherently discards the last frame, where hybrid `deinit` leaves it visible in
  scrollback. An app with a parting summary prints it *after* `deinit`, onto the
  restored main screen.
- **Full-screen requires an interactive TTY.** Unlike the hybrid, which degrades
  to plain lines when piped, a TUI into a pipe is meaningless; constructing a
  `full_screen` App on a non-TTY is an error, surfaced at `init`.
- **Teardown state becomes a process global.** The signal/panic restore path
  cannot reach instance state, so the saved terminal modes live in a global
  singleton — same modality assumption the SIGWINCH watcher already makes (one
  active session at a time).
- **Windows/ConPTY.** Alt-screen (`?1049`) and raw mode already work through the
  virtual-terminal console path the terminal package relies on; the existing
  ConPTY e2e harness covers interactive input, and the `vterm` cell model gives
  golden-frame tests for full-screen frames exactly as for the live region.
  External-termination cleanup uses `SetConsoleCtrlHandler` rather than POSIX
  signals; the resize watcher's 60ms size poll becomes session-long in a
  full-screen app, which is negligible.
- **Still explicitly deferred, with the same clean homes ADR-0013 named:** mouse
  and focus/paste events (join `Event`; `event.zig` already reserves the spot),
  overlays / z-layers (a fifth node variant or an absolute-addressed overlay
  pass), scrollable viewports (a `custom` leaf first, a first-class node if it
  earns it), and a focusable widget library (component functions and `custom`
  leaves, grown as consumers appear). None forces a core redesign; none is
  blocked by this increment; each is a follow-up ADR when a real consumer needs
  it.
- **Build order:** (1) `Options.mode` + alt-screen enter/exit + entry anchor +
  full-viewport limits + `emit`/non-TTY guards; (2) session-owned raw mode +
  `nextEvent` (timeout, flush-before-read) wrapping `readEvent`, + the resize
  re-anchor; (3) the global restore state + signal/ctrl handlers + the panic
  hook in generated `main.zig`, shared with the hybrid; (4) a runnable
  full-screen example (a `top`-style live table on a `nextEvent(250)` tick) to
  validate the loop shape before considering `run()` sugar.
