# Consistent construction across the core output packages

Status: accepted

Every package that writes to the terminal — `prompts`, `progress`, `markdown`,
`theme`, `ui` — needs some subset of the same five environment inputs: a
**writer**, a **reader**, an `std.Io`, an **allocator**, and a **theme**. Today
each package threads those inputs in a different way, so a CLI author learns a
new construction idiom for every capability:

- **`prompts`** is a value bundle — the import *is* the type. You fill
  `{ writer, reader, allocator, theme }` once and every prompt is a method that
  takes only its config. `context.prompts()` returns an instance pre-wired to
  the command's streams, allocator, and theme.
- **`progress`** is a pair of free functions, `progress.spinner(io, config)` /
  `progress.progressBar(io, config)`. The writer is a hidden thread-local
  stdout, `io` is re-passed on every call, and the theme lives *inside* the
  config. There is no `context.progress()`.
- **`markdown`** is a soup of free functions plus two formatter constructors
  (`formatter(writer)`, `capabilityFormatter(writer, capability)`) and their
  `*WithPalette` variants. The allocator is re-passed on every `print`. There is
  no `context.markdown()`.
- **`theme`** is a per-call fluent builder: `theme.styled(s).success().render(writer, &ctx)`.
- **`ui.App`** is a classic `init(gpa, writer, options)` / `deinit`, with the
  theme reduced to a bare `capability` enum in `Options`. There is no
  `context.ui()`.

Two independent inconsistencies are tangled here:

1. **How the environment is threaded.** Three unrelated idioms — value bundle
   (prompts), free-function-with-args (progress, markdown, theme), and
   init/deinit object (ui, vterm). progress hides its writer in a thread-local
   and re-threads `io` every call; markdown re-threads the allocator every
   `print`.
2. **How the theme is represented.** prompts and progress take a full
   `theme.ThemeContext`; `ui` takes a bare `TerminalCapability`; `markdown`
   takes a comptime `Palette` plus a runtime `TerminalCapability` as two
   separate arguments.

`context.prompts()` already proves the shape we want. This ADR generalizes it.

## Decision

**The command `Context` is the single front door for every output capability,
and the stateless output packages adopt the `prompts` value-bundle shape.**

### 1. `context.X()` is the universal front door

`Context` already holds all five environment inputs. It hands out a pre-wired
instance of each output capability, exactly as `context.prompts()` does today:

```zig
pub fn progress(self: *Self) zcli.Progress {
    return .{ .writer = self.stdout(), .io = self.io, .theme = self.theme };
}

pub fn markdown(self: *Self) zcli.Markdown {
    return .{ .writer = self.stdout(), .capability = self.theme.capability() };
}

pub fn ui(self: *Self, options: zcli.ui.App.Options) !zcli.ui.App {
    return zcli.ui.App.init(self.allocator, self.stdout(), options);
}
```

The mental model becomes uniform: *`context.X()` hands you a thing already wired
to this command's streams, io, allocator, and theme; standalone, you fill the
same fields yourself.*

`zcli` re-exports `ui` (`pub const ui = @import("ui")`) so `context.ui()` and
`zcli.ui.App.Options` resolve; today `ui` is not re-exported at all.

### 2. The factory packages become value bundles (the `prompts` shape)

`progress` and `markdown` are constructed by a lightweight value that just
captures the environment and hands out configured objects — no long-lived state
lives on the package root — so they take the same import-is-the-type form as
`prompts` (which likewise allocates on behalf of the objects it produces):

```zig
// progress — matches prompts exactly (import IS the type)
const Progress = @import("progress");
const p: Progress = .{ .writer = w, .io = io, .allocator = a, .theme = ctx };
var spinner = try p.spinner(.{ .style = .dots });   // was progress.spinner(a, io, .{ .style = .dots, .theme = ctx })
var bar = try p.progressBar(.{ .total = 100 });
var mb = try p.multiBar(.{});
```

The `Progress` bundle is a stateless *factory* over the environment; the
indicators it produces own heap state — since #170 each runs on a `ui.App`
(ADR-0013) — so they allocate, the methods return errors (`try`), and each
indicator has its own `deinit`/finish. The bundle therefore carries an
`allocator` too, making its field set identical to `Prompts` (minus `reader`).
This removes the thread-local stdout entirely, stops re-threading `allocator`,
`io`, and `theme` on every call, and drops `theme` out of the indicator configs
(it lives on the bundle, forwarded to each widget). `markdown` collapses
`formatter` / `capabilityFormatter` / `formatterWithPalette` /
`capabilityFormatterWithPalette` into one instance carrying `{ writer, capability }`.

Per the project's no-back-compat rule, the old shapes are removed, not
deprecated: the `progress.spinner`/`progressBar`/`multiBar` free functions, the
thread-local writer, and the four markdown formatter constructors go away.

### 3. Stateful packages keep `init`/`deinit`, but align their inputs

`ui.App` and `vterm.VTerm` own heap state (surfaces, scrollback), so they keep
`init`/`deinit` — a value bundle would be wrong for a resource that must be torn
down. What changes is only their *inputs*, so the environment set and its names
match everywhere: `App.Options.capability: TerminalCapability` becomes
`theme: ThemeContext`, and `App` reads `theme.capability()` where it currently
reads `capability`. `vterm` is a test-only terminal emulator and stays as-is
(it has no writer/theme to wire).

### 4. `markdown` keeps its comptime-palette / runtime-capability split

`markdown` does **not** become a runtime `ThemeContext` consumer. It bakes ANSI
sequences into format strings at comptime — that is the whole point of its
zero-runtime-cost design (ADR-0012). A `ThemeContext` is half comptime (the
`*const Theme` / palette) and half runtime (the detected `Capabilities`):

- The **palette** stays a comptime input — `const app_palette = zcli.appTheme().palette`
  is a comptime-known `const`, and markdown pre-compiles the format string
  against it.
- The **capability** stays runtime — the instance carries
  `capability: TerminalCapability` (from `context.theme.capability()`), and
  markdown selects among the four comptime-compiled variants at runtime, exactly
  as `CapabilityFormatter` does today.

So markdown's instance bundles `{ writer, capability }`, and the palette is
resolved at comptime from `appTheme()` rather than passed through the runtime
bundle. Its *construction shape* unifies with the others; its *resolution model*
is deliberately left unchanged. This is why the change is non-breaking: markdown
never consumed a runtime `ThemeContext`, so it loses nothing by not starting to.

### 5. `theme.styled` stays a per-call fluent builder

Stateless per-call styling is the right shape for `theme.styled`, so it is left
as is. Optionally, `context.styled("x")` can pre-bind `context.theme` and return
a `Styled` whose `.render(writer)` no longer needs the `&ctx` argument — a
convenience, not a required part of this decision.

## Considered Options

**Push everything through `context.X()` and drop the standalone shapes.**
Rejected: every package must stay usable standalone (a `prompts`/`progress` user
with no `zcli` dependency is a supported case, and the packages are published
independently). The value bundle is what makes both paths the same code —
`context.X()` just fills the fields the standalone user fills by hand.

**Make every package `init`/`deinit`, including progress and markdown.** Rejected:
these packages own no heap state; `init`/`deinit` would invent a lifecycle where
there is none and force `defer x.deinit()` on value types. `init`/`deinit` is
reserved for packages that genuinely own resources (`ui`, `vterm`).

**Make markdown a runtime `ThemeContext` consumer for full symmetry with
prompts/progress.** Rejected: it would force role→ANSI resolution to runtime and
delete the comptime-baked, zero-overhead help/format pipeline (ADR-0012) for
cosmetic uniformity. Construction-shape symmetry is worth having; resolution-model
symmetry is not.

## Consequences

- One construction idiom to learn. `context.X()` is the front door for prompts,
  progress, markdown, and ui alike; standalone use fills the same fields.
- The `progress` thread-local stdout — a real wart — is removed, and call sites
  stop re-passing `allocator`/`io`/`theme`. markdown call sites stop re-passing
  the allocator.
- Breaking changes across the board (intended): every `progress.spinner`/
  `progressBar`/`multiBar` call site, every markdown formatter construction, and
  `ui.App.Options.capability` are rewritten. Examples, `projects/zcli`, and the
  `zcli_help` plugin are the known call sites.
- `progress` reshaped on top of its ui-engine rewrite (#170): the bundle wraps
  the same `Spinner`/`ProgressBar`/`MultiBar` and forwards the environment to
  each `ui.App`. The engine rewrite and this construction reshape are orthogonal
  and compose cleanly.
- Naturally sequenced as one PR per package (progress, markdown + help-plugin,
  ui-context + `zcli.ui` re-export, optional `context.styled`), each shippable
  on its own.
- `markdown`'s comptime coloring is untouched, so the change carries no
  rendering-behavior risk for the help pipeline.
- `terminal` (low-level primitives) and `vterm` (test emulator) stay outside the
  idiom by design; forcing them in would be miscategorization, not consistency.
