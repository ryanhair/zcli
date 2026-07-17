# init-scaffold

This is the exact project `zcli init` scaffolds — its `build.zig`,
`src/main.zig`, and `src/commands/hello.zig` are the **reference sources** the
`init` command `@embedFile`s and (for `build.zig`) substitutes the project
name, description, and selected plugins into.

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
