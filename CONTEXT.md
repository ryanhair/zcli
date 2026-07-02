# zcli

zcli is a batteries-included CLI framework for Zig whose surface is everything derived from your command files. This context covers the vision of AI-authored CLIs — an AI generating zcli command files into a project the human owns.

## Language

**Scaffold**:
The structural, framework-facing part of a CLI: command layout, `meta`/`Args`/`Options` contracts, plugins, help/completions. Generated and verified by tooling; it is meant to never break at runtime.
_Avoid_: Boilerplate, skeleton (when precision matters)

**Business logic**:
The work a command actually does — the body of `execute()`. Unbounded and human-facing. Kept small, localized, and readable enough that a non-Zig-fluent developer can patch it.
_Avoid_: Handler code, implementation (when distinguishing from Scaffold)

**Wedge user**:
The polyglot developer who writes CLIs in other languages but does not know Zig. AI removes the language barrier; the generated Zig stays a legitimate, ownable artifact. (Beachhead is the zcli-fluent developer, for whom AI = speed.)
_Avoid_: End user (ambiguous — could mean the user of the generated CLI)

**Read-back**:
The AI's "observe" step: reading the current CLI structure out of the command files as stable, ANSI-free text (an enriched `tree`), so it can reconcile against intent. The counterpart to writing via `add`.
_Avoid_: Dump, export

**Canonical example**:
A small, complete, CI-compiled example CLI that is a first-class maintained artifact — simultaneously an example, the source of the AI idiom/pattern context, and a drift-detector (a framework change that breaks it forces the context up to date). See ADR-0004.
_Avoid_: Fixture, sample (when it means throwaway test data)

## Example dialogue

> **Dev:** The AI needs to see what commands exist before it adds one.
> **Expert:** That's the Read-back — enriched `tree`, plain text, no ANSI. It reads the Scaffold out; it never touches Business logic.
> **Dev:** Where does the AI learn the idioms so it writes idiomatic bodies?
> **Expert:** From the Canonical examples via the scaffolded `AGENTS.md`. Not hand-written prose — the examples compile in CI, so the context can't rot.
> **Dev:** And if the AI's `execute()` body leaks memory?
> **Expert:** It can't, within the run — the arena reclaims everything at command end. The idiom is "never call `free`."

## Flagged ambiguities

**"AI-powered CLI"** — resolved to mean *build-time codegen* (AI writes zcli source the human owns), NOT runtime (a CLI that embeds an LLM for natural-language dispatch).
