# Contributing to zcli

## Prerequisites

- **Zig 0.16.0** (`minimum_zig_version` in build.zig.zon; [mise](https://mise.jdx.dev/) users get it from `.tool-versions`)
- No other toolchain requirements — the terminal stack is libc-free on POSIX, and Windows is supported. The secrets plugin's Linux backend shells out to `secret-tool` / `pass` rather than linking (see [ADR-0010](docs/adr/0010-linux-secrets-shell-out-and-pass.md)), so `zig build test-secrets` needs no dev packages; its live round-trip (CI-only) needs those tools installed at runtime.

## Repository layout

```
packages/    the framework, as standalone Zig packages
  core/        parsing, registry, plugins, build-time codegen (the framework)
  ui/          the terminal-native layout engine (ADR-0013) prompts/progress render on
  theme/ markdown/ terminal/ prompts/ progress/   the terminal stack
  vterm/       virtual-terminal emulator (used by tests)
  testing/     the three-tier testing framework
projects/zcli/   the zcli meta-CLI (init/add/rm/mv/tree/dev/release/…)
examples/        canonical example CLIs (ADR-0004: compiled in CI, drift detectors)
docs/            user reference (COMMANDS, PLUGINS, TESTING) + internals (DESIGN, BUILD, ERROR_HANDLING), adr/
website/         zcli.sh (built with Zine, not zig build — deployed by .github/workflows/deploy-docs.yml)
```

Each package under `packages/` builds and tests standalone (`cd packages/<name> && zig build test`). The root `build.zig` is a thin umbrella: it re-exports the packages' modules as the `zcli` dependency surface and aggregates their test steps in-process.

## Building and testing

From the repo root:

- `zig build test` — the whole battery: every package's suite plus the meta-CLI's and every example's tests
- `zig build test-<name>` — one subproject (`test-core`, `test-terminal`, `test-prompts`, `test-tasks`, …)
- `zig build fuzz-smoke` — deterministic parser fuzz corpora (also included in `test`)
- `zig build fuzz --fuzz=50K` — bounded coverage-guided parser fuzzing; omit `=50K` for a sustained local run you stop manually
- `zig build build-examples` / `build-cli` — compile the examples / the zcli binary
- `zig build e2e` — the meta-CLI's end-to-end suite (scaffolds real projects in temp dirs and drives the binary through a PTY; slow, not part of `test`; run it after prompt/render/help changes). Forwards to `projects/zcli`'s own `e2e` step; `cd projects/zcli && zig build e2e -De2e-filter=<substring>` to narrow it while iterating.
- `zig build test-secrets` — compile+link the host's native secrets backend (forwarded from `packages/core`, like `benchmark`/`regression`; not part of `test`)
- `zig build build-all` — everything above that CI also gates: `test` + `build-examples` + `build-cli` + `e2e`. Slow, by design; it is the step whose name means all of it.

`-Dtarget=` and `-Doptimize=` at the root propagate into the package test builds.

### Parser fuzzing and coverage

The core fuzz artifact drives the public `zcli.parseCommandLine` and
`zcli.response_file.expandArgs` seams. It checks arbitrary argv repeatability
and borrowed lifetimes, compares equivalent long/short/attached option
spellings, and expands generated response files through the command parser.
These are behavioral/metamorphic properties, not fixtures that merely assert
their own contents.

An ordinary `zig build fuzz-smoke` executes the fixed Smith corpus and empty
input once. It is deterministic and runs in the default test suite on every
supported OS. `zig build fuzz --fuzz=N` rebuilds the same target with Zig
0.16's coverage-guided instrumentation and stops after a bounded iteration
budget; plain `--fuzz` is the sustained local entry point and opens Zig's web
UI. Zig 0.16 does not implement fuzz mode on Windows, so use Linux or macOS for
the sustained run.

The CI fuzz job uses a clean local cache and publishes Zig's built-in report:
runs, unique runs, and covered/total instrumented PCs. There is deliberately no
coverage percentage gate. The denominator is the full imported core test
artifact and moves with compiler/codegen and source shape; the report is an
objective snapshot and trend signal, not evidence for an arbitrary minimum.
CI uses a 1K iteration budget: clean Linux measurements reach the same useful
in-memory coverage plateau there as at 5K, without exposing the required merge
gate to slow inputs unnecessarily. The job retains a 20-minute hard ceiling
for cold instrumentation and hosted-runner variance. Use a larger bound or an
unbounded session for sustained local fuzzing.

Response-file fuzzing performs real temporary-file I/O to stay on the public
seam. Its Smith corpus runs deterministically in `fuzz-smoke` and the default
test suite, outside the coverage-guided callback: Zig 0.16's multi-instance
Linux/x86_64 fuzzer did not terminate reliably when that callback repeatedly
wrote fixed paths.

Zig 0.16.0's bundled fuzz test runner has an error-return stack-trace type
mismatch when tracing is enabled. The fuzz artifact alone disables
error-return tracing as a narrow workaround; safety checks, panic traces, leak
checks, and all ordinary-test error traces remain enabled.

Before pushing:

```sh
zig fmt packages projects examples build.zig
zig build test
```

### What CI runs

`.github/workflows/ci.yml`, on every PR and every push to `main`. Keep this list in sync when you add a job — it drifted silently once.

| job | what it covers |
| --- | --- |
| `classify changed paths` | Path filters that gate the jobs below. PR-only: pushes to `main` always run everything, and the `ci-full` label forces the full matrix. |
| `zig fmt check` | `zig fmt --check packages projects examples build.zig`, the output-contract grep (no `std.debug.print` / `std.process.exit` outside the command context), and a doc-comment gate on `packages/vterm/src/vterm.zig` (every `pub` declaration needs a `///`). |
| `main ruleset shape` | Anonymous, fail-closed assertion that the public `Main Protection` ruleset still targets the default branch and remains active with deletion, non-fast-forward, and non-strict `CI OK` requirements. It cannot observe bypass actors; those require authenticated administrative audit. |
| `version consistency` | The three umbrella `build.zig.zon` versions, README/ROADMAP archive tags, ROADMAP current release, newest dated CHANGELOG release, and built CLI agree; validator regressions run first. The website transcript injects its version instead of hardcoding one, and install URLs use the branded host. |
| `unit tests` | `zig build test` — the whole battery, on **ubuntu, macos and windows**. |
| `parser fuzz + coverage report` | Deterministic parser fuzz corpus plus a bounded Zig 0.16 coverage-guided run on Linux; publishes covered/total instrumented PCs without a percentage gate. |
| `zcli end-to-end tests` | `zig build e2e` on **ubuntu, macos and windows**. |
| `windows release build` | The CLI built natively on Windows in ReleaseSafe — the only ReleaseSafe Windows coverage on PRs. |
| `linux musl release build` | Both static-musl targets, byte-for-byte the release's build command; x86_64 is smoke-run. |
| `zcli_secrets backend` | The native secrets backend on all three OSes (ADR-0003/ADR-0010). |
| `installer signature binding` | `install.sh` / `install.ps1` signature + version binding on all three OSes (`scripts/test-install-signature.{sh,ps1}`). |
| `release orchestration` | Deterministic workflow dispatch correlation, resumable docs recovery, bounded workflow waiting, and tagged-installer compatibility (`scripts/test-release-orchestration.sh`) on Linux and macOS. |
| `canonical examples compile` | `zig build build-examples` (ADR-0004), plus a real `zig build docs` run against `examples/tasks` with content assertions. |
| `registry comptime scaling` | A generated 120-command app compiled **and run**, so the comptime branch-quota ceiling can't silently come back (#730). |
| `performance budgets` | `zig build regression` — parsing hot path, startup time, binary size. Fail-closed: no skip path. |
| `CI OK` | Aggregates all of the above. This is the **only** required status check; adding a job needs no ruleset edit, only an entry in its `needs`. |

Most jobs are path-gated, so a docs-only PR runs `zig fmt check`, `main ruleset shape`, `version consistency`, and `CI OK`.

## Change conventions

- **One focused PR per change**, branched off `main` — see [What CI runs](#what-ci-runs) for the gate it has to clear.
- **Routine PRs squash-merge.** Use a conventional, imperative squash-commit subject such as `docs: clarify release policy` or `fix: reject invalid input`; do not rewrite shared history merely to make an existing branch conform.
- **Tests ride with the change.** A behavioral fix wants a regression test that fails without it; if you add a command file to the meta-CLI with tests in it, wire it into `command_test_files` in `projects/zcli/build.zig` (unit tests there are opt-in per file).
- **The examples are load-bearing** (ADR-0004): if a framework change breaks `zig build build-examples`, update the examples in the same PR — they're the canonical idiom source.
- **Docs live next to decisions**: significant design choices get an ADR in `docs/adr/`; user-facing behavior changes update the relevant `docs/*.md` (and the scaffolding templates in `projects/zcli/src/commands/init.zig`, which generate what users see first).
- Zig style: `zig fmt` is the arbiter; match the surrounding code's comment density and naming.

## Where to start reading

Internal docs live in the repo:

- [docs/DESIGN.md](docs/DESIGN.md) — how the framework fits together
- [docs/BUILD.md](docs/BUILD.md) — the build-time codegen pipeline
- [docs/adr/](docs/adr/) — why things are the way they are

User-facing docs live on the website ([zcli.sh](https://zcli.sh)) — the repo copies (`docs/COMMANDS.md`, `docs/PLUGINS.md`, `docs/TESTING.md`, `docs/ERROR_HANDLING.md`) are quick summaries that link to it:

- [zcli.sh/docs](https://zcli.sh/docs/) — commands, args & options, the context
- [zcli.sh/plugins](https://zcli.sh/plugins/) — using and writing plugins
- [zcli.sh/testing](https://zcli.sh/testing/) — the three testing tiers and when to use each
- [zcli.sh/errors](https://zcli.sh/errors/) — the error model and diagnostics
