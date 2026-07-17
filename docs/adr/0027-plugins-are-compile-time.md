# Plugins are compile-time by design

Status: accepted

zcli plugins are resolved, type-checked, and linked at build time. There is no
`oclif plugins install <pkg>`, no Cobra-style out-of-tree binary plugin, no plugin
registry, and no install-without-rebuild. This ADR makes that an explicit,
defended stance rather than an unfilled gap — the biggest affordance a
practitioner coming from oclif/Cobra will notice missing (issue #346).

## Why compile-time

The runtime-plugin story other frameworks ship is a *consequence* of their
architecture: an interpreted or dynamically-linked host can load code it did not
know about when it was built. zcli's core value comes from the opposite property —
the whole CLI is known at `zig build`, so it can be introspected and specialized.
A plugin is not an add-on bolted onto a running host; it is a participant in the
comptime registry that *is* the program. Three concrete mechanisms depend on that
and would have to be given up to load plugins at runtime:

- **The registry is generated and compiled from the plugin set.** `generate()`
  discovers commands and takes the explicit plugin list, then writes a Zig
  registry source that `@import`s each plugin and wires its hooks, commands, and
  global options (`build_utils/code_generation.zig`, `main.zig`). Plugin
  build-time config is introspected from the config struct at comptime and emitted
  as the plugin's `.init(.{…})` call — no runtime config plumbing. The plugin set
  is a compile-time constant; the router has no dynamic-dispatch table to register
  into.

- **Context extensions are type-safe fields, not a string map.** A plugin declares
  `pub const ContextData = struct {…}` plus a `plugin_id`, and the framework
  synthesizes one typed field per plugin under `context.plugins.<id>`
  (`context.zig`, `plugin_types.zig`). Commands read `context.plugins.secrets.token`
  with full type-checking and no lookup. A runtime-loaded plugin cannot contribute
  a field to a struct the host already compiled — the best it could offer is an
  untyped `getData("key")` bag, which is exactly the type safety this design
  exists to remove.

- **Zero runtime overhead / single static binary.** Because everything resolves at
  comptime, there is no plugin loader, no ABI shim, and no dynamic linking on the
  hot path. The shipped artifact is one self-contained binary — which is also the
  distribution story (below), not a limitation to apologize for.

## What this gives up

Stated plainly, because it is real:

- **No install-without-rebuild.** Adding a plugin means editing the project and
  running `zig build`. An end user cannot extend someone else's already-shipped
  CLI without recompiling it.
- **No third-party marketplace dynamics.** There is no ecosystem where independent
  authors publish plugins that any installed CLI can pull at runtime — the network
  effect oclif's `plugins install` enables does not exist here.

## Mitigations

The gap is narrower in practice than it looks, because the workflows runtime
plugins usually serve are covered another way:

- **Local plugins are convention-discovered.** A `plugins_dir` (opt-in; `null`
  unless the project sets it — `zcli init` scaffolds it to `src/plugins`) is
  scanned exactly like `commands_dir`; dropping a `plugins/<name>.zig` file is
  enough (`build_utils/plugin_system.zig` `scanLocalPlugins`, ADR-0006). No
  `build.zig` array to splice.
- **`zcli add plugin <name>` scaffolds one** as a guided skeleton, auto-discovered
  on the next build (ADR-0006).
- **Rebuilds are fast**, and `zcli dev` watches and rebuilds on change — the
  edit-plugin/see-result loop is measured in the same seconds as editing a command.
- **The single static binary is the distribution advantage.** The thing you ship
  has no plugin-version matrix, no "did the user install a compatible plugin"
  failure mode, no runtime resolution to break in the field. For most zcli
  users — a team building *their* CLI, not a platform hosting other people's
  extensions — that trade is strictly favorable.

## When to revisit

Runtime plugins would require either a **stable plugin ABI** (so precompiled
plugin objects could be dynamically linked) or an **IPC/subprocess plugin model**
(plugins as separate executables the host shells out to, à la git subcommands).
Both are real designs; neither is worth building now:

- A stable ABI freezes the `Context`/hook surface — the exact surface these ADRs
  keep evolving (ContextData, `initContextData`, completion `Request`) — and buys
  dynamic linking that undoes the single-static-binary property. It cannot deliver
  the typed `context.plugins.<id>` field; runtime plugins would be second-class.
- An IPC model *can* coexist with the compile-time core (the host stays static;
  external plugins are just discovered executables) and is the more likely path if
  demand appears. It is out of scope until a concrete user needs an
  installed-CLI-extends-at-runtime workflow that the local `plugins_dir` + rebuild
  loop genuinely cannot serve.

The trigger to reopen this is that specific demand — a distribution scenario where
the consumer of a CLI, not its author, must add behavior without a rebuild. Absent
that, compile-time plugins are the intended design, not a missing feature.
