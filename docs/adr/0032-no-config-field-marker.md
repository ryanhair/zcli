# `meta.options.<field>.no_config`: config trust as a field declaration

Status: accepted (implemented)

An Options field may declare `.no_config = true`. A marked field is never filled
from a config file — no `applyConfigDefaults` hook can populate it — while the
CLI, the env fallback, and the struct default keep working exactly as before.
The marker is comptime-validated and enforced in the registry, not requested of
the plugin.

## Context

`zcli_config` discovers project-local config from the process's cwd
(`.{app}.config.toml` and friends). That is a real, bounded exposure, documented
at length on the plugin: anyone who can get a victim to run the CLI inside a
directory they control — a cloned repo, an extracted archive, a shared build
dir — sets the *default* for every Option the plugin covers, for that
invocation. Values still flow through the typed parser, content is capped, and
CLI/env always win, so it is an attacker-influenced default rather than code
execution. The plugin's doc comment therefore gave concrete guidance:

> do not model security-sensitive behavior (e.g. "skip verification", "disable
> a safety check", a trusted path/URL/repo) as a plain config-overridable Option
> field.

Good advice, correctly reasoned, and followed by the framework's own upgrade
plugin (its repo and signing key are comptime). But it is a **doc comment**.
Nothing stopped an app author from declaring `--skip-verification` as an
ordinary `bool` Option, and nothing warned them. The one class of field where
the guidance matters most is the one where "I read the plugin's doc comment"
is the weakest possible control (#788).

Meanwhile the framework already expresses field-level policy at comptime
everywhere else: `meta.exclusive` and `meta.options.<field>.requires` for
cross-field constraints (ADR-0022), a per-field `validate` hook for value rules
(ADR-0025). "This field is never settable from a config file" is exactly that
shape of statement, and there was no way to say it.

## Decision

A comptime marker in the place every other per-field policy lives:

```zig
pub const Options = struct {
    skip_verification: bool = false,
    registry: []const u8 = "https://registry.example",
};

pub const meta = .{
    .options = .{
        .skip_verification = .{ .no_config = true },
        .registry = .{ .no_config = true },
    },
};
```

Following ADR-0022/ADR-0025 exactly: it sits on `meta.options.<field>`, it joins
the `valid_option_fields` allowlist so a neighbouring typo is a build error, and
its type is checked (`bool`) at comptime with a message that says what the
marker does. `false` is a legitimate no-op, so a comptime-computed marker reads
the way it looks.

### Enforced in the registry, not in the plugin

The obvious implementation — teach `zcli_config` to read the marker — was
rejected for two reasons.

**It would still be advisory.** `applyConfigDefaults` is a public plugin hook.
Any plugin can implement it, and a second config source that didn't check the
marker would silently defeat it. A security marker that only the *bundled*
implementation honors is barely stronger than the doc comment it replaces.

**It would grow the hook contract.** Passing `meta` (or a locked mask) to the
hook makes honoring it an obligation every implementer has to remember — which
is the same failure mode one level down.

So the registry enforces it, around the hook loop, in two layers:

1. **`maskNoConfig`** hands the hooks a `provided` view with every marked
   field's flag forced true. Every hook *already* owes the framework "skip any
   field whose `provided` flag is true" — that single check is what makes
   CLI > env > config hold — so a locked field is skipped by machinery a
   conforming hook has already implemented. No new obligation, and third-party
   config sources get the guarantee for free.
2. **`restoreNoConfig`** afterwards restores the pre-hook value of every marked
   field and clears its `config_applied` flag. A conforming hook makes this a
   no-op; a hook that ignores `provided` cannot make the marker a lie. This is
   what turns the marker from advice into a guarantee.

The *real* provided bitset is untouched, so the required-option and ADR-0022
constraint checks still see the truth: a marked **required** option that only a
config file supplied correctly reports "missing" rather than silently taking the
file's value — the safe outcome, and the one an author who marked the field
would expect.

### Cost

The mask is comptime, so with no marker every flag is false and every guarded
branch folds away. The snapshot needed more care than that: an unconditional
`const before = options` would copy the whole options struct on *every*
invocation of *every* command, and no amount of dead-branch folding removes it —
the copy happens before the branch that would have ignored it. On a path this
repo gates with startup-time and binary-size budgets (#738/#739), that is not a
cost to wave through on behalf of a marker almost no command uses.

So the snapshot's **type** is conditional: `NoConfigSnapshot` is `OptionsType`
when some field is marked and `void` when none is. The unmarked case does not
take a cheap copy — there is nothing to copy. `captureNoConfig` compiles to
nothing and `restoreNoConfig` returns before reading `before`. Commands that
actually use the marker pay one struct copy per invocation, which is the honest
price of a guarantee that survives a hook ignoring its contract. `.no_config =
false` is a no-op here too: it does not flip the snapshot type, so mentioning the
marker inertly costs nothing either.

Restoring **orphans** rather than frees whatever a rogue hook wrote. It must: a
slice field's current value may be the hook's allocation or the struct's own
comptime default, and nothing at that point can tell them apart, so freeing
risks an invalid free. Under the arena-per-command (ADR-0001) the orphan is
reclaimed wholesale, and a conforming hook never allocates for a locked field at
all, because layer 1 made it skip.

### Why a per-field opt-out rather than a per-field opt-in

An allowlist (`.config = true`, nothing settable from config unless marked)
would be the stricter default, and was considered. It was rejected because it
inverts the plugin's entire value proposition: `zcli_config` exists so that
adding one plugin makes *every* option config-overridable with no per-field
work. Requiring an annotation per field would make the common, harmless case
(a default output format) pay for the rare, sensitive one, and an annotation
tax that fires constantly is an annotation people apply mechanically — which
is how it stops meaning anything. Opt-out keeps the marker rare, which keeps it
readable as a signal.

### Why the marker names config, not "trust"

`no_config` says precisely what it does — this field is not populated from a
config file — rather than implying a general trust level the framework cannot
enforce. Env vars are not covered: the environment belongs to the user's own
process, not to a directory they happened to `cd` into, and conflating the two
would make the marker mean something vaguer than it can deliver.

## Consequences

- The plugin's threat-model doc comment now ends in a mechanism instead of an
  instruction: it shows the marker, and keeps recommending the stronger option
  (comptime/build-time config, as the upgrade plugin uses) where it fits. A
  security note that terminates in something you can *write* is worth more than
  one that terminates in something you must remember.
- The `applyConfigDefaults` contract in `plugin_types.zig` documents that
  `provided` now carries the marker, and that ignoring `provided` gets a hook's
  writes to marked fields undone. Hooks that were already correct need no change.
- Help output is unchanged: a marked field looks like any other option. Marking
  it in `--help` was considered and deferred — the marker is a statement about
  where a value may come from, not about how to use the flag, and no other
  source-level policy (`.env`) is surfaced there either. Easy to add if asked for.
- Deliberately not covered, in keeping with the ADR-0022 habit of deferring
  primitives until something needs them: a command-level "no config at all"
  switch, and any marker for `meta.args.<field>` (positionals are never
  config-sourced, so there is nothing to lock).
