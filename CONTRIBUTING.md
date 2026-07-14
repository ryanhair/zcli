# Contributing to zcli

## Prerequisites

- **Zig 0.16.0** (`minimum_zig_version` in build.zig.zon; [mise](https://mise.jdx.dev/) users get it from `.tool-versions`)
- No other toolchain requirements — the terminal stack is libc-free on POSIX, and Windows is supported. The secrets plugin's Linux backend shells out to `secret-tool` / `pass` rather than linking (see [ADR-0010](docs/adr/0010-linux-secrets-shell-out-and-pass.md)), so `zig build test-secrets` needs no dev packages; its live round-trip (CI-only) needs those tools installed at runtime.

## Repository layout

```
packages/    the framework, as standalone Zig packages
  core/        parsing, registry, plugins, build-time codegen (the framework)
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
- `zig build build-examples` / `build-cli` — compile the examples / the zcli binary
- `zig build e2e` — the meta-CLI's end-to-end suite (scaffolds real projects in temp dirs and drives the binary through a PTY; slow, not part of `test`; run it after prompt/render/help changes). Forwards to `projects/zcli`'s own `e2e` step; `cd projects/zcli && zig build e2e -De2e-filter=<substring>` to narrow it while iterating.
- `zig build test-secrets` — compile+link the host's native secrets backend (forwarded from `packages/core`, like `benchmark`/`regression`; not part of `test`)

`-Dtarget=` and `-Doptimize=` at the root propagate into the package test builds.

Before pushing:

```sh
zig fmt packages projects examples build.zig
zig build test
```

## Change conventions

- **One focused PR per change**, branched off `main`. CI runs the unit battery on ubuntu/macos, e2e on ubuntu/macos, a Windows build + portable-package tests, the secrets backends on all three OSes, and compiles every example.
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
