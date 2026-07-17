# Examples

Every directory here is a small, complete zcli app. Each depends on the root
`zcli` package the same way an external consumer would (`.zcli = .{ .path =
"../.." }`), so they build and test as subprocesses rather than as workspace
members — that's also what makes them *canonical*: they exercise the exact
path a real project takes through this package, manifest and module exports
included (see `build.zig` at the repo root, `test_projects`).

`zig build test` from the repo root compiles and runs every example below
(`test-<name>` steps also exist individually, e.g. `zig build test-vault`).

| Example | What it demonstrates |
|---------|-----------------------|
| [**tasks**](tasks) | The showcase app (see the demo GIF in the root README): 14 commands with nested groups and aliases, six of the eight prompt types, spinners and progress bars, themed output, JSON persistence, config files, and completions. |
| [**ghauth**](ghauth) | GitHub device-flow companion: stashes an API token in the OS keychain via `zcli_secrets`, then uses `zcli.http` to call the API as `whoami`. |
| [**oauth-device**](oauth-device) | Mints a token from scratch by running GitHub's OAuth device flow (RFC 8628), then keychains it — freeform command code, not a framework feature. |
| [**notes**](notes) | A tiny note keeper: saves and loads a typed struct as a JSON file and shares one `store` module across three commands. |
| [**repostat**](repostat) | Prints stats for a public GitHub repo — the minimal `zcli.http` + typed-JSON example, with safe client defaults out of the box. |
| [**ext-plugin**](ext-plugin) | Registers a third-party plugin shipped as its own Zig package (`.dependency = greet_plugin_dep`), contrasting the local-path and built-in plugin styles. |
| [**vault**](vault) | A secrets-backed CLI stitching together `zcli_secrets` (OS keychain), `zcli_config` defaults, dynamic shell completions, and password prompts. |
| [**options-features**](options-features) | Option-parsing edge cases: required options (flag/env/config), array options, per-field `validate` hooks, custom `parse` types, and `meta.exclusive`/`meta.options.*.requires`. |
| [**prompts-features**](prompts-features) | The `password` and `multi_select` prompt types (the other prompt types are covered in `tasks`). |
| [**testing-demo**](testing-demo) | The `zcli-testing` harness used directly in app code: unit-tier `runCommand` inside a command's own tests, plus a subprocess/snapshot integration test against the compiled binary. |
| [**upgrade-demo**](upgrade-demo) | Wires the `github_upgrade` plugin to add a self-upgrade `upgrade` command backed by GitHub Releases. |
| [**init-scaffold**](init-scaffold) | Exactly what `zcli init` scaffolds — its `build.zig`, `main.zig`, and `hello.zig` are the reference sources `init` embeds, so compiling it here catches scaffold drift against the live framework API. |

Building something with zcli? Open a PR to add it here.
