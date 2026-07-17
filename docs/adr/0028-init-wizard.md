# The `zcli init` wizard

Status: proposed

`zcli init` is the first thing every user (human or agent) touches, and today it
stops at the project skeleton: name/semver validation, a plugin multi-select,
AGENTS.md, `zig fetch --save`, and next-steps text. Everything *around* the
skeleton — git, a first build, README, GitHub wiring, plugin configuration — is
left for the user to discover. This ADR defines the full init experience:
everything a user might reasonably want decided up front, gathered in one short
wizard, with complete flag parity for non-interactive use.

## Goals

1. **The happy path is ~5 keystrokes.** A short wizard, not an interrogation.
   Every step has a sensible default and can be skipped.
2. **The first manual command runs the user's CLI, not the compiler.** init
   verifies its own output (`zig fetch` + `zig build`) so a scaffold bug is our
   failure, surfaced immediately, not the user's confusing first experience.
3. **Agents are first-class** (ADR-0001..0008). Hard invariant: **every prompt
   has a flag, and `--defaults` (or a non-TTY stdin) answers all of them.**
4. **No dead ends in generated code.** A selected plugin with required config
   gets a follow-up prompt (with a smart default), not a `TODO:` placeholder.

## The wizard flow

Each numbered step is one prompt (or zero, when the corresponding flag was
passed). Order matters: identity → shape → plugins → extras → confirm → do.

1. **Name** — positional arg, as today (`.` = current dir). Unchanged
   validation (identifier-safe, no leading digit, no Zig keywords).
2. **Description** — prompt when interactive and `--description` absent.
   A one-line prompt beats an eternal "A CLI application built with zcli"
   in every `--help` render. Default: skip with the generic text.
3. **CLI shape** — select, `--template <multi|single>`:
   - `multi` (default): current scaffold — `src/commands/hello.zig`, groups
     grow from there.
   - `single`: the root **is** the command (rg/fd style) — scaffold a
     top-level `src/commands/index.zig` with Args/Options and no subcommand
     example. Restructuring between shapes later is genuinely annoying, which
     is why this is asked up front. (A kitchen-sink demo template can be
     added later; out of scope.)

   **Prerequisite**: ADR-0029 (first-class single-command CLIs — the root is
   a group, executable root `index.zig`, positional fallback routing,
   `root.zig` removed). The `single` template ships only after ADR-0029
   lands.
4. **Plugins** — multi-select, as today; flag: `--plugins help,version,...`
   (`--plugins none` for none). New behavior: a selected plugin whose config
   has required fields gets a follow-up prompt instead of TODO placeholders.
   Today that's only `github_upgrade` → prompt for `OWNER/REPO`, default
   inferred from `git remote get-url origin` when available. Non-interactive
   with no flag value: keep the compiling TODO snippet (current behavior).
5. **Extras** — multi-select, flags `--git/--no-git`, `--github <ci,release>`:
   - **git** (default on): `git init`, Zig `.gitignore` (`.zig-cache/`,
     `zig-out/`), initial commit after a successful scaffold. Skip silently
     when `git` is absent or the directory is already inside a work tree.
   - **GitHub CI workflow** (default off): build + test on push/PR. Net-new
     scaffold (nothing exists under `gh add workflow` for CI yet); implement
     as `zcli gh add workflow ci` first, then reuse from init.
   - **GitHub release workflow** (default off, but **suggested on** when
     `github_upgrade` was selected — the release workflow completes the
     self-update loop): reuse the existing `gh add workflow release` scaffold.
6. **Summary + confirm** — one themed block ("Creating `my-app`: multi-command
   · plugins: help, version, not_found · git · release workflow — proceed?")
   before anything touches disk. `--yes` (or `--defaults`, or non-TTY) skips.
7. **Scaffold + verify** — write files, `zig fetch --save` (spinner), `zig
   build` (spinner; `--no-build` opts out), git commit, themed success box
   whose next step is `./zig-out/bin/<name> hello World` (already built).

New scaffold content regardless of choices: **README.md** stub (name,
description, build/run/test instructions).

## Flag surface (the agent contract)

```
zcli init <name|.>
  --description <text>        --app-version <semver>
  --template <multi|single>   --plugins <list|none>
  --upgrade-repo <owner/repo> (github_upgrade config)
  --git | --no-git            --github <ci,release|none>
  --no-build                  --yes / --defaults
  --dry-run                   (print the file list + summary, write nothing)
```

Rules: any flag answers its prompt; `--defaults` answers every remaining prompt
with its default; non-TTY stdin implies `--defaults`; `--yes` additionally
skips the confirm. `--dry-run` renders the summary and file list and exits 0.

## Failure behavior

Unchanged where it exists today (validate before writing; delete the created
tree on scaffold failure; fetch failure downgrades the success message with the
exact recovery command). New steps follow the same pattern: a `zig build` or
`git` failure after a good scaffold is a **warning with the exact command to
run**, never a rollback — the project is valid, only the verification step
failed.

## Deliberately deferred

- Homebrew/package-manager distribution scaffolding — premature.
- Remote or user-definable templates — wait for demand.
- Editor config (`.vscode/`, zls) — opinionated, low value.
- License/author prompts — revisit when release artifacts need them.
- Config-file scaffolding for `zcli_config` — the plugin works without one.

## Implementation increments

Each lands independently, in this order:

1. **Flag parity + `--defaults`/`--yes`/`--dry-run`** for the existing surface
   (plugins flag, non-TTY = defaults formalized). Pure additive; unblocks agents
   immediately. — Implemented: `--plugins <list|none>` (comma-separated,
   validated against the picker set, deduped), `--defaults`, `--yes`/`-y`
   (implies `--defaults`; will additionally skip the confirm once increment 2
   adds one), `--dry-run` (plan summary + file list, exit 0, nothing written).
2. **Git + README + `zig build` verification** with spinners and the summary/
   confirm step. The bulk of the perceived-quality win.
3. **`--template single`** (top-level `src/commands/index.zig` scaffold) and
   the shape prompt — implemented on top of ADR-0029. Release-gated: init
   pins generated projects to this CLI's released tag, and root index
   support ships in the first release after 0.20.0, so while the CLI still
   carries 0.20.0 the shape prompt is not offered and an explicit
   `--template single` fails closed with the reason. The gate clears
   automatically at the next release bump.
4. **Plugin config prompt-through** (`github_upgrade` repo, `--upgrade-repo`,
   git-remote default).
5. **`zcli gh add workflow ci`**, then the extras step reusing both gh
   scaffolds from init.

Every increment keeps `zig build e2e` green and adds e2e coverage for its
non-interactive path (the interactive paths are covered by the existing
prompt/vterm harness).
