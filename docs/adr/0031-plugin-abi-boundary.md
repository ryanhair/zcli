# Bundled plugins keep the single-import rule; `plugin_abi` gets an admission test

Status: accepted

Bundled plugins — `zcli_help`, `zcli_config`, `zcli_completions`, `zcli_docs`
and the rest under `packages/core/src/plugins/` — compile against exactly one
import, `"zcli"`, the same as a third-party plugin package or a
`plugins_dir` local. They are **not** given a private door into framework
internals. `zcli.plugin_abi` stays the single, named place where an internal
becomes reachable from a plugin, and it now carries a written admission test
(below) that says which internals qualify.

**Nothing was removed from `plugin_abi`.** Issue #787 framed the work as
shrinking it, so this is worth stating plainly rather than leaving a reader to
notice: all five groups remain, because on review all five pass the admission
test this ADR introduces. The change here is a rule where there was none, not a
smaller surface — and if the rule is right, the surface being unchanged is the
expected result, not a dodge. What would have shrunk it is the rejected design
(a private import for bundled plugins), and the "Decision" section is the
argument for why that trade is bad.

## Context

`plugin_abi` re-exports five groups of framework internals purely so bundled
plugins can reach them: `isNegativeNumber`, the serde `config_parse` shims,
`usage`, `custom_type`, and `config_coerce`. Every consumer today is a bundled
plugin; no third-party plugin uses any of it.

The tension is structural and was raised in #787. ADR-0027 makes plugins
compile-time participants in the registry, and bundled plugins live *inside*
core — the same repository, the same release, the same reviewer. Yet
`addPluginModulesToRegistry` gives a built-in exactly the module set it gives a
consumer's local plugin: `zcli` and nothing else. So core reaches its own
internals through a public re-export on its own umbrella, and that re-export
list only ever grows.

The obvious fix is to let bundled plugins import internals directly — an
additional `zcli_internal` module wired only for built-ins (they cannot use
relative imports; their module root is the plugin file, so `../../` escapes it).
That would shrink `plugin_abi` to whatever genuine third-party plugins need,
which today is nothing.

## Decision

**Keep the constraint.** Three reasons, in order of weight:

1. **Bundled plugins are the reference implementations.** A `plugins_dir`
   local plugin and a built-in are compiled by the *same branch* of
   `addPluginModulesToRegistry`, differing only in where the root source file
   resolves. That is not an accident of the build code; it is the property that
   makes "read `zcli_help` to see how a plugin does it" a true answer. Give the
   built-ins a private door and every such answer becomes "with a mechanism you
   don't have" — and the framework loses its most honest set of worked examples
   at exactly the moment ADR-0027 is asking users to accept compile-time-only
   plugins.

2. **The constraint is the only thing making the surface visible.** The
   complaint is that `plugin_abi` grows monotonically. It does — but it grows
   *in a reviewed, documented, greppable list*. Replace it with
   `@import("zcli_internal")` and the growth does not stop; it stops being
   observable. The leak gets worse and quieter. A boundary you can see people
   crossing is worth more than a boundary nobody crosses because it isn't there.

3. **Each crossing is a forcing function.** Adding to `plugin_abi` costs a
   deliberate act, which is what makes someone ask whether the thing being
   exported is *shared vocabulary* or just convenient. Four of the five current
   groups are shared vocabulary: `usage` exists so help and the doc generator
   render the same synopsis, `isNegativeNumber` so the completions cursor walk
   counts positionals exactly as the parser does, `custom_type` and
   `config_coerce` so config coerces a value identically to CLI and env. A
   divergent private copy of any of them would be a *behavioral bug*, not
   duplication. That is not leakage; it is single-source-of-truth, and it should
   be somewhere visible.

There is no ABI cost either way — everything resolves at comptime and links into
one binary (ADR-0027) — so the whole question is conceptual surface, and the
visible-boundary answer wins.

## The admission test

A declaration may join `plugin_abi` only if it passes **at least one** of:

- **Shared agreement.** Two or more independently-compiled units must agree on
  it, such that a divergent copy would be a behavioral bug rather than
  duplication. (`usage`, `isNegativeNumber`, `custom_type`, `config_coerce`.)
- **Dependency containment.** It is a narrow shim that exists to keep a
  third-party dependency *out* of zcli's public contract. (`config_parse`
  re-exports four serde names instead of serde.)

and **all** of:

- **In-lockstep ownership.** You would fix the bundled plugins yourself when it
  changes. If a change here would require coordinating with code you don't own,
  it is a public API question, not a `plugin_abi` one.
- **Named for the job, not the internal.** It goes under a named group that
  says what need it serves (`config_parse`, `config_coerce`), so the entry
  documents the requirement rather than advertising the internal.

And the negative rule, which is the one that matters: **`plugin_abi` is not for
convenience.** If a bundled plugin wants an internal only for itself, and
nothing in core has to agree with it, the answer is to copy the logic into the
plugin or move it there — not to widen the surface. A sixth group that is not
like the five above is the signal that this ADR is being violated.

## Consequences

- The rule lives in three places on purpose: here, as a comment on `plugin_abi`
  in `packages/core/src/zcli.zig` (the point of temptation), and by example in
  the five existing groups. A reviewer can apply it without reading this file.
- `plugin_abi` will keep growing, and that is now an intended, bounded outcome
  rather than an unexamined one. It stays small because the test is narrow, not
  because nobody is looking.
- The `zcli_internal`-module design is written down as **rejected**, so the next
  person to have the idea can see it was considered and why it lost, instead of
  re-deriving it.
- If a genuine third-party plugin ever needs one of these groups, nothing has to
  change — that is the point of exporting them under a documented name in the
  first place. What would reopen this ADR is the opposite: sustained pressure to
  add entries that pass neither arm of the admission test.
