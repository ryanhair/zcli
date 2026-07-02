# AI context ships via AGENTS.md, sourced from CI-compiled canonical examples

Status: accepted

To make any coding agent good at zcli despite LLMs having almost no zcli training data (leg-3 legibility), `zcli init` scaffolds an agent-agnostic `AGENTS.md` into the user's repo that points at the machine-legible tools (`tree`, `add`) and a compact idiom/pattern guide. The idiom and pattern content is **sourced from a small set of canonical example CLIs that CI compiles**, not from hand-maintained prose — so a breaking change to the framework breaks the build and forces the context up to date. This applies the projection philosophy already used for docs/config ("the surface is derived, not hand-kept") to the AI context itself: it is a projection of compiled, tested truth. Stale context is worse than none because it actively steers the model toward APIs that changed, so drift-resistance is the governing requirement.

## Consequences

- The canonical example CLIs become first-class, maintained artifacts — simultaneously the examples, the idiom source, and the drift-detector — not throwaway fixtures.
- zcli does not build its own agent; it makes existing agents fluent (consistent with ADR-0002, AI-authoring is additive).
- The patterns for everything deliberately *not* built as a feature (per ADR-0002) live here.
