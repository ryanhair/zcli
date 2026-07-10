# Roadmap to 1.0

This document exists to answer one question an evaluator has before adopting a
pre-1.0 framework: **can I build on this now, and what will break under me?**

The [CHANGELOG](CHANGELOG.md) is honest that "breaking changes may land in minor
versions" before 1.0. This page gives that policy a destination — what freezes at
1.0, what stays deliberately open, and what has to land first — so you can decide
whether to adopt today or wait.

It is a statement of *intent*, not a delivery contract. Dates and the exact
freeze list are the maintainer's calls; where this doc guesses ahead of a
decision it says so inline.

<!-- DECIDE: The whole document is a draft for the maintainer to ratify. Search for "DECIDE:" to find every open decision. -->

## 1. Where zcli is today

Current release: **v0.19.0** (Zig 0.16.0, Linux/macOS/Windows).

zcli is past the experimental stage. The parts an app is actually built *on* have
been stable across several releases and are exercised by the framework's own
meta-CLI (`zcli init/add/mv/rm/tree/dev/guide/release` are all zcli commands) and
by the CI-compiled canonical examples:

- **The command contract** — `meta` / `Args` / `Options` / `execute`, build-time
  filesystem discovery, comptime-checked argument parsing. Unchanged in shape
  since the foundation releases; the recent scaffolding tools (`add option/arg`,
  `mv`, `rm`) edit these files in place precisely *because* the contract is
  settled enough to splice mechanically.
- **The plugin system** — lifecycle hooks (`preExecute`, `onError`,
  `handleGlobalOption`), `global_options`, plugin-owned commands, and typed
  `context.plugins.<id>` data. Eight plugins ship in-box on this surface.
- **The testing tiers** — in-process unit tests against a real vterm emulator,
  subprocess integration tests, and an e2e/PTY harness. Releases are gated on the
  full suite, including native Windows.
- **CI on three OSes** — every commit builds and tests on Linux, macOS, and
  Windows (interactive e2e on Windows via a ConPTY backend). Actions are pinned
  to SHAs; releases are gated on green.
- **A completed UI/layout milestone** — the terminal-native layout engine
  (ADR-0013) and its widget/overlay/viewport/focus work (ADR-0016 through
  ADR-0020) landed the full-screen-TUI deferral list. The engine exists and the
  prompt/progress packages are built on it.

What is still genuinely in motion is called out in §2 and §3.

## 2. What "1.0" means

1.0 is a promise about *source compatibility*: code that compiles against 1.0
keeps compiling against every 1.x after it, with breaking changes reserved for
2.0. It is **not** a claim that the framework is "finished" — the UI catalog and
the plugin set will keep growing under 1.x, additively.

The line below is what we're proposing to draw. The specific membership is a
maintainer decision.

<!-- DECIDE: Confirm the two lists below — every surface here is a promise you'll owe under semver once 1.0 ships. Anything you're unsure about should move to "stays unstable" rather than be over-promised. -->

### Freezes at 1.0 (breaking changes ⇒ 2.0)

- **The command contract.** The `meta` block's recognized keys, the `Args` /
  `Options` struct conventions (types, `nullable`, `multiple`/variadic,
  short-flag derivation, defaults), and the `execute(args, options, context)`
  signature.
- **The `context` surface used inside `execute`.** The documented accessors —
  `context.stdout()` / `stderr()`, `context.io`, `context.prompts()`,
  `context.progress()`, `context.ui()`, `context.theme`, `context.plugins.<id>`,
  `context.fail()`, and the arena allocator. <!-- DECIDE: `context.io` is `std.Io`, whose stability is coupled to Zig's std — see the Zig-coupling note in §4. Decide whether to freeze the *accessor names* only, and explicitly exclude the shape of Zig std types they return. -->
- **The `build.zig` integration API.** The `zcli.generate()`, `generateDocs()`,
  and `addCommandTests()` signatures and their typed config structs;
  `zcli.builtin(...)`; `zcli.option(...)`.
- **Plugin hook signatures.** `plugin_id`, `ContextData`, `global_options`,
  `handleGlobalOption`, `preExecute`, `onError`, and the plugin-command
  convention — the contract a third-party plugin is written against.
- **Package names and the public module surface.** The post-rename package set
  (`core`, `prompts`, `progress`, `theme`, `markdown`, `terminal`, `vterm`,
  `testing`/`zcli-testing`, `ui`) and the top-level `zcli` re-exports. The
  rename churn (0.18: `zinput→prompts`, `zprogress→progress`, `ztheme→theme`,
  `markdown_fmt→markdown`) happened *before* 1.0 deliberately, so these names
  are the ones that freeze.
- **The dual-tag release scheme.** `vX.Y.Z` (library) + `zcli-vX.Y.Z` (CLI
  binaries) in lockstep.

### Stays versioned-but-unstable under 1.x (additive, may change)

These grow and evolve under 1.x; changes are announced in the CHANGELOG but do
**not** wait for a major bump. Betting on zcli's *core* doesn't require betting
these are final.

- **The `ui` widget catalog.** New widgets, new options on existing widgets, and
  layout-engine internals. The Select/TextInput/Button/etc. catalog is declared
  "capability-complete" for common forms (ADR-0018), but the surface is expected
  to keep gaining leaves and knobs. <!-- DECIDE: If you want any UI primitive frozen at 1.0 (e.g. the `ui.box`/`ui.text`/`ui.column` node API vs. the widget catalog), split it out into the frozen list above. Recommendation: freeze the *node/layout primitives*, keep the *widget catalog* open. -->
- **New plugins and new options on existing plugins.** Adding a plugin, or adding
  a field to a plugin's `ContextData`/config, is additive.
- **Theme tokens.** New semantic roles and component tokens (ADR-0012/0020).
  Existing role *names* are part of the frozen theme API; the set grows.
- **The meta-CLI's own commands and their flags.** `zcli add/mv/rm/dev/guide/…`
  are developer tooling, versioned with `zcli-vX.Y.Z`; their UX can change more
  freely than the library API an app compiles against. <!-- DECIDE: Confirm the meta-CLI is intentionally held to a looser bar than the library. It's the defensible split, but say so out loud. -->
- **Generated doc-site HTML/CSS.** Cosmetic output, not an API.

## 3. What must land before 1.0

Derived from [TODOS.md](TODOS.md) and the CHANGELOG. This is deliberately short:
1.0 is a *stability* declaration, not a feature gate, so the bar for an item here
is "shipping this after 1.0 would be a breaking change or an integrity gap we'd
regret freezing around."

<!-- DECIDE: This is the highest-value section to edit. Move items between "blocks 1.0" and "explicitly deferred past 1.0" per your judgment. Everything here is sourced from TODOS.md + CHANGELOG; none of it is invented scope. -->

**Recommended blockers (do before 1.0):**

- **Land the current `Unreleased` breaking changes and let them settle.** The
  progress/prompts instance-API rebuild (ADR-0014) and the `zcli.ui` engine are
  in `Unreleased`. These are the last *known* breaking changes to the surfaces
  §2 proposes to freeze — 1.0 should ship *after* they've had at least one
  released minor to shake out. <!-- DECIDE: cut a 0.20 (or 0.19.x) that releases the Unreleased block, adopt it in the examples + meta-CLI, then freeze. -->
- **A final API sweep of the freeze list in §2.** One pass to rename/remove
  anything awkward *while it's still free* — the project's stated preference is
  "never prioritize backwards compatibility pre-1.0; make the cleanest choice."
  1.0 is the deadline for that preference.
- **Release integrity: sign `checksums.txt`** (TODOS "Sign releases",
  ADR-0009). The trigger the ADR names — "a third-party install base emerges" —
  *is* 1.0. Freezing the install/upgrade path without publisher-level integrity
  is the one security gap worth closing before inviting adoption. <!-- DECIDE: Blocker or fast-follow? Recommendation: blocker, because 1.0 is the adoption invitation and this defends the invitees. Effort is M per TODOS. -->

**Recommended NON-blockers (fine to defer past 1.0 — all additive or internal):**

- **Split the unit-testing tier out of `testing`** (TODOS). Internal dependency
  hygiene; a module split can happen in any 1.x without breaking the public
  `zcli-testing` API.
- **Un-bundle the TUI libraries from the public surface** (TODOS "Deferred").
  Explicitly parked pending adoption signal — and un-bundling is exactly the kind
  of surface change that 1.0 is meant to *prevent* doing casually, so it should
  either happen before the freeze or wait for 2.0. <!-- DECIDE: This one genuinely can't be a quiet 1.x change. Either do it pre-1.0 or accept it's a 2.0 item. Recommendation: keep bundled (it's the differentiator per the CEO review), revisit only with adoption. -->
- **Re-pressure-test config formats / HTML doc-gen** (TODOS). Scope-boundary
  review, not a compatibility issue.

## 4. Cadence & compatibility promises

**Pre-1.0 (now):** As the CHANGELOG states — breaking changes may land in minor
versions and are always called out in the entry; patch versions are always safe
to take. Each release is tagged twice (`vX.Y.Z` library, `zcli-vX.Y.Z` CLI) in
lockstep.

**Post-1.0:** Standard semver. Breaking changes to the frozen surfaces in §2
require a major bump. Additive changes (new widgets, new plugins, new theme
tokens, new `meta` keys) are minor. Fixes are patch. Every release keeps the
CHANGELOG's per-entry migration notes.

**Zig-version coupling** — this is the one place a dependency's instability can
reach through a "stable" zcli, so it gets an explicit rule:

- zcli targets **stable Zig only** — never nightly. `main` and the latest release
  build and test against a single stable Zig (currently 0.16.0) on all three OSes
  every commit.
- **Moving to a new stable Zig is at least a minor bump**, stated in the release
  entry (0.18.0 → Zig 0.16 is the precedent). This holds after 1.0 too: a Zig
  upgrade that forces source changes on your commands is a zcli minor, and the
  entry says what changed.
- Because `context.io` exposes `std.Io` and commands can touch `std` directly,
  **zcli's source-compatibility promise is bounded by Zig's own.** A 1.x that
  moves to a new stable Zig may require the *same* mechanical edits Zig's release
  required — zcli won't paper over a std API change, but it will (a) never make
  you chase nightly, and (b) document the delta. <!-- DECIDE: State the support window — e.g. "each zcli minor supports exactly one stable Zig; the prior Zig is supported on the prior zcli minor for N months." Pick N (or "no back-support" — the CI only ever builds one Zig). -->
- <!-- DECIDE: Will 1.0 ship on Zig 0.16, or wait for the next stable Zig? If Zig 1.0 is on the horizon, note whether zcli 1.0 intends to track it. -->

## 5. How to bet on zcli today

You can build on zcli now. The core contract has been stable across releases and
the remaining churn is scoped (§3). To insulate yourself pre-1.0:

- **Pin a release tag** with its immutable hash — never track `main` in a project
  you ship:
  ```bash
  zig fetch --save https://github.com/ryanhair/zcli/archive/refs/tags/v0.19.0.tar.gz
  ```
  (`main`'s hash changes every commit; that's for trying the development branch,
  not depending on it.)
- **Read the CHANGELOG entry before every upgrade.** Breaking changes pre-1.0 are
  always listed there with migration notes, and only ever in minor/major bumps —
  patch upgrades are always safe.
- **Expected migration effort per minor, pre-1.0:** small and mechanical. The
  recent breaks are representative — a package rename (search-and-replace), an
  instance-API shift (`context.progress()` instead of a free function), a renamed
  method (`setText` → `setMessage`). None have been architectural rewrites of
  your command files; the `meta`/`Args`/`Options`/`execute` shape has held
  throughout. <!-- DECIDE: This characterization is drawn from the 0.18/0.19 CHANGELOG. If you expect the Unreleased block or the pre-1.0 API sweep (§3) to be heavier, temper this. -->
- **The meta-CLI helps you migrate.** `zcli guide` is version-matched to your
  pinned release, and `zcli dev`/`tree` surface breakage fast on upgrade.

If you need a hard source-stability guarantee *today*, wait for 1.0 —
that's precisely the line this document exists to draw. If you can absorb a small,
well-documented migration once per minor, the core is ready to build on now.

---

*Questions or want to weigh in on the 1.0 freeze list? Open an issue. This
roadmap is versioned with the repo and updated as decisions land.*
