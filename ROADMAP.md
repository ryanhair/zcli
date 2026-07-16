# Roadmap to 1.0

This document exists to answer one question an evaluator has before adopting a
pre-1.0 framework: **can I build on this now, and what will break under me?**

The [CHANGELOG](CHANGELOG.md) is honest that "breaking changes may land in minor
versions" before 1.0. This page gives that policy a destination — what freezes at
1.0, what stays deliberately open, and what has to land first — so you can decide
whether to adopt today or wait.

It is a statement of *intent*, not a delivery contract. **There is no 1.0 date.**
The freeze list below is the ratified plan for what 1.0 will promise when it
happens; 0.20 — the last *known* breaking block — has shipped (§3), and 1.0
ships when the maintainer judges the frozen surfaces have settled — not before.

## 1. Where zcli is today

Current release: **v0.20.0** (Zig 0.16.0, Linux/macOS/Windows).

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
  `context.plugins.<id>` data. Seven plugins ship in-box on this surface (see
  [docs/PLUGINS.md](docs/PLUGINS.md) for the canonical list).
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

The two lists below are ratified: this is the line 1.0 will draw.

### Freezes at 1.0 (breaking changes ⇒ 2.0)

- **The command contract.** The `meta` block's recognized keys, the `Args` /
  `Options` struct conventions (types, `nullable`, `multiple`/variadic,
  short-flag derivation, defaults), and the `execute(args, options, context)`
  signature.
- **The `context` surface used inside `execute`.** The documented accessors —
  `context.stdout()` / `stderr()`, `context.io`, `context.prompts()`,
  `context.progress()`, `context.ui()`, `context.theme`, `context.plugins.<id>`,
  `context.fail()`, and the arena allocator. The promise covers the accessors'
  *names and existence*; the shape of Zig std types they return (`context.io` is
  `std.Io`) is explicitly excluded and bounded by Zig's own stability — see the
  Zig-coupling rule in §4.
- **Process exit codes.** `0` success, `1` command failure (`context.fail`),
  `2` CLI misuse, `3` command not found, `141` broken pipe — scripts may depend
  on these.
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
- **The `ui` node/layout primitives.** The immediate-mode node API
  (`ui.box`/`ui.text`/`ui.spacer`/`ui.column` and friends, the `fit`/`len`/`fill`
  sizing model) and the `App.emit()`/`App.frame()` loop. The *widget catalog*
  built on top of these stays open — see below.
- **The dual-tag release scheme.** `vX.Y.Z` (library) + `zcli-vX.Y.Z` (CLI
  binaries) in lockstep.

### Stays versioned-but-unstable under 1.x (additive, may change)

These grow and evolve under 1.x; changes are announced in the CHANGELOG but do
**not** wait for a major bump. Betting on zcli's *core* doesn't require betting
these are final.

- **The `ui` widget catalog.** New widgets, new options on existing widgets, and
  layout-engine internals. The Select/TextInput/Button/etc. catalog is declared
  "capability-complete" for common forms (ADR-0018) and the `handle()`/state
  contract was recently unified across all widgets, but the surface is expected
  to keep gaining leaves and knobs. (The node/layout *primitives* the widgets are
  built on freeze at 1.0 — see the list above.)
- **New plugins and new options on existing plugins.** Adding a plugin, or adding
  a field to a plugin's `ContextData`/config, is additive.
- **Theme tokens.** New semantic roles and component tokens (ADR-0012/0020).
  Existing role *names* are part of the frozen theme API; the set grows.
- **The meta-CLI's own commands and their flags.** `zcli add/mv/rm/dev/guide/…`
  are developer tooling, versioned with `zcli-vX.Y.Z`; their UX can change more
  freely than the library API an app compiles against. This looser bar is
  intentional: the semver promise protects code that *compiles* against zcli,
  not muscle memory in the dev tool.
- **Generated doc-site HTML/CSS.** Cosmetic output, not an API.

## 3. What must land before 1.0

1.0 is a *stability* declaration, not a feature gate, so the bar for an item here
is "shipping this after 1.0 would be a breaking change or an integrity gap we'd
regret freezing around." **1.0 is deliberately not scheduled.** 0.20 shipped
2026-07-15; the freeze happens some releases after that, once the surfaces in
§2 have stopped moving on their own.

**Blockers (in order):**

- **Let 0.20 settle.** The progress/prompts instance-API rebuild (ADR-0014) and
  the `zcli.ui` engine were the last *known* breaking changes to the surfaces
  §2 freezes. They shipped as v0.20.0 (2026-07-15) and are adopted by the
  examples and the meta-CLI; they still need at least one released minor of
  real use before any freeze.
- **A final API sweep of the freeze list in §2.** One pass to rename/remove
  anything awkward *while it's still free* — the project's stated preference is
  "never prioritize backwards compatibility pre-1.0; make the cleanest choice."
  1.0 is the deadline for that preference. (A first pass already landed: the
  widget `handle()` contract was unified, the plugin-ABI re-exports moved under
  `zcli.plugin_abi`, and standard exit codes shipped.)

**Already landed (was on this list):**

- **Release integrity.** `checksums.txt` is signed with an offline-custody
  [minisign](https://jedisct1.github.io/minisign/) key ([ADR-0023](docs/adr/0023-release-signing-minisign.md));
  `install.sh` and `zcli upgrade` verify fail-closed. The install/upgrade path
  freezes with publisher-level integrity already in place.
- **Split the unit-testing tier out of `testing`** (TODOS). `unit.zig` is now its
  own module (`zcli_testing_unit`); the `testing` module no longer drags
  zcli/vterm/serde into subprocess/PTY-only consumers. The public `zcli-testing`
  import name is unchanged.

**NON-blockers (fine to defer past 1.0 — all additive or internal):**

- **Re-pressure-test config formats / HTML doc-gen** (TODOS). Scope-boundary
  review, not a compatibility issue.

**Decided against:**

- **Un-bundling the TUI libraries from the public surface.** The batteries-included
  terminal stack is the differentiator; it stays bundled, and the `ui` split in §2
  (frozen primitives, open catalog) is how it coexists with a stability promise.
  Un-bundling can't be a quiet 1.x change, so this decision holds until at least
  2.0. (The compile-time plugin stance is likewise settled — see
  [ADR-0027](docs/adr/0027-plugins-are-compile-time.md).)

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
  you chase nightly, and (b) document the delta.
- **Each zcli release targets exactly one stable Zig; there is no back-support.**
  CI only ever builds one Zig, and that's the honest promise: staying on an older
  Zig means pinning the last zcli release that targeted it, which receives no
  further changes once the next minor ships.
- **1.0 will not wait on a Zig release.** It ships on whichever stable Zig is
  current when the freeze list has settled (today that's 0.16.0), and zcli 1.0
  does not track or wait for Zig 1.0.

## 5. How to bet on zcli today

You can build on zcli now. The core contract has been stable across releases and
the remaining churn is scoped (§3). To insulate yourself pre-1.0:

- **Pin a release tag** with its immutable hash — never track `main` in a project
  you ship:
  ```bash
  zig fetch --save https://github.com/ryanhair/zcli/archive/refs/tags/v0.20.0.tar.gz
  ```
  (`main`'s hash changes every commit; that's for trying the development branch,
  not depending on it.)
- **Read the CHANGELOG entry before every upgrade.** Breaking changes pre-1.0 are
  always listed there with migration notes, and only ever in minor/major bumps —
  patch upgrades are always safe.
- **Expected migration effort per minor, pre-1.0:** small and mechanical. The
  recent breaks are representative — a package rename (search-and-replace), an
  instance-API shift (`context.progress()` instead of a free function), a renamed
  method (`setText` → `setMessage`). The 0.20 block (§3) was the same
  character. None have been architectural rewrites of your command files; the
  `meta`/`Args`/`Options`/`execute` shape has held throughout.
- **The meta-CLI helps you migrate.** `zcli guide` is version-matched to your
  pinned release, and `zcli dev`/`tree` surface breakage fast on upgrade.

If you need a hard source-stability guarantee *today*, wait for 1.0 —
that's precisely the line this document exists to draw. If you can absorb a small,
well-documented migration once per minor, the core is ready to build on now.

---

*Questions or want to weigh in on the 1.0 freeze list? Open an issue. This
roadmap is versioned with the repo and updated as decisions land.*
