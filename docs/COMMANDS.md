# Commands

> **Full reference: [zcli.sh/docs](https://zcli.sh/docs/#commands).** This is a quick
> orientation; the website is the single source of truth for the command contract.

Commands are `.zig` files in your commands directory. The file path becomes the command path:

```
src/commands/
├── init.zig              → myapp init
├── deploy.zig            → myapp deploy
└── users/
    ├── create.zig        → myapp users create
    └── list.zig          → myapp users list
```

Discovery happens at build time — see [BUILD.md](BUILD.md) for how the registry is generated.

### Naming rules (build errors, not silent skips)

Discovery fails the build loudly rather than dropping a command, so mistakes can't vanish from your CLI:

- **Name collisions** — a leaf and a same-named group (e.g. `users.zig` *and* `users/`) both resolve to the command `users`. This is rejected; delete one, or use `users/index.zig` for an executable parent that also has subcommands.
- **Reserved names** — Windows DOS device names (`con`, `prn`, `aux`, `nul`, `com1`–`com9`, `lpt1`–`lpt9`) are rejected on **all** platforms, not just Windows targets. This is portability-by-default: a `commands/aux.zig` that builds on macOS/Linux would break the Windows build in a far more confusing way. If you hit this on a POSIX-only project, rename the command.
- **Invalid characters** — names must start with a letter or underscore and contain only letters, digits, `_`, or `-`.

Files and directories prefixed with `_` (helpers) or `.` (hidden) are skipped silently by design.

Every command is one file with up to four exports:

```zig
const zcli = @import("zcli");

pub const meta = .{ .description = "Add files to the index" };
pub const Args = struct { files: []const []const u8 };   // positional; variadic tail
pub const Options = struct { all: bool = false };        // flags & valued options

pub fn execute(args: Args, options: Options, context: anytype) !void {
    // context.stdout(), context.allocator, context.theme, context.plugins.<id>, …
}
```

- **`meta`** — help text and parsing metadata. Top-level fields: `description`,
  `examples`, `aliases`, `hidden`, and `args`/`options` (per-field metadata,
  below), plus `exclusive` — sets of options where at most one may be supplied
  (see [DESIGN.md](DESIGN.md) and [ADR-0022](adr/0022-option-constraints.md)).
  Per-field metadata (`meta.args.<field>` / `meta.options.<field>`) accepts
  `description`, a `validate` hook (`fn(T) ?[]const u8`, refining an
  already-typed value — [ADR-0025](adr/0025-field-validation-and-custom-parse-types.md)),
  and a `complete` hook for dynamic shell completion (`.file`/`.dir` builtins,
  or a function returning runtime candidates —
  [ADR-0026](adr/0026-dynamic-shell-completion.md)). Options additionally
  accept `short` (single-char flag alias), `name` (override the flag's long
  name — e.g. `.output_dir = .{ .name = "out" }` makes the flag `--out`
  instead of `--output-dir`), `env` (fallback environment variable), and
  `requires` (this option, if supplied, requires another option to also be
  supplied; see ADR-0022). For values that don't map onto a plain scalar
  (`u16`, `enum`, `[]const u8`, …), a field's type can itself declare
  `pub fn parse(s: []const u8) E!@This()` instead of relying on `validate` —
  see ADR-0025.
- **`Args`** — positional arguments as a struct; a `[]const []const u8` field is variadic.
- **`Options`** — `bool`/`?bool` fields are flags; other types take values, with defaults from the initializers.
- **`execute`** — the command body, receiving the parsed, typed `Args` and `Options` plus the app context.

The parser is generated from these structs at compile time, so option types are checked when parsing and reading a nonexistent field fails to compile.

For the full contract — variadic rules, boolean negation (`--no-flag`) and how it shapes help, typing `context` for editor autocomplete, and runnable command groups — see **[zcli.sh/docs](https://zcli.sh/docs/#commands)**.
