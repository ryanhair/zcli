# Option constraints: mutually-exclusive sets and dependencies

Status: accepted (implemented)

zcli derives a command's options from its `Options` struct: field type drives
parsing, and a field is *required* when it has no default and can't be absent
(not `?T`, not a `bool`/`?bool` flag, not an array — see `isRequiredOption`).
Required-ness is satisfied by any source — CLI, env (`meta.options.<field>.env`),
or config — tracked through the per-field `options_provided` bitset and a
before/after config snapshot (`firstMissingRequiredOption`).

What's missing is *relationships between* options:

- **Mutual exclusion** — `--json`, `--yaml`, `--xml` may not be combined.
- **Dependency** — `--output-format` is meaningless without `--output`.

Neither can live in a single field's type, because both are cross-field. The
open question was how to express them without inventing a constraint DSL and
without growing a zoo of primitives.

## Decision

**Two constraints, each in its natural home:**

- **`meta.exclusive`** (command level) — a list of *sets*; at most one member of
  each set may be provided.
- **`meta.options.<field>.requires`** (field level) — a list of option names that
  must be provided whenever this field is.

```zig
pub const Options = struct {
    json: bool = false,
    yaml: bool = false,
    xml: bool = false,
    output: ?[]const u8 = null,
    output_format: ?enum { pretty, compact } = null,
};

pub const meta = .{
    .exclusive = .{
        .{ .json, .yaml, .xml },   // at most one
    },
    .options = .{
        .output_format = .{ .requires = .{.output} },  // directional
    },
};
```

Options are named as enum literals (`.json`, `.output`) — the same `.name`
spelling an option is keyed by elsewhere in `meta` — so one uniform rule ("an
option is `.its_name`") holds across the block. `@tagName` recovers the field
name at comptime for the `@hasField` check.

Both constraints operate on the same notion of "provided" that `required`
already uses — the `options_provided` set, filled by CLI / env / config. A
constraint is about whether an option was *supplied*, not about its value; this
keeps one coherent mental model across required, exclusive, and requires.

### Why a root-level *set* for exclusion, not field-level `conflicts`

A binary "A conflicts with B" is just a two-element exclusive set, so sets lose
no expressive power — *any* conflict graph is a union of its edges:

- one-off binary → `.{ "a", "b" }`
- non-clique (`a⊥b`, `b⊥c`, `a`+`c` fine) → `.{ "a", "b" }, .{ "b", "c" }`
- the common N-way "pick one mode" → `.{ "a", "b", "c" }` as one atomic set

and sets add two things field-level conflicts can't:

- **Group atomicity.** An exclusive *set* physically can't be declared with a
  hole. Pairwise conflicts have the star-vs-clique footgun: declaring `json⊥yaml`
  and `json⊥xml` leaves `yaml`+`xml` legal, and no amount of symmetry checking
  catches an edge you simply never wrote. The clique is exactly the case you most
  want protected, and the set makes it a single declaration.
- **Declared once.** Each exclusion is written in one place, not mirrored on two
  fields.

Non-clique conflict graphs — the only thing binary conflicts express that a
single set doesn't — are vanishingly rare in real CLIs (mutual exclusion is
almost always "pick at most one mode"), and the overlapping-sets form above still
covers them. So `exclusive` strictly dominates a field-level `conflicts`, and we
do **not** add one.

### Why field-level `requires`, not a root `together`/`inclusive`

Dependency is frequently **directional**: `--output-format` needs `--output`, but
`--output` alone is fine. A symmetric "all-or-none" set (`together`) can't say
that. `requires` is directional by construction, and the symmetric case —
"both or neither" — is just declaring `requires` in both directions, which is
rare enough not to deserve its own primitive.

### Why not a required/exactly-one flavor

Exactly-one-of-a-mode is already expressible without a new concept: an enum with
no default (`format: enum { json, yaml, xml }`) is exactly-one, and `?enum … =
null` is at-most-one — both with the "did you mean" diagnostics we already emit.
A required flavor of `exclusive` (exactly one of several *separate flags*) and an
at-least-one primitive are deliberately deferred until a real command needs them.

### Validation and diagnostics

- Every name in an `exclusive` set or a `requires` list is checked at comptime
  with `@hasField(Options, name)`; a typo is a build error, not a runtime
  surprise — consistent with the type-driven ethos of the rest of options.
- Comptime guards reject the nonsensical: a self-reference, a *required*
  (always-present) field placed in an `exclusive` set, and two required fields
  sharing one exclusive set (an unsatisfiable constraint).
- Runtime checks run beside `firstMissingRequiredOption`, after config is applied,
  over `options_provided`. Ordering: missing-required first, then `requires`, then
  `exclusive`. Two new diagnostics join the existing structured set:
  - `OptionMutuallyExclusive` — names the set members that were both supplied.
  - `OptionMissingDependency` — names the supplied option and the missing one it
    requires.
  Both flow through the same `?*?ZcliDiagnostic` path and `reportParseError`
  rendering as every other option error, and are interceptable by `onError` hooks.

## Consequences

- One way to express exclusion (`meta.exclusive`) and one way to express
  dependency (`requires`) — no overlapping mechanisms, no DSL, no expression
  grammar to parse. Field names stay greppable and comptime-checkable.
- The runtime gains a second constraint walk over `options_provided`; it reuses
  the provided-set and config-snapshot machinery already built for required
  options, so no new state is threaded through parsing.
- Deferred, to be added only on demand: a required/exactly-one flavor of
  `exclusive`, an at-least-one primitive, and directional-vs-symmetric sugar. The
  chosen primitives don't preclude any of them.

To be documented in `docs/COMMANDS.md` and `docs/DESIGN.md` alongside the
required-options behavior when implemented.
