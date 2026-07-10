# Theme-derived style defaults: set once, derive everywhere

Status: accepted

ADR-0012 gave a CLI one `Theme`, declared once in the app's root source file
(`pub const zcli_theme`), and the line-oriented render paths follow it: help,
prompts, and progress all resolve through the app theme with no per-call
plumbing. The `ui` package does not. Its widgets default to `&default_theme` —
the one theme guaranteed to ignore the app's declaration — and its box chrome
takes literal `Style` values, so every panel repeats the same incantation:

```zig
const th: ui.widgets.Theme = .{};          // the DEFAULT, not the app theme
...
.border_style = th.surface.border.resolve(th.palette),
.style = th.surface.panel.resolve(th.palette),
```

Four of the five `ui` examples carry this verbatim. ADR-0012 blessed the
pattern as a consequence ("the `ui` core is untouched — callers resolve a token
and assign it"), but it fails the design system's own premise: an app sets a
theme once, and components derive their look *by default*, with styles never
required at a call site. This ADR revises that consequence.

The obvious fix — thread the theme through `App` into `RenderCtx` — does not
work without damaging the core. Widget `view()` functions and the `ui` builders
run at **tree-build time**; `RenderCtx` exists only inside `frame()`, during
measure/render. Reaching it would mean either nodes carrying unresolved
`StyleRef`s that the core resolves at render (the core learns about themes,
styles stop being plain data) or every themed widget becoming a `custom` leaf.
Both trade the engine's simplicity for a default.

The mechanism ADR-0012 already built is the answer: the theme is
**comptime-known** via the root declaration. Every *default value* in every
package can reach it directly — no threading, no runtime channel, no core
change.

## Decision

**Style parameters are never required. Every styling default derives from the
app theme (`zcli_theme`, falling back to `default_theme`), resolved where the
default is declared — in builders and widget option structs at build time,
never in the layout core.**

1. **`appTheme()` moves into the `theme` package** (zcli re-exports it). The
   `@import("root")` + `@hasDecl` lookup is the `std_options` idiom ADR-0012
   established; hosting it in `theme` lets `ui`, `prompts`, and `progress`
   use it as a default without depending on zcli.

2. **`ThemeContext.theme` defaults to `appTheme()`** instead of
   `&default_theme`. Any context built without an explicit theme — including
   `ThemeContext.fallback`, the standalone default for `prompts` and
   `progress` instances — follows the app theme automatically.

3. **Widget option defaults derive**: every `theme: *const Theme =
   &default_theme` in `ui.widgets` (`TextInput`, `Checkbox`, `Select`,
   `Button`, `spinner`, `bar`, `multiBar`) becomes `= appTheme()`. A custom
   `zcli_theme` now flows into every widget with zero call-site changes; the
   per-call `theme` override remains for tests and special cases.

4. **Borders derive by default.** `BoxOpts.border_style` becomes `?Style =
   null`; the `ui.box` builder resolves `null` to `surface.border` through the
   app palette. An explicit value — including `.{}` for a plain border —
   overrides. `Node.Box.border_style` stays a plain `Style`: resolution
   happens in the builder, so the core (node/surface/diff, `RenderCtx`)
   remains theme-free.

5. **`ui.panel` is the opaque themed surface**: a box (default `.column`,
   `.rounded` border) whose background defaults to `surface.panel` and border
   to `surface.border`, every field overridable. Box *backgrounds* stay
   opt-in — deriving `Box.style` would make every box opaque and destroy
   ADR-0016's transparency rule (style-less box = transparent in stacks). The
   split stays crisp: boxes are layout (transparent by default), panels are
   chrome (opaque by declaration).

6. **`ui.role(.success)`** resolves a semantic role through the app palette —
   one word for themed text instead of a palette dance.

## Considered Options

- **Thread the theme through `App` into `RenderCtx`** — rejected: the theme
  would arrive after the styles are already resolved (build time vs render
  time, above), so it helps nothing unless the core also learns to resolve
  deferred styles. It would add a second, runtime channel for information the
  comptime channel already delivers to every call site for free. ADR-0013 §4
  reserved theme-in-`RenderCtx` as the `custom`-leaf escape hatch; it stays
  reserved for a future that actually needs runtime theming.
- **Nodes carry `StyleRef`, resolved at render** — rejected: the fullest
  version of "never required," but the core stops being
  styles-as-plain-data, `styleEql`/diffing complicate, and the simple case
  (`ui.text(.{ .bold = true }, …)`) gets syntactically worse. The entire pain
  lives in chrome (borders, panels), which options 4–5 cover without touching
  `Text`.
- **A `theme` field on `BoxOpts`/every builder** — rejected: that is the
  threading disease this ADR exists to cure, applied one level down.
- **Runtime-settable global theme** — rejected: ADR-0012 already ruled runtime
  switching out of scope (comptime themes are what keep help compilation
  zero-cost), and a mutable global buys races for no expressed need.

## Consequences

- **Behavior change: bordered boxes wear the themed border by default.**
  `surface.border` defaults to the `accent` role, so a bare `.border =
  .rounded` is now accent-colored where it was terminal-default. Golden tests
  updated accordingly; `.border_style = .{}` restores plain, and quiet-chrome
  apps set `zcli_theme.surface.border` once (e.g. to `.{ .style = .{ .dim =
  true } }`).
- The `const th: ui.widgets.Theme = .{};` + `resolve` boilerplate disappears
  from the examples; a panel with zero style mentions reskins entirely from
  the root declaration.
- Under `zig test` the root is the test runner, so `appTheme()` falls back to
  `default_theme` — package tests exercise the same defaults as before.
- One theme per binary, bound at comptime. A library component compiled into
  an app resolves the *app's* theme — the desired composition.
- The layout core is untouched: measure/render stay pure over `Limits`,
  styles stay plain data on nodes, transparency semantics (ADR-0016) are
  unchanged.
