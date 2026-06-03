# TODOS

Deferred work and future scope decisions for zcli. Active work happens on branches;
this file tracks things intentionally postponed with the context to pick them up later.

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
