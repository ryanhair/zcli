# Theme system: one app-level theme applied everywhere

Status: accepted

The `theme` package started as a text styler: a fluent API (`.red().bold()`),
terminal capability detection, and a set of semantic roles (`success`,
`command`, `flag`, ...) — but the palette behind those roles was hardcoded.
`SemanticPalette` was a customizable struct that nothing accepted; the fluent
API and the markdown formatter both resolved roles through a private default.
Meanwhile prompts hardcoded its own ANSI colors (with no NO_COLOR support) and
progress hardcoded `.ansi_16`. A CLI author had no way to say "my app's brand
color is amber" and have help, prompts, and their own output follow.

## Decision

**A CLI declares one `Theme`, and every render path resolves through it.**

The token hierarchy follows design-system practice:

- **`Palette`** maps every semantic role to a complete `Style` — color *and*
  attributes (errors are bold, links italic, muted is dim). The palette field
  defaults are the single source of truth for the default look.
- **`StyleRef`** is either a role reference or a literal style. Component
  tokens — `PromptTheme` (cursor, selected, marker, hint) and `ProgressTheme`
  (spinner, bar fill/empty) — default to role references, so one palette edit
  flows through every component, while any single token can still be pinned.
- **`Theme`** aggregates `{ palette, prompts, progress }`. **`ThemeContext`**
  pairs a `*const Theme` with detected `Capabilities` (the struct previously
  misnamed `Theme`) and is the one value render paths consume: it answers both
  "what does this role look like" and "what can this terminal display".

**Apps declare the theme in their root source file**, the `std_options` idiom:

```zig
pub const zcli_theme: zcli.Theme = .{
    .palette = .{ .command = .{ .foreground = .{ .rgb = .{ .r = 255, .g = 179, .b = 71 } } } },
};
```

`zcli.appTheme()` resolves it via `@import("root")` + `@hasDecl` with a default
fallback. This needs no build wiring and no codegen serialization, and the
theme is comptime-known — which preserves the zero-runtime-cost help pipeline:
the help plugin hands the app's palette to the markdown formatter, which still
compiles all four capability variants (no_color/16/256/truecolor) of every
format string at comptime and selects one at runtime.

**Semantic styling is resolved at render time, not at tag time.** The fluent
API's `.success()` only tags a role; `render(writer, ctx)` resolves the role
through the active palette and merges any explicit fluent settings on top
(explicit settings win regardless of chain order). This is what makes a custom
palette apply to code written before the theme existed.

## Consequences

- Help output is themed by the app palette (section headers render via the
  `header` role; command/flag/argument names via their roles). Verified e2e:
  a scaffolded project with a root `zcli_theme` renders help under a PTY in
  the custom color, stays plain when piped, and honors NO_COLOR.
- Prompts and progress adopt their component tokens in follow-up changes;
  the schema ships with the Theme so the contract is stable.
- Runtime theme *switching* (config file, `--theme` flag) is deliberately out
  of scope: a comptime theme is what keeps help compilation zero-cost. If
  demand appears, help rendering can move to the runtime formatting path.
- Light/dark background adaptation (OSC 11) is future work; the palette
  defaults assume a dark background, except `header`, which is attribute-only
  (bold, no color) so it stays readable on any background.
- The roles `primary`/`secondary` were dropped (unused, ambiguous); `accent`
  is the brand hook component tokens reference by default.
