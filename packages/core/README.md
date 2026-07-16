# core

The zcli framework itself: argument/option parsing, the command registry and execution engine, the plugin system, and the build-time code generation that turns a `src/commands/` directory into a routed CLI. If you're *using* zcli, start at the [root README](../../README.md) and [docs/](../../docs/) — this file orients you inside the package.

## Map

| Area | What lives there |
|------|------------------|
| `src/args.zig`, `src/options/`, `src/command_parser.zig` | Positional argument parsing, option/flag parsing with validators, and the unified mixed-syntax command-line parser |
| `src/context.zig` | The per-command `Context` (io, allocator — arena-per-command per [ADR-0001](../../docs/adr/0001-arena-per-command-allocator.md) — environ, plugin state) and `Stdio` |
| `src/registry.zig` | The generated registry's runtime: registration, dispatch, `app.run(...)` |
| `src/plugin_types.zig` | The plugin-authoring API: `GlobalOption`, lifecycle hooks, `PluginEntry` |
| `src/plugins/` | The shipped plugins: `zcli_help`, `zcli_version`, `zcli_not_found`, `zcli_completions`, `zcli_config`, `zcli_secrets`, `zcli_github_upgrade` — enabled via `zcli.builtin(.tag, .{})` |
| `src/http.zig` | HTTP client with safe defaults (TLS verification, timeouts, bounded bodies, credential-header stripping on redirect) |
| `src/build_utils/` | Build-time pipeline: command discovery, registry source generation, module wiring, `generate()` coordination, `addCommandTests` |
| `src/diagnostic_errors.zig`, `src/logging.zig` | Error taxonomy and build/runtime logging |
| `src/security_test.zig`, `src/property_test.zig` | Security and randomized-property suites (part of `zig build test`) |

## Build-time API (what consumers call from build.zig)

Re-exported through the zcli package root — `const zcli = @import("zcli");`:

- `generate(b, exe, zcli_dep, config: GenerateConfig) !*Module` — discover commands, generate the registry
- `generateDocs(b, registry, zcli_dep, config: DocsConfig)` — markdown/man/html docs on every build
- `addCommandTests(b, exe, zcli_dep, config: CommandTestsConfig)` — per-command unit-test wiring
- `builtin(tag, config)` — register a shipped plugin by tag
- Types: `GenerateConfig`, `DocsConfig`, `CommandTestsConfig`, `PluginConfig`, `SharedModule`

The full build-system walkthrough is [docs/BUILD.md](../../docs/BUILD.md).

## Test steps

From this directory (`cd packages/core`):

- `zig build test` — everything below except the secrets/native and benchmark steps
- `zig build test-core` / `test-plugins` / `test-security` — focused slices
- `zig build test-secrets` — compiles the host OS secrets backend + its unit tests (links a keychain lib on macOS/Windows; Linux shells out, so it links nothing — ADR-0010)
- `zig build test-secrets-live` — CI-only round-trip against the real OS keychain
- `zig build benchmark` / `regression` — performance runs (ReleaseFast)

All of these also run from the repo root: `zig build test-core` aggregates the `test` step in-process, and `test-secrets`, `test-secrets-live`, `benchmark`, and `regression` are forwarded as root steps.

## Dependencies

[`theme`](../theme/), [`markdown`](../markdown/), [`progress`](../progress/), [`prompts`](../prompts/) (sibling path deps), and [serde.zig](https://github.com/OrlovEvgeny/serde.zig) for config serialization.

## Deeper docs

- [docs/DESIGN.md](../../docs/DESIGN.md) — architecture and runtime design
- [docs/BUILD.md](../../docs/BUILD.md) — the codegen pipeline
- [zcli.sh/testing](https://zcli.sh/testing/) — the testing tiers
- [docs/adr/](../../docs/adr/) — the decision record (0001–0027)
