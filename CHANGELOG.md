# Changelog

All notable changes to zcli are documented here.

**Versioning policy:** zcli follows [semver](https://semver.org). Until 1.0, breaking changes may land in minor versions and are called out below; patch versions are always safe to take. Releases target **stable Zig** — moving to a new Zig version is at least a minor bump and is stated in the entry. Each release is tagged twice in lockstep: `vX.Y.Z` is the framework library (the tag for your `build.zig.zon`), `zcli-vX.Y.Z` carries the prebuilt meta-CLI binaries.

## Unreleased

The terminal-native layout engine (ADR-0013) and the migration of the interactive packages onto it.

### Added
- **`zcli.ui`** — a terminal-native layout engine for CLI/TUI hybrid apps: a static stream flowing into scrollback plus a diffed live region (`app.emit()` / `app.frame(node)`). Immediate-mode node trees (box/text/spacer/custom, `fit`/`len`/`fill` sizing), viewport clamping, resize re-layout including reflow of the visible static tail, real-cursor placement for line editors, and plain-line degradation when piped. `context.ui()` returns a pre-wired `ui.App`.
- **`progress.MultiBar`** — stacked labeled bars for parallel work with thread-safe updates.
- vterm supports DECAWM (private mode 7).

### Changed (breaking)
- **progress**: rebuilt as an instance API (ADR-0014, mirroring Prompts): `@import("progress")` is the `Progress` type bundling writer/`io`/allocator/theme, with `.spinner()`/`.progressBar()`/`.multiBar()` constructors — in commands, `context.progress()`. Indicator types are no longer writer-generic and gained idempotent `deinit()`; `setText` → `setMessage`, `stopAndPersist` → `persist`; `SpinnerConfig.hide_cursor` removed (the engine owns the cursor); piped bars print one finish summary line instead of a line per update.
- **prompts**: the `text` Preview callback returns one line of plain text from the prompt's frame arena (was: writes raw styled bytes) and is styled with the theme's hint token; `number`'s range errors render inside the prompt frame instead of scrolling past it. Rendering is engine-based throughout — navigation repaints only changed cells, long input wraps correctly, and answered lines persist as static output.

## v0.19.0 — 2026-07-05

Hardening and tooling release. Requires Zig 0.16.0.

### Added
- **Command-authoring tools in the meta-CLI**: `zcli add option/arg/group/plugin` and `zcli mv`/`zcli rm` restructure command files in place via an AST splice engine — no JSON blobs, no regeneration.
- **`zcli guide`** — version-matched, topic-based reference for the framework's idioms; `zcli init` scaffolds an `AGENTS.md` that points AI agents at it.
- **`zcli_secrets` plugin** — opt-in credential storage in the OS keychain (macOS Keychain, Linux Secret Service, Windows Credential Manager), no plaintext fallback.
- **HTTP client** with safe defaults over `std.http.Client` (credential headers stripped on cross-origin redirects), plus a canonical `ghauth` example showing the secrets + auth idiom.
- **Arena-per-command allocator** for `execute()` and `context.fail()` for friendly, stack-trace-free command errors.
- Windows joins the first tier: unit tests and the full e2e suite (interactive tier via a ConPTY backend) run on Windows CI, `upgrade` self-replaces correctly on Windows, and the console is put into UTF-8 mode so multibyte I/O round-trips.

### Fixed
- Two full-repo audit passes burned down 50+ findings: memory leaks in the parse pipeline, a PTY-harness deadlock, vterm out-of-bounds on resize, comptime build errors that now name the offending command, config command-scoping applied to TOML/YAML (was JSON-only), and legible errors instead of `exit(1)` throughout the build API.

### Changed
- `generate()`/`generateDocs()`/`addCommandTests()` take typed configs and derive the zcli module themselves.
- The 2,460-line registry was split into focused submodules; zcli no longer re-exports all of serde.
- Releases are gated on the full test suite (including native Windows), and CI actions are pinned to SHAs.

## v0.18.0 — 2026-06-30

The Zig 0.16 release — the largest since the project started. **Breaking: requires Zig 0.16.0** (the new `std.Io` model).

### Added
- **`zcli dev`** — watches your source and rebuilds on change, with restart-on-change for a running binary (native fs events via kqueue/inotify/FSEvents).
- **`zcli tree`** — prints the command hierarchy, sharing the framework's own discovery logic.
- **Interactive wizard** for `zcli add command`, plus declarative flags for scripted use.
- **Interactive prompts** (text, confirm, select, multi-select, password, search, number, editor), config file support for TOML and YAML with per-command scoping, and command aliases.
- Apps can name their generated `Context` type for full editor autocomplete in commands.
- End-to-end test suite for the meta-CLI; docs website; Windows console backend and a libc-free terminal stack (fully static musl builds on Linux).

### Changed
- The monolithic interactive package was split into focused, standalone packages: `zinput`, `terminal`, `vterm`, `zprogress`, `ztheme`.
- `vterm` was removed from zcli's public re-exports — it's a testing tool, available directly.
- `zcli.builtin(.help, .{})` shortcut for enabling built-in plugins.

## v0.14.0 – v0.17.0 — 2025-10-23 to 2025-11-21

Zig 0.15.1 era. Windows support landed (v0.15.0), `std.posix.getenv` was dropped for portability, repeated short options for array types were fixed, commands gained support for C dependencies and command-specific imports (v0.16.0), and a completions memory leak was fixed.

## v0.1.0 – v0.13.1 — 2025-10-09 to 2025-10-19

The foundation, built in ten days: build-time command discovery and routing, the plugin system (help, version, not-found, completions, config, output, upgrade), shell completions, hidden commands, shared modules, the `zcli` meta-CLI with `init`/`release`/`upgrade`, and the `curl | sh` install script. The dual-tag release scheme (`v*` library / `zcli-v*` CLI) was established at v0.11.0.
