# Changelog

All notable changes to zcli are documented here.

**Versioning policy:** zcli follows [semver](https://semver.org). Until 1.0, breaking changes may land in minor versions and are called out below; patch versions are always safe to take. Releases target **stable Zig** — moving to a new Zig version is at least a minor bump and is stated in the entry. Each release is tagged twice in lockstep: `vX.Y.Z` is the framework library (the tag for your `build.zig.zon`), `zcli-vX.Y.Z` carries the prebuilt meta-CLI binaries.

## Unreleased

The terminal-native layout engine (ADR-0013), the migration of the interactive packages onto it, and its growth into a full-screen TUI toolkit (ADRs 0015–0020).

### Added
- **Required options** — a non-`bool`, non-optional, non-array `Options` field with no default (e.g. `region: []const u8`) is now a **required option**: the type says a value must be provided. "Required" means absent after *every* source — the CLI flag, a declared `.env` variable, and `zcli_config`'s config file all satisfy it; only if none did does the command fail with `Missing required option '--region'.` plus a usage hint. Help marks these `(required)`, shows them in the usage line (`app cmd --region <value> [OPTIONS]`), and lists enum choices for both options and positional args (`one of: dev, staging, prod`). (This shape was previously a compile error — see the breaking note below.) The `zcli add option <cmd> <name> --type T` scaffolder (and the interactive wizard) create a required option when no `--default`/`--nullable` is given.
- **Enum value suggestions** — a mistyped enum value (positional arg or option) now gets a `Did you mean 'staging'?` hint alongside the `one of: …` choice list, using the same edit-distance engine as unknown-command/option suggestions.
- **`zcli.ui`** — a terminal-native layout engine for CLI/TUI hybrid apps: a static stream flowing into scrollback plus a diffed live region (`app.emit()` / `app.frame(node)`). Immediate-mode node trees (box/text/spacer/custom, `fit`/`len`/`fill` sizing), viewport clamping, resize re-layout including reflow of the visible static tail, real-cursor placement for line editors, and plain-line degradation when piped. `context.ui(.{})` returns a pre-wired `ui.App`.
- **Full-screen TUI mode** — `context.uiFullScreen(.{})` / `App.initFullScreen` run the same layout engine on the alternate screen with raw input and an `App.run` event loop (`view` builds the tree, `update` handles a key/resize/mouse/focus/paste event or a deadline-scheduled `null` tick, an optional post-frame hook places the hardware cursor). The screen and scrollback are restored on exit; requires a `pub const panic = zcli.ui.panic` hook (checked at compile time). (ADR-0015)
- **Focusable widgets** — `ui.widgets.TextInput`, `Select`, `Checkbox`, and `Button`: immediate-mode structs with a `view`/`handle` contract where `handle` returns whether it consumed the key (the whole routing model), caller-owned focus via `focusNext`/`focusPrev`, hardware-cursor placement, and click-to-focus. `Select` supports multi-line / wrapped options. (ADRs 0018–0019)
- **`ui.widgets.Table`** — a read-only data grid: `Dim`-sized columns (`.fit`/`.len`/`.fill`, distributed by the layout engine), a themed header band, a selectable/scrolling body with PgUp/PgDn paging, cell truncation, and overflow arrows. Adds `.pageup`/`.pagedown` to the terminal key parser (`CSI 5~`/`6~`). (ADR-0021)
- **`ui.widgets.Tabs`** — a stateless tab-bar row (the chrome only; the caller owns the content panes): a strip of labels with the active one themed apart from the muted rest, ←/→ moving the active tab with wrap-around and number keys `1`-`9` jumping directly, over a caller-owned active index. `Tab` is never consumed, so it stays reserved for focus navigation. (ADR-0021)
- **`ui.widgets.TextArea`** — a multi-line text field over a caller-owned buffer, sharing `TextInput`'s codepoint-granular editing over a buffer with embedded `\n`s. Soft-wraps at the granted width (the same grapheme/ANSI-aware wrap machinery `Select` uses), ↑/↓ move by *visual* row and Home/End to the row's ends, Enter inserts a newline, PgUp/PgDn page by the field height, and the view scrolls to keep the caret visible. The caret is the real hardware cursor via `cursor_out` (a reverse block is the fallback). Renders through a `custom` leaf so wrap sees the granted width and the caret's absolute cell is reported. (ADR-0021)
- **`ui.widgets.FocusRing(State)`** — a comptime focus-routing helper that derives the ring from `State`'s widget fields (any field whose type has a `handle` method) in declaration order: a reified `Focus` enum, wrapping `next`/`prev`, and `dispatch(state, focus, key, extras)` that routes a key to the focused widget and returns *consumed* (`extras` supplies each multi-arg widget's extra args, and must cover every multi-arg widget since dispatch compiles all arms). Sugar over the ADR-0018 switch — no framework loop, no registry, fully bypassable; generalizes `focusNext`/`focusPrev`. `examples/form.zig` drops its hand-written `Field` enum and dispatch switch for it. (ADR-0021)
- **Scrollbar indicator** — an opt-in `scrollbar: bool` on `viewport` `ViewportOpts` and `Select`/`Table` `ViewOpts`. Off by default (so content width stays stable as data grows); when on, it reserves a 1-cell right gutter and paints a proportional thumb — a dim track (`prompts.hint`) with a brighter thumb (`surface.border`), length ∝ visible/total (min 1 cell) and position ∝ scroll/(total−visible), touching the top at the first row and the bottom at the last. On `Select`/`Table` the scrollbar replaces the overflow arrows in the same gutter (the richer indicator for the column). No new theme tokens; the thumb math is a shared, unit-tested pure function. Closes the ADR-0021 widget-catalog arc. (ADR-0021)
- **Overlays, viewports, and popups** — a `stack` z-layer direction with `center` for modals, `viewport` for content taller than its window, and `probe`/`positioned`/`anchored` for popups that flip above and clamp on screen; plus opt-in `mouse`/`focus`/`paste` events. (ADRs 0016–0019)
- **Theme-derived style defaults** — every styling default derives from the root `zcli_theme` at compile time: a new `surface` token group (`border`, `panel`) styles full-screen chrome, `ui.panel` and bordered boxes need no call-site `Style`, and `ui.role(r)` resolves a palette role in one word. (ADR-0020)
- **`progress.MultiBar`** — stacked labeled bars for parallel work with thread-safe updates.
- vterm supports DECAWM (private mode 7).

### Changed (breaking)
- **Options contract**: a non-`bool`, non-optional, non-array `Options` field with no default used to be a *compile error* ("required values belong in `Args`"). It now compiles and means **required option** (see Added). Pre-1.0 this only affects code that was relying on that shape being rejected — no runnable app could have shipped one. `Args` positionals are still the right home for a value that must appear on the command line in a fixed position.
- **progress**: rebuilt as an instance API (ADR-0014, mirroring Prompts): `@import("progress")` is the `Progress` type bundling writer/`io`/allocator/theme, with `.spinner()`/`.progressBar()`/`.multiBar()` constructors — in commands, `context.progress()`. Indicator types are no longer writer-generic and gained idempotent `deinit()`; `setText` → `setMessage`, `stopAndPersist` → `persist`; `SpinnerConfig.hide_cursor` removed (the engine owns the cursor); piped bars print one finish summary line instead of a line per update.
- **prompts**: the `text` Preview callback returns one line of plain text from the prompt's frame arena (was: writes raw styled bytes) and is styled with the theme's hint token; `number`'s range errors render inside the prompt frame instead of scrolling past it. Rendering is engine-based throughout — navigation repaints only changed cells, long input wraps correctly, and answered lines persist as static output.

### Fixed
- **`ui.widgets.Table` click-to-select off-by-one** — clicking a table row selected the row *below* the cursor in the full-screen demo. Two things stacked: mouse reports are 1-based cells while surfaces are 0-based, and `Table.view` paints its column header as the table's first row inside the same rect `probe` reports — so a hand-rolled `row = click_y - rect.y` was off by one on both counts. Added `Table.rowAt(rect, y) ?usize`, which maps a 0-based click row through the header offset and the scroll window (and rejects clicks on the header or below the table), so click-to-select is one call with no layout magic numbers. `examples/fullscreen.zig` now uses `ui.probe` + `rowAt` (the same click-hit-test idiom `form.zig`/`popup.zig` already use). (ADR-0021)

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
