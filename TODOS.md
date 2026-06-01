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
