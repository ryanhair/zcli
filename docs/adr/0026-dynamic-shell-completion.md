# Dynamic shell completion

Status: accepted (implemented — all three increments shipped)

Shell completion (the `zcli_completions` plugin) generates a static bash/zsh/fish
script from the app's compiled command tree. It knows everything derivable at
build time: the command/subcommand names, each command's options, and — after the
positional-argument work — each positional's name, description, and enum choices.
So `tasks done <TAB>` can offer `open done blocked` (an enum), and `tasks edit
<TAB>` can show a `Task ID` hint. What it *cannot* do is offer the **actual ids** —
`3`, `7`, `12` — because those live in the running program's data, not its types.

That is the ceiling of static completion, and three real needs sit above it:

- **Runtime values.** Task ids, branch names, remote hosts, a config key that
  exists in *this* user's file. The set is unknown until the program runs.
- **The bash/fish hint gap.** Static hints are a zsh-only trick (`_message`);
  bash and fish have no message facility, so for a plain positional they can only
  offer real candidates or nothing. Dynamic values are the thing that finally
  gives bash and fish something useful to show.
- **File/dir arguments.** Static completion deliberately dropped the blanket
  `_files` fallback (it dumped the CWD for id-shaped args). But some args *are*
  paths (`tasks import <file>`), and there is currently no way to say so.

The mechanism for all three is the same one every mature CLI framework
(Cobra, Click, clap) converges on: at `<TAB>` the shell **calls back into the
program**, which prints candidates for the word being completed. This ADR defines
that callback for zcli.

## Decision

Add an optional, per-field **`complete` hook** in `meta`, a sibling of the
`validate` hook from ADR-0025, plus a hidden **`__complete`** command that the
generated shell scripts invoke to run it.

Four sub-decisions carry the design.

### 1. The hook is per-field in `meta`, not per-command

A command can have several positionals and options that each complete
differently (`tasks move <id> <sprint>`; `deploy --host <h> --region <r>`). The
unit that needs completion is therefore a *field*, not a command — and zcli
already attaches per-field metadata (`description`, `validate`, `parse`) through
`meta.args.<field>` / `meta.options.<field>`. Completion joins that set:

```zig
pub const Args = struct { id: u32 };

pub const meta = .{
    .args = .{
        .id = .{ .description = "Task ID", .complete = completeTaskId },
    },
};

fn completeTaskId(req: *zcli.completion.Request) !zcli.completion.Result {
    var parsed = try store.load(req.allocator, req.io);
    defer parsed.deinit();
    var out = std.ArrayList(zcli.completion.Candidate).empty;
    for (parsed.value.tasks) |t| {
        if (!std.mem.startsWith(u8, t.idStr(), req.partial)) continue;
        try out.append(req.allocator, .{ .value = t.idStr(), .description = t.title });
    }
    return .{ .candidates = out.items };
}
```

This reuses the exact shape authors already know. It also stays consistent with
the discovery-by-convention contract ([[command-contract-args-options]]): no
separate registration call, no registry mutation — the hook is found the same
comptime way `execute` is, by walking `meta`. The alternative, a single
`pub fn complete` per command that switches on an arg index, was rejected: it
re-introduces positional bookkeeping the rest of the contract has spent effort
*removing*, and it doesn't compose with options.

**Note on the dual-shaped `meta.args`.** A field's arg-meta is *either* a plain
description string (`.id = "Task ID"`) *or* the struct form
(`.id = .{ .description = … }`). `.complete` only exists in the struct form, so an
author adding completion migrates that one field's string to the struct — exactly
as ADR-0025's `validate` already required. The comptime introspection must branch
on the shape before reading `.complete`; reuse the existing shape-discrimination
helper (`option_utils.hasValidateHook` at `options/utils.zig`) rather than writing
a new one.

### 2. A dedicated, field-agnostic `completion.Request`, not the full `*Context`

The hook receives a purpose-built request whose shape is **identical for
positional args and option values**. The hook already *is* the field
(`completeTaskId` on `.id`, `completeHost` on `--host`), so it knows its own
identity; the request only describes the state of the line. That is what lets
option-value completion reuse this contract with no widening later:

```zig
pub const completion = struct {
    pub const Request = struct {
        allocator: std.mem.Allocator, // arena; freed after the callback
        io: std.Io,
        environ: *const std.process.Environ.Map,
        /// The word being completed (may be empty). Offer only values with this prefix.
        partial: []const u8,
        /// Positional tokens already entered for this command, options stripped,
        /// in order — for context-dependent completion (a branch of the repo named
        /// in an earlier arg). Excludes `partial`. An option-value hook sees the
        /// positionals entered so far here too.
        args: []const []const u8,
    };

    pub const Candidate = struct {
        value: []const u8,
        /// Shown by zsh/fish beside the value; ignored by bash.
        description: ?[]const u8 = null,
    };

    pub const Result = struct {
        candidates: []const Candidate = &.{},
        /// What to do *in addition* to `candidates`. `.default` = just the
        /// candidates. See sub-decision 3 for `.also_files`/`.also_dirs`.
        directive: Directive = .default,
    };

    pub const Directive = enum { default, also_files, also_dirs };
};
```

Handing over the full `*Context` would give the hook `stdout` — and a stray
`context.stdout().print` mid-completion corrupts the very byte stream the protocol
travels on. A dedicated request makes the hook's contract *read inputs, return a
result*, structurally unable to write to the wire, and trivially testable (no
stdio, no theme). Same reasoning ADR-0025 used to keep `validate` pure.

The hook returns `Result`, not a bare `[]Candidate`, from day one — so adding the
`directive` behaviour (sub-decision 3) never changes the signature. The common
case stays one line: `return .{ .candidates = out.items };`.

Errors are swallowed: a hook that returns `error.X` yields **zero candidates**,
never a broken shell. Because silent-nothing is miserable to debug — and the
resolver (sub-decision 4) can *also* fail silently by landing on the wrong field —
`ZCLI_COMPLETE_DEBUG=1` makes `__complete` print **both** hook errors and
resolution mismatches to **stderr** (never stdout — that is the protocol channel);
off by default so real shells stay quiet.

A hook that needs config gets `io`/`environ` and re-reads it; the request does not
hand over the framework's resolved config. This is a known cost (a config-key hook
re-parses per `<TAB>`), acceptable given completion is best-effort and the file is
small; a cached-config request field is a possible later addition, not v1.

### 3. Builtins (`.file`, `.dir`) resolve in the shell; only functions call back

`complete` accepts **either** a builtin tag **or** a function, discriminated at
comptime:

```zig
.args = .{
    .path = .{ .complete = .file },   // native file completion, no subprocess
    .id   = .{ .complete = completeTaskId }, // dynamic callback
},
```

- `.file` → the generator emits the shell's **native** file completion (`_files`
  in zsh, `compgen -f` in bash, fish's default). This already includes
  directories — you descend through them — so `.file` *is* "files and dirs".
- `.dir` → **directories only** (`_files -/`, `compgen -d`), for `cd`-shaped args.
- a **function** → the generator emits a callback to `__complete` (below).

Builtins are a **closed set the generator owns**: a shell-native behaviour only
exists if the generator knows how to emit it, so a user cannot add one without
touching the generator. That is why they are enum tags and not "provided
functions" — a `zcli.complete.files` function would still need the generator to
recognise its identity specially, i.e. an enum wearing a function costume, while
falsely implying user-extensible natives. The genuinely user-extensible half —
dynamic hooks — *is* already functions. New natives (should any prove worth it)
are new enum variants.

Enum-*typed* fields need no `complete` — their choices are already static and
baked in. `complete` is only for what the type can't express, mirroring how `meta`
is "the escape hatch for what a field's type can't say" (ADR-0025).

**The combine case** — dynamic values *and* file completion (`tasks import <TAB>`
offering recent names *and* accepting a path) — is the one thing the either/or of
builtin-vs-function can't say by declaration. It is handled at the *return* site:
a hook returns `Result{ .candidates, .directive = .also_files }`, and the generated
script, after collecting the callback's values, also invokes native file
completion. This is Cobra's `ShellCompDirective`, pared to the file-relevant
subset. It composes cleanly and is deferred to the last increment.

### 4. Resolution reuses the real parser; the wire is a word array + cursor index

Finding the field the cursor is on is a *parsing* problem, not a token count.
Given `deploy --host x <TAB>`, knowing the cursor sits on positional slot 0
(not slot 1, and not the value of `--host`) requires knowing `--host` takes a
value and consumed `x`. That knowledge — option arity, `--flag=value`, clustered
`-xyz`, `-x value`, negative-number-is-not-a-flag, custom flag names, `--`
end-of-options — already lives in `command_parser`/`options/utils` (`parser.zig:546`
for takes-value, `utils.isNegativeNumber`, `utils.effectiveLongName`). `__complete`
**reuses those primitives** to classify the cursor word; it does not reimplement
them. Reinventing that logic is the single biggest way this feature could ship
subtly wrong.

Because of this, the wire is **not** a reconstructed command line with a `--`
delimiter — a real line can *contain* `--`, which would collide. Instead the
scripts pass the shell's own word array plus the **cursor word index**, the way
Cobra/clap do:

```
tasks __complete <cword> <word0> <word1> …
# bash:  "$COMP_CWORD" "${COMP_WORDS[@]}"
# zsh:   "$CURRENT"    "$words[@]"
# fish:  (count of tokens) (commandline -opc) + current token
```

`__complete` treats everything after `<cword>` as literal words (no option parsing
of its own args), so no word can be mistaken for a flag to `__complete` and there
is no delimiter to collide. It then: resolves the command via the **same
`cmd_entries` path→module walk `executeCommand` already does** (`compiled.zig:1107`,
longest-path-first — no second dispatch table); runs the parser primitives over the
post-command words up to `<cword>` to decide *positional slot N* vs *value of
option `--flag`*; picks that field's `complete` from the module's `meta`; and, for
a function hook, runs it. A `.file`/`.dir` builtin never reaches `__complete` (it
was resolved statically at generation time); a field with no hook prints nothing.

Because the same arity-aware pass classifies both cases, **there is no
"positional-only" version of the resolver** — option-value classification is not a
later add-on but the same code. Only the *script-side wiring* that decides which
positions call back is staged across increments (below).

## The `__complete` wire format and escaping

`__complete` prints a **NUL-delimited** stream: the **first** record is a directive
token (`default` / `also_files` / `also_dirs`); every record after it is a candidate
— `value` then, optionally, a tab and `description`. NUL — not newline — because
candidate values are arbitrary runtime strings (a task title, a branch, a path)
that can legally contain newlines and tabs. Stripping them, as an earlier draft
proposed, is *data corruption*: it would offer a value that differs from the real
one and insert a broken string on the command line. NUL is the only byte a value
cannot contain, so it is the only correct delimiter. (The directive leads rather
than trails so the scripts can read it before deciding whether to also invoke
native file completion, and so a stream is never mistaken for candidates-only.)

Value quoting is the place completion bugs live (the Tier-1 static work proved it),
and dynamic values are the worst case. The naive `COMPREPLY=($(…))` **word-splits
on `IFS` and glob-expands**. So the protocol and scripts are designed together —
each reads NUL records directly (never re-splitting a `$(…)` blob):

- **bash:** a `while IFS= read -r -d '' rec` loop appends quoted values to
  `COMPREPLY` (a `read -d ''` loop rather than `mapfile -d ''` so it also works on
  bash 3.2, the macOS system bash). Never `COMPREPLY=($(…))`.
- **zsh:** the same `read -r -d ''` loop feeds `compadd -d … --`, the `--` guarding
  a value that starts with `-` from being read as an option; descriptions via the
  `-d` display array.
- **fish:** `string split0` turns the NUL stream into a list; fish command
  substitution then splits it on newlines, so the fish path **cannot represent a
  value containing a literal newline** — documented as a fish limitation, not a
  silent corruption (such values are dropped, not mangled).

For the **combine** directive (`.also_files`/`.also_dirs`), after emitting the
candidates each script additionally invokes the shell's native file/dir
completion. On an **empty** partial the directive is downgraded to `default` at the
source (in `__complete`), so a bare `<TAB>` in combine mode shows only the dynamic
candidates, not the whole CWD — the flood guard.

Increment 1 must include **functional per-shell tests** (the Tier-1 `expect` /
`bash -n` / `zsh -n` harness) asserting that a value containing a space, a quote, a
`$`, a glob char, **and a leading `-`** completes as exactly one candidate and
renders literally. The escaping is the risky core, not an implementation detail.

`__complete` runs a deliberately thin path: build the arena + `Request`, resolve,
call the one hook, print, exit. It never dispatches `execute`, runs no
`transformArgs`/`onError` plugin hooks, and produces no other stdout — both so a
`<TAB>` is fast (it spawns the whole binary on every completion) and so no command
side effect can fire during completion.

## Coexistence with static completion

Strictly additive to the positional-argument work:

| field shape                    | completion source           | subprocess? |
|--------------------------------|-----------------------------|-------------|
| enum type                      | static choices              | no          |
| `.complete = .file` / `.dir`   | shell-native files/dirs     | no          |
| `.complete = fn` → `.default`  | `__complete` values         | yes         |
| `.complete = fn` → `.also_*`   | `__complete` values + files | yes         |
| plain, no `complete`           | static hint (zsh only)      | no          |

The fast, no-spawn cases stay fast; the process launch is paid only where an
author explicitly opted into runtime values. And the bash/fish hint gap closes
exactly where it can be closed usefully — with real candidates.

## Consequences

- One new per-field `meta` key (`complete`), discovered at comptime like every
  other contract member; one hidden command; generator changes in all three
  shells. No change to `execute`, `Args`/`Options`, or existing static output for
  fields that don't use it.
- No new registry table and no new parser: `__complete` reuses the `cmd_entries`
  path→module walk (`compiled.zig:1107`) and the `command_parser`/`options/utils`
  arity primitives. The only new logic is "classify the cursor word," built from
  those pieces.
- New public surface, namespaced like ADR-0025's `zcli.custom_type`:
  `zcli.completion.{Request, Candidate, Result, Directive}`, plus the `.file`/`.dir`
  builtin tags. `__complete` is testable the way any command is — feed it argv,
  assert the NUL stream — alongside the per-shell functional escaping tests.
- Performance: completion can spawn the binary per `<TAB>`. Mitigated by the thin
  `__complete` path and by keeping enums/hints/files static; documented so authors
  know a slow `complete` hook is a slow completion.
- Trust boundary: a `complete` hook is read-only by intent and by the shape of
  `Request` (no stdout, no mutation surface). Same privileges as `execute`; the ADR
  states the expectation that hooks don't mutate state, since they fire on
  keystrokes.
- Debuggability: `ZCLI_COMPLETE_DEBUG=1` surfaces hook errors *and* resolver
  mismatches on stderr, so silent-nothing has an explanation during development.
- Docs/AI context: because the hook lives in `meta`, it flows into the compiled
  examples that feed AI authoring ([[ai-authored-cli-design]]) for free.

## Increments

1. **Protocol + function hooks + arity-aware resolution + safe escaping.** The
   `zcli.completion` types; function hooks; the word-array/cursor-index wire; the
   full arity-aware resolver (classifies both positional slots and option values —
   this is *not* deferrable) built on the `cmd_entries` walk and the parser
   primitives; `ZCLI_COMPLETE_DEBUG`; dual-shape `meta.args` handling; and NUL-safe
   callback wiring in all three generators **for positional args**, with the
   per-shell escaping tests (space/quote/`$`/glob/leading-`-`). Ships real ids on
   the hardest surface (cross-shell quoting + correct cursor resolution) first.
2. **Option-value script wiring + `.file`/`.dir` builtins.** The resolver already
   classifies `--flag <TAB>`; this increment emits the callback at option-value
   positions in the three scripts (keying on the option spec), reusing the
   increment-1 `Request` and `__complete` unchanged. Plus the static
   native-file/dir markers (a self-contained generator tweak restoring the path
   completion the static work dropped).
3. **The combine directive.** Wire `.also_files`/`.also_dirs`: after the callback
   list, additionally invoke native file/dir completion — including the guard that
   an **empty `partial` in combine mode does not flood the CWD** (the misbehavior
   static completion removed). Extension filtering, if ever wanted, extends
   `Directive` here.

Increment 1 carries the genuinely hard, correctness-critical parts (resolution +
escaping); 2 and 3 are additive, lower-risk wiring on top.

## Open questions

- **Descriptions in bash.** bash discards them (COMPREPLY is values only). Fine,
  but worth a note in the generated output so it's not mistaken for a bug.
- **fish + embedded newlines.** fish's newline-split command substitution can't
  carry a value with a literal newline; such candidates are dropped on fish.
  Acceptable (near-zero real cases); revisit only if it bites.
- **Caching.** A slow hook run per `<TAB>` could warrant per-directory caching
  (some shells do it). Out of scope; revisit only if a real hook proves too slow.
