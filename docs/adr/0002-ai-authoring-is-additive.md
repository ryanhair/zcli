# AI-authoring is an additive feature, not a reframe

Status: accepted

zcli is gaining the ability for an AI to author CLIs (build-time codegen into a project the human owns), but this must never reframe the framework around AI. Every feature is gated first by the developer building a CLI *without* AI: **"Is this a genuine use-case in a large portion of CLIs?"** A feature that only makes sense because an AI is writing the code does not get built as a feature — instead we capture it as a *pattern/context* handed to the AI. This keeps zcli's identity ("a batteries-included CLI framework whose surface is everything derived from your command files") intact and prevents AI-authoring from bloating scope. Corollary: a primitive's value as an AI constraint (it shrinks the freeform surface) is a welcome *side benefit*, never the primary justification.

## Consequences

- Primitives like an HTTP-with-safe-defaults client qualify because they serve the majority of CLIs directly; the fact that they also stop an AI from hand-rolling something unsafe is a bonus, not the reason.
- "Danger of freeform AI code" is not, by itself, grounds to add a feature. If a concern is real but niche, it becomes shipped context/idioms, not core surface.

## Corollary: the gate is graduated

The "genuine use-case in a large portion of CLIs" test applies with **full force to the framework** (anything in the shipped binary — runtime surface, plugins, primitives) and with **reduced force to the `zcli` CLI itself** (developer-facing authoring/scaffolding tooling that never ships in the user's artifact). Scaffolding convenience is cheap and self-contained; framework surface is expensive and permanent. So `zcli add option`/`add arg`/`rm option`/`rm arg` are justified as CLI tooling even though a human *could* hand-edit — because the edit is a coordinated multi-site change (struct field + `meta` entry + default + short flag + arg ordering), and the tooling carries no runtime cost.
