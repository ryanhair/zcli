# init-scaffold

This is the exact project `zcli init` scaffolds — its `build.zig`,
`src/main.zig`, `src/commands/hello.zig`, and `src/commands/index.zig` are the
**reference sources** the `init` command `@embedFile`s and (for `build.zig`)
substitutes the project name, description, and selected plugins into.

A generated project gets ONE of the two command files, by template:
`hello.zig` for `--template multi` (the default), `index.zig` — the root
command (ADR-0029) — for `--template single`. They coexist here so one
compiled project vouches for both scaffolds (an exact command name beats the
root's positionals, so both are exercised).

Because it lives in-repo and is registered as a test project (root `build.zig`),
`zig build test` and `zig build build-examples` compile it against the local,
unreleased zcli. That makes it the scaffold's drift-detector: if a change to
`zcli.generate`, `zcli.addCommandTests`, `zcli.builtin`, `zcli.SharedModule`,
`zcli.ui.panic`, or the command contract breaks the code `init` emits, **our own
build fails here** — instead of shipping a broken scaffold that only fails inside
a downstream user's `zig build`.

Editing these files is editing the scaffold. Keep them buildable and keep them
the idiomatic starting point a new zcli user should read first.

The one difference from `init`'s output is `build.zig.zon`: `init` generates it
programmatically (a random fingerprint, the `--app-version`, and a `zig fetch
--save` of the pinned release tag), so it is not embedded here. This project's
`build.zig.zon` uses a local path dependency like every other in-repo example.
