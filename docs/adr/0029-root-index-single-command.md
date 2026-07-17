# First-class single-command CLIs: the root is a group

Status: proposed

A large class of excellent CLIs is a single command: `rg`, `fd`, `jq`, `curl`.
zcli today half-supports this via a special `src/commands/root.zig` file: the
registry routes to a pseudo-path `["root"]` when argv is empty or starts with
`-`. Validated 2026-07-17 (scratch project against local zcli): options and
bare invocation work, but a bare positional — `myapp World`, the *defining*
usage of this shape — dies with `Unknown command 'World'`. The mechanism is
also an island: discovery doesn't know about it (`root.zig` is discovered as
an ordinary leaf named `root`), help has a one-off branch for the pseudo-path,
completions ignore it, and it's undocumented outside two DESIGN.md lines.

Meanwhile zcli already has exactly the right concept: **groups**. A directory
is a group; its `index.zig` makes it metadata-only or executable. The only
group without this power is the most important one — the root of
`commands_dir` itself (discovery silently skips a top-level `index.zig`).

## Decision

**The root of `commands_dir` is a group like any other.** A top-level
`src/commands/index.zig` is the root group's index — and an executable root
index with no sibling commands *is* a single-command CLI. `root.zig` and its
pseudo-path machinery are removed entirely (no compatibility shim; a
`root.zig` file simply becomes an ordinary command named `root`).

The root index gets everything a subcommand gets: `Args` (optional, varargs,
enums, custom parse types, field validation), `Options` (short flags, env
binding, constraints), `meta` validation, help, static and dynamic
completions, `zcli tree` visibility, doc generation, and `addCommandTests`
coverage.

### Group-type parity at the root

| Group type | In a subdirectory | At the root |
|---|---|---|
| Pure (no index.zig) | organizational, help lists children | today's behavior: bare invocation → help/CommandNotFound |
| Metadata-only (meta, no execute) | description in parent's help listing | **build-time error** — the root has no parent listing and `app_description` already owns that slot; a silent no-op would violate fail-loud. The error message points at `app_description` in build.zig. |
| Executable (execute) | runs on bare group invocation | runs on bare invocation, option-first argv, and unmatched positionals (below) |

### Routing (one rule, every depth)

Longest command-path match wins, unchanged. When matching stops short:

1. Find the deepest matched group (the root is the depth-0 group).
2. If that group has an executable index **whose `Args` declares at least one
   positional** (comptime-known), route the remaining argv to it —
   `myapp World --loud` → root index with `name="World"`; `app users 123` →
   `users/index.zig` with the `123` positional.
3. Otherwise keep today's behavior: CommandNotFound / SubcommandNotFound with
   "did you mean" suggestions.

The positional-declaration gate is the design's key trade: an app whose
executable index takes no positionals (a git-status-style dashboard root)
keeps full typo suggestions; an app that declares root positionals has *told
us* bare words are values, so suggestions are impossible anyway (Cobra makes
the same choice). Empty argv and option-first argv route to an executable
index unconditionally, as the root pseudo-path does today — a required root
positional then fails with the normal missing-argument diagnostic and usage,
which is correct rg-style behavior for `myapp` alone.

Precedence stays: real command paths (file-based, then plugin commands like
`help`) always beat the positional fallback. A user whose root CLI must accept
a value that collides with a command name can use `--` (already supported) —
document this, don't special-case it.

### Surfaces

- **Discovery** (`command_discovery.zig`): `discoverInDir` checks the top
  directory for `index.zig` (same `hasIndexFile` used for subdirs) and records
  a root command on `DiscoveredCommands`. `zcli tree` (shared discovery)
  renders it as the root row.
- **Codegen** (`code_generation.zig` / `module_creation.zig`): import the root
  index module and `.register("", <module>)`; `builder.zig`/`paths.zig` learn
  that the empty string splits to the empty path. Module naming follows the
  existing full-path convention (root index → `index`).
- **Registry** (`registry/compiled.zig`): delete the `["root"]` pseudo-path
  block and the two help-listing skips; add empty-path routing per the rule
  above. `context.command_path` for the root index is `&.{}` — audit
  consumers (diagnostic_errors.zig already renders a fallback label).
- **Help plugin**: replace the `command_path[0] == "root"` branch with
  `command_path.len == 0`. Single-command layout: when the root index is the
  only file-based command, lead with `myapp [OPTIONS] <ARGS>` usage and its
  ARGUMENTS/OPTIONS; list plugin commands (e.g. `help`) only if visible. The
  existing merged app+root help rendering carries over.
- **Completions**: top-level completion offers the root index's options and
  positional hints (enum candidates, dynamic callback per ADR-0026), not just
  command names.
- **Docs**: DESIGN.md loses its two `root.zig` lines and documents the
  root-group model; `zcli guide structure` gains the single-command shape;
  the website structure guide follows.

## What is removed

- `registry/compiled.zig`: `use_root_command` / `root_exists` /
  `["root"]` routing and both `path[0] == "root"` help-listing skips.
- `zcli_help/plugin.zig`: the `"root"` pseudo-path branch.
- `docs/DESIGN.md`: both `root.zig` mentions.
- `registry/tests.zig`: pseudo-path assumptions in affected tests.

Clean break, per project policy: no deprecation window, no alias. Nothing in
the repo's own projects uses `root.zig`.

## Implementation increments

1. **Strip `root.zig`** — remove the pseudo-path machinery and docs lines.
   Standalone, immediately mergeable; the half-feature stops being load-bearing
   before anything builds on the new model.
2. **Root index discovery → execution** — discovery, codegen, empty-path
   registration, routing for empty/option-first argv, meta-only-root build
   error. e2e: the validation matrix (bare, `--loud`, `-l`, `--help`,
   `--version`).
3. **Positional fallback at every depth** — the unmatched-word rule gated on
   declared positionals, with registry unit tests for root and nested groups
   (`app users 123`) plus suggestion-preservation tests for positional-less
   indexes.
4. **Surface parity** — help single-command layout, completions, `zcli tree`,
   guide/docs updates.

ADR-0028's `--template single` (increment 3 there) then scaffolds
`src/commands/index.zig` on top of this.
