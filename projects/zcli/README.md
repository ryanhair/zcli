# zcli (meta-CLI)

The `zcli` binary is the command-line companion for working on [zcli](../../README.md) projects — and it is itself a zcli app: every command below is a file in [`src/commands/`](src/commands/), and it runs on the framework's own plugins (help, completions, "did you mean?", GitHub self-upgrade).

## Install

```bash
curl -fsSL https://zcli.sh/install.sh | sh
```

Prebuilt binaries ship with every release under the `zcli-vX.Y.Z` tags; the installer picks the right one for your platform. Once installed, `zcli upgrade` updates in place.

## Commands

| Command | Does |
|---------|------|
| `zcli init <name>` | Scaffold a new zcli project (build files, example command, `AGENTS.md`, dependency fetch) |
| `zcli add command\|group\|arg\|option\|plugin` | Grow the project — `zcli add command` with no path opens an interactive wizard |
| `zcli rm command\|arg\|option` | Remove a command file, or trim args/options from one |
| `zcli mv <from> <to>` | Move or rename a command file, tidying up empty groups |
| `zcli tree` | Show the command tree discovered from `src/commands` |
| `zcli dev [-- <cmd>]` | Watch `src/` and rebuild on change, optionally re-running a command |
| `zcli guide` | Version-matched reference and worked examples for building with zcli |
| `zcli release` | Create and manage project releases |
| `zcli gh add workflow release` | Add a GitHub Actions workflow for building and releasing binaries |
| `zcli completions` | Generate/install shell completions (from the completions plugin) |
| `zcli upgrade` | Self-upgrade via GitHub releases (from the github_upgrade plugin) |

`add`, `rm`, and `mv` edit command files structurally — they parse the source and preserve your `execute` body, so regenerating scaffolding never clobbers business logic.

## For coding agents

`zcli init` scaffolds an `AGENTS.md` that points agents at `zcli guide` — a reference that ships inside the binary and always matches the installed framework version, so agent context can't drift from the API. `zcli tree` gives agents a stable, ANSI-free read-back of the current command structure.

## Development

Built and tested from this repo:

```bash
zig build          # builds zig-out/bin/zcli
zig build test     # unit tests
zig build e2e      # end-to-end tests against the built binary
```
