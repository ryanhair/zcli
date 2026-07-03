# TODOS

Deferred work and future scope decisions for zcli. Active work happens on branches;
this file tracks things intentionally postponed with the context to pick them up later.

## Roadmap: AI-authored CLIs

Vision + rationale live in `docs/adr/0001`–`0008` and `CONTEXT.md`. This is the build
sequence. Each PR references the ADR carrying its rationale. Ordered by dependency.

**Phase 1 — Loop foundations (read + verify + safe execution)**
- [x] **Arena-per-command allocator** (ADR-0001) — DONE. The keystone: makes freeform AI
  business logic memory-safe by construction.
- [x] **PR: Enriched `tree --show-options`** (ADR-0007) — DONE. The AI's read-back. Unified
  `<>`/`[]`/`:type`/`=default`/`...`/`/-short` grammar; short flags, defaults,
  nullable-vs-required, variadic, aliases, hidden; ANSI-free on non-TTY.
- [x] **PR: Legible comptime build errors** (grill Q6) — DONE. The verify feedback signal;
  `validateCommand` names every meta/Args/Options contract violation by command path in
  plain language. (execute-shape check omitted: `@TypeOf(execute)` → Context → registry is a
  comptime dependency loop; a bad signature still fails at the framework call site.)

**Phase 2 — Write surface (the scaffolding CLI)**
- [x] **PR: `add command` extension** — DONE (partial). Full `meta` coverage (commented
  `aliases`/`hidden` scaffolded alongside `examples`); hint when it births an undescribed
  group (ADR-0005/0007). The co-located unit-test stub (Q7) was split out below — it needs a
  `test` step wired into `init`'s generated build.zig to actually run, so it earns its own PR.
- [x] **PR: generated-project testing story (Q7)** — DONE. `zcli add command` scaffolds a
  co-located, schema-robust `runCommand` test (a `hasRequiredArgs` comptime guard makes it
  auto-run while args are optional and compile away once `add arg` adds a required one).
  `init`'s build.zig calls the new `zcli.addCommandTests` helper, which discovers command files
  and compiles each as a test module against a `command_registry` stub (`Context =
  zcli.TestContext(&.{})`) + the unit-testing tier. That tier is now exposed FROM the zcli
  dependency (root build.zig `zcli_testing` module), so scaffolded projects need no extra dep.
- [x] **PR: `add option` + splice engine** (ADR-0005) — DONE. The centerpiece's first half.
  New `scaffold` shared module: `spec` (the arg/option model + rendering/type/name/path
  helpers, extracted from `add command` as the single source of truth) and `splice` (the
  in-file, AST-guided textual editor that adds a field + meta entry while preserving
  `execute()`/comments/formatting). `add option <cmd> <name> --type/--multiple/--nullable/
  --default/--short/-d`. (Note: zcli auto-derives shorts from field first-letters — `default`
  would claim `-d`, so the command's own Options declares `description` before `default`.)
- [x] **PR: `add arg` + remove JSON-blob bulk** (ADR-0005) — DONE. The centerpiece's second
  half. `add arg <cmd> <name> --type/--multiple/--nullable/--before/--after/-d`, reusing the
  splice `Anchor`; ordering (required-before-optional, `multiple` last) validated against the
  real file via a new `splice.fieldShapes` reader, erroring clearly before any write. Deleted
  the JSON front-end (`declarative`/`parseArgJson`/`parseOptJson` + `--arg`/`--option` on
  `add command`) and the now-dead `validateArg`/`validateOpt`; the wizard + shared spec stay.
- [x] **PR: `rm option`/`rm arg`** (ADR-0005) — DONE. New `rm` group with `option`/`arg`
  subcommands. Splice-out (`splice.removeOption`/`removeArg`) computes each field's span +
  trailing comma/whitespace and cuts it, dropping the emptied `meta.<sub>` block; variadic
  `names`; batch is atomic — a missing name (`splice.missingFields`) rejects the whole edit.
- [x] **PR: `add group`** (grill Q8) — DONE. `add group <path> [-d] [--with-landing]` writes a
  meta-only `index.zig` (pure group) by default; `--with-landing` adds an empty-`Args` `execute`
  (optional group — positionals would clash with subcommand names). Describes an existing
  undescribed group; refuses an already-described one. The `add command` group-hint now points
  at `zcli add group <path>/... -d`. (The co-located test rides the deferred Q7 testing PR.)
- [x] **PR: `add plugin` + `init` sets `plugins_dir`** (ADR-0006) — DONE. `init` now emits
  `.plugins_dir = "src/plugins"` in the generated build.zig, so `add plugin <name> [-d]` just
  drops `src/plugins/<name>.zig` (auto-discovered by `scanLocalPlugins`, no build.zig mutation).
  Guided skeleton: one working pass-through `preExecute` + a commented catalog of every other
  hook with exact signatures; `plugin_id`/`ContextData` commented out. Residual case: on a
  build.zig lacking `plugins_dir`, it prints the one-line fix (never splices).
- [x] **PR: `mv` + `rm command`** (grill Q10) — DONE. Whole-file restructure. `mv <from> <to>`
  renames/moves a leaf command file (creating destination group dirs); `rm command <path>`
  deletes one. Both clean group dirs the move/removal leaves empty (`scaffold.fs.removeEmptyParents`,
  cascading up but preserving a group that still holds an `index.zig` or siblings). In-file
  tests/`execute` travel with the file. Leaf-only: moving/removing a whole group errors clearly.

**Phase 3 — Primitives that shrink the freeform surface** (parallelizable with Phase 2)
- [ ] **PR: HTTP client with safe defaults** (ADR-0002/0003) — core; TLS-verified, timeouts.
- [ ] **PR: `zcli_secrets` opt-in plugin** (ADR-0003) — credential storage only (not auth
  flows); keychain-backed with fallback; opt-in to preserve static-musl portability.

**Phase 4 — Context layer (leg 3)** — depends on Phases 2–3 existing
- [ ] **PR: Canonical example CLIs + CI compile** (ADR-0004) — first-class maintained
  artifacts; the idiom source and drift-detector. Demonstrate the primitives above.
- [ ] **PR: `zcli guide`** (ADR-0008) — topic-based; `@embedFile`s the canonical examples
  from the pinned version. Depends on the examples PR.
- [ ] **PR: `AGENTS.md` scaffold + `init` append** (ADR-0008) — thin frozen spine (six
  invariants, speaks commands); marker-delimited, never clobbers. Capstone: it advertises
  the whole surface, so it lands last.

**Critical path:** `add command` → `add option/arg` → `rm option/arg` (the splice family),
then the context tail `examples → guide → AGENTS.md`. **Parallelizable early:** enriched
`tree`, legible build errors, HTTP, secrets.

## Deferred

### Un-bundle / evict the TUI libraries from zcli's public surface
- **What:** Stop re-exporting `zinput` (prompts) and `zprogress` (progress bars) from the
  public `zcli` module, and/or move `zinput`/`zprogress`/`vterm` into their own repositories
  with independent release cadences.
- **Why deferred:** "Batteries-included" is currently zcli's main differentiator vs. a bare
  "Cobra for Zig." Un-bundling trades that DX for positioning clarity, and (per the 2026-05-31
  CEO review) nothing functional breaks by waiting. Pre-adoption there's no user base to
  benefit from the clarity yet.
- **Trigger to revisit:** A bundled library earns an independent audience, OR adoption grows
  enough that a sharp "CLI framework, period" identity outweighs the cost of opt-in deps.
- **Effort:** un-bundle from public API = S; full eviction to separate repos = L (multi-repo,
  version coordination, CI per repo).
- **Context:** See design doc `~/.gstack/projects/ryanhair-zcli/ryanhair-main-design-20260531-005730.md`
  (Approaches A & B, "Deferred Work"). Identity decision: zcli is a batteries-included CLI
  framework whose surface is everything derived from your command files.

### Re-pressure-test config formats and HTML doc generation
- **What:** Revisit whether config needs all three formats (JSON/TOML/YAML via serde) and
  whether HTML doc-site generation belongs in core (vs. man + markdown, which are CLI-native).
- **Why deferred:** Kept by explicit decision (they're projections of command metadata, on
  identity). Flagged as the scope boundaries most likely to be challenged later.
- **Trigger to revisit:** Maintenance burden of multi-format config bites, or HTML doc-gen
  starts pulling zcli toward static-site-generator concerns.
- **Effort:** S–M (per item).

### Split the unit-testing tier out of the `testing` package
- **What:** The `testing` package was zero-dependency until the 2026-06-01 unit-tier move
  (commit `703fd69`). It now depends on `core` + `vterm` (and transitively on serde and core's
  whole sibling tree) solely because the **unit tier** (`testing.unit` / `runCommand`) needs
  `zcli.IO`/`TestContext` + vterm. The **integration** and **E2E** tiers need none of that.
  Consider splitting the unit tier into its own sub-module/package so consumers who only write
  subprocess/PTY tests don't pull the entire framework + a remote serde dep into their test build.
- **Why deferred:** Acceptable trade-off for putting the unit tier in its natural home; not worth
  the extra package/module split pre-adoption. Flagged in the 2026-06-01 five-axis code review as
  the one "Important" architectural item.
- **Trigger to revisit:** A user complains about the testing package's dependency footprint, or
  integration/E2E-only consumers report unwanted transitive deps (esp. the remote serde fetch).
- **Effort:** S–M (module split within `packages/testing`, or a new `zcli-testing-unit` package).
- **Context:** `packages/testing/build.zig.zon` (the new `zcli_core` + `vterm` deps);
  `packages/testing/src/unit.zig` is the only tier needing core.

### Sign releases (checksums.txt) with a pinned client key

- **What:** Sign `checksums.txt` with a detached-signature scheme (minisign/signify style) in the
  release workflow, verify in both `install.sh` and the `zcli_github_upgrade` plugin against a
  public key pinned in the client. Removes GitHub account/token security as the sole integrity
  anchor for distributed binaries.
- **Why deferred:** ADR-0009 records the current model: fail-closed checksums from the same
  release defend transit integrity and asset mix-ups, not a malicious publisher. A signing key
  only adds security once it lives somewhere the release credentials do not — pre-adoption,
  it's key-management ceremony with no one downstream to protect.
- **Trigger to revisit:** Third-party install base emerges; releases move to CI with long-lived
  credentials; or a packaging ecosystem (Homebrew tap, distro) wants a verifiable artifact.
- **Effort:** M (keygen + secret in release workflow, ~30-line verify in installer and plugin,
  key-rotation story documented).
- **Context:** `docs/adr/0009-release-integrity-trust-model.md`; enforcement landed in the
  audit-fix series (#46 installer fail-closed, #47 scratch dir, #57 exec smoke test, #58 exact
  checksum matching).
