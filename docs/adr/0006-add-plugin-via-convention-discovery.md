# `add plugin` scaffolds a file into a convention-discovered `plugins_dir`

Status: accepted

`zcli add plugin <name>` scaffolds a plugin *file* and does **not** mutate `build.zig` on the happy path. The framework already supports convention-based local-plugin discovery via `scanLocalPlugins` over a `plugins_dir` (single-file `plugins/<name>.zig` or multi-file `plugins/<name>/plugin.zig`), exactly parallel to command discovery over `commands_dir`. So `zcli init` will generate `build.zig` with `.plugins_dir = "src/plugins"` (harmless when the dir is absent — discovery returns empty), and `add plugin` simply drops `src/plugins/<name>.zig` plus a co-located test; it is auto-discovered on the next build. This keeps the plugin authoring model consistent with the command model (files-as-source, convention discovery) and eliminates the fragile `build.zig` array-mutation that an explicit-registration approach would require.

Two plugin categories stay distinct: **built-in plugins** (`help`, `version`, `config`, …) remain explicit `zcli.builtin(.tag, .{})` entries chosen via `init`'s multiselect (framework toggles); **user plugins** are convention-discovered. `add plugin` only ever creates the latter.

## Skeleton

The generated file is a guided skeleton, not a bare stub: a header comment, one working pass-through `preExecute` hook (illustrating the real signature and the return-`null`-to-halt pattern), a **commented catalog** of the remaining hooks with exact signatures to uncomment, and `plugin_id` + `ContextData` commented out by default with a note that `plugin_id` is required when `ContextData` is present (minimal-valid plugins need neither — every hook is `@hasDecl`-gated, and `plugin_id` is only required alongside `ContextData`). The CLI surface stays lean: `add plugin <name> [-d <desc>]`, with **no `--hook`/`--with-context` flags** — because naming a hook does not specify its body (unlike an option, which is fully specified by its flags), so the in-file catalog is the better discovery mechanism than CLI flags. Default is single-file `src/plugins/<name>.zig` (consistent with `add command`); the directory form remains available for plugins that grow.

## Considered Options

- **Mutate `build.zig` to add an explicit plugin entry** — rejected for the happy path: fragile array splice; the convention mechanism already exists.
- **Flag-driven hook scaffolding (`--hook …`)** — rejected: generates empty function bodies the author must fill anyway; adds CLI surface for little gain.
- **Convention discovery + guided skeleton (chosen).**

## Consequences

- The one residual `build.zig` case: a project whose `build.zig` lacks `plugins_dir` (pre-existing project, or user removed it). There `add plugin` cannot rely on discovery and instead **prints the single line to add** (`.plugins_dir = "src/plugins",`) — a one-line hint, not a multi-site splice. New projects never hit this.
- `zcli init` must be updated to emit `.plugins_dir = "src/plugins"` in the generated `build.zig`.
