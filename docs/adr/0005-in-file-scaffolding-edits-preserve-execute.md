# Arg/option authoring: one flag-based interface, spliced in-file

Status: accepted

There is exactly one way to describe an arg or option to the `zcli` CLI: a **positional name plus typed flags** — `--type` (element type), `--multiple`, `--nullable`, and, for options, `--default` and `--short`, plus `--description`/`-d`. `type`, `multiple`, and `nullable` stay **decomposed into separate flags** (not encoded into a Zig-type string like `?[]u32`), consistent with the existing deliberate `ArgSpec`/`OptSpec` model. Args and options are added and removed exclusively through the `add option`/`add arg`/`rm option`/`rm arg` verbs; `add command` scaffolds only the command *shell* (path + `-d` description + stubbed `execute` + co-located test) and no longer accepts args/options inline. The prior JSON-blob bulk form (`add command --arg '{…}' --option '{…}'`) is **removed** — flag-based single-item authoring is preferred over blocks of JSON.

Interactive bulk authoring is still served by the **wizard** (`add command` with no flags prompts through args/options in one session), which builds the same `ArgSpec`/`OptSpec` model. So the split is: wizard = human interactive bulk; `add option`/`add arg` = scripted/AI atomic edits. The removed JSON blobs only ever served the awkward non-interactive-bulk middle, now covered better by a shell command followed by atomic `add option`/`add arg` calls (which the AI orchestrates anyway; the transient IR the AI emits is the flag invocations themselves, not JSON).

## Flag semantics

- **Required is implicit**, mirroring the existing `ArgSpec`/`OptSpec` model — there is no `--required` flag. An option with `--nullable` renders `?T = null`; with `--default <expr>` renders `T = <expr>`; with neither it is required (`T`, must be provided). `--default` together with `--nullable` is contradictory and is an **error** (a nullable option already defaults to null; a default_expr is only emitted for non-nullable scalars). Args have no default: `--nullable` makes an arg optional, its absence makes it required.
- **`add arg` positioning:** appends by default; `--before <name>`/`--after <name>` insert at a chosen point (nearly free given the splice already targets a span); ordering rules (required-before-optional, `multiple` last) are enforced by reusing the existing `validateArg`, erroring clearly on violation. `add option` needs no positioning (options are unordered).
- **`rm option`/`rm arg` shape:** `rm option <cmd> <name...>` — variadic names allowed (removal needs no per-item spec, so this is the one place bulk reintroduces no DSL); errors if a named field does not exist (never silently succeeds); echoes what was removed. `rm arg` needs no ordering handling — removal only relaxes constraints.

## In-file edits splice via AST, never regenerate

The commands that mutate an existing command file — `add option`/`add arg`/`rm option`/`rm arg` — must edit the file as a **targeted, AST-guided textual splice**: locate the source spans of the `Options`/`Args` struct and the `meta.options`/`meta.args` literals via `std.zig.Ast` (the same read machinery `tree.zig` already uses), and insert or remove the specific field + meta entry while leaving every other byte untouched. They must **not** regenerate the file from the spec model, because regeneration would destroy the file's `execute()` body — the user's/AI's business logic — along with comments and formatting. (Creation-time rendering still uses full-file `generateSource`, since there is no execute body to preserve yet.) Adding an arg appends by default and re-validates ordering (required-before-optional, `multiple` last), erroring clearly on violation.

## Considered Options

- **JSON-blob bulk (status quo)** — removed: a mini-DSL that served neither humans (wizard is better interactively) nor AI (atomic flag calls are more verifiable) well.
- **Regenerate from spec model on edit** — rejected: destroys `execute()` bodies, comments, formatting.
- **Flag-based single interface + AST splice (chosen)** — one way to describe an arg/option; surgical in-file edits preserve surrounding code.

## Consequences

- `add option`/`add arg`/`rm option`/`rm arg` are the highest-complexity scaffolding tooling (fine-grained in-file mutation), distinct from `mv`/`rm` which operate at whole-file granularity.
- The AST read machinery already exists in `tree.zig`; the new work is the write/splice side.
- Deleting the JSON front-end (`parseArgJson`/`parseOptJson` + the `--arg`/`--option` flags on `add command`) is a net simplification; the shared `ArgSpec`/`OptSpec` model and the wizard front-end stay.
- Creating a command with several args/options is now N+1 atomic calls instead of one — accepted, and better for AI (each op individually verifiable and echoed).
