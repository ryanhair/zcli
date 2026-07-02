# AGENTS.md is a thin frozen spine over a versioned `zcli guide`

Status: accepted

The leg-3 AI context (ADR-0004) is delivered in three layers, each with the stability profile its content needs, resolving the tension that `init` scaffolds `AGENTS.md` *once* (frozen) while the context must be *drift-proof*:

1. **`AGENTS.md`** — scaffolded by `init`, frozen, but safe to freeze because it is thin and **speaks in `zcli` commands, not Zig APIs** (commands are a far more stable contract than code signatures). Contains: project identity, the command loop (read/write/verify), a curated set of invariants, and a pointer to the versioned guide.
2. **`zcli guide`** (new command) — served from the **pinned** zcli version, so it is drift-proof by construction: it always matches the code the AI writes against. Holds the volatile detail (API signatures, primitive catalog, worked examples).
3. **Command files + `tree --show-options`** — the live, always-current project state.

Drift-sensitive content lives only in layer 2 (version-matched to the code). `AGENTS.md` never contains a signature.

## Invariants in AGENTS.md

Curation rule: an invariant belongs here only if it is **(a) high-leverage against a common or severe mistake and (b) version-stable**. Principles belong here; signatures go to `zcli guide`. The set (six):

1. Never call `free`/`deinit` on what you allocate in `execute()` — the allocator is a per-command arena, reclaimed automatically (ADR-0001).
2. Change structure with `zcli add`/`rm`/`mv`, not by hand; write freeform code only in `execute()` bodies.
3. Output via `context.stdout()`/`context.stderr()` — never `std.debug.print` or direct stdout.
4. Don't hand-roll terminal I/O — use `zinput` (input), `zprogress` (progress), `ztheme` (color).
5. Verify with `zig build` + tests; run `zcli guide` for version-matched API detail and examples.
6. File path = command path (`src/commands/foo/bar.zig` → `app foo bar`; `index.zig` = group landing; plugins in `src/plugins/`).

## `zcli guide` shape

Topic-based, like `go doc`/`git help <topic>`: `zcli guide` prints a one-screen overview + topic list; `zcli guide <topic>` (e.g. `prompts`, `arena`, `output`, `plugins`, `http`) prints a focused reference whose worked example is a **real CI-compiled canonical example** embedded from the pinned zcli (via `@embedFile`), not hand-written prose. Topic granularity keeps token cost down (the AI pulls only what it needs) and the compiled source is the drift-detector (an example that stops compiling fails CI).

## `init` behavior with an existing AGENTS.md

`init` **appends a marker-delimited block** (`<!-- zcli:begin --> … <!-- zcli:end -->`), never clobbering an existing file; if absent it creates the file with that block. The user owns everything outside the markers; the markers let a future upgrade refresh just the zcli section.

## Considered Options

- **Fat self-contained AGENTS.md** — rejected: frozen at init, goes stale on zcli upgrade (the "worse than none" drift failure).
- **Regenerate AGENTS.md via a command each upgrade** — rejected: requires user action and risks clobbering local edits.
- **Thin frozen spine + versioned `zcli guide` (chosen).**

## Consequences

- Adds `zcli guide` as a new command (passes the human-first gate — a version-matched reference is useful to any dev, like `rustup doc`).
- Depends on the canonical examples of ADR-0004 existing and compiling in CI; `guide` is their delivery surface.
