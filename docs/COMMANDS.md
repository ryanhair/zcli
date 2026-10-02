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
  below), `plugins` (typed per-command settings declared by registered plugins;
  see [PLUGINS.md](PLUGINS.md#command-specific-plugin-settings)), plus
  `exclusive` — sets of options where at most one may be supplied
  (see [DESIGN.md](DESIGN.md) and [ADR-0022](adr/0022-option-constraints.md)).
  Per-field metadata (`meta.args.<field>` / `meta.options.<field>`) accepts
  `description`, a `validate` hook (`fn(T) ?[]const u8`, refining an
  already-typed value — [ADR-0025](adr/0025-field-validation-and-custom-parse-types.md)),
  and a `complete` hook for dynamic shell completion (`.file`/`.dir` builtins,
  or a function returning runtime candidates —
  [ADR-0026](adr/0026-dynamic-shell-completion.md)). Options additionally
  accept `short` (single-char flag alias), `name` (override the flag's long
  name — e.g. `.output_dir = .{ .name = "out" }` makes the flag `--out`
  instead of `--output-dir`), `env` (fallback environment variable),
  `requires` (this option, if supplied, requires another option to also be
  supplied; see ADR-0022), and `no_config` (`.no_config = true` — the field is
  never filled from a config file, only from the CLI, `env`, or its default;
  use it for anything a config file discovered in the current directory must
  not be able to decide, such as skipping a verification step or naming a
  trusted URL — [ADR-0032](adr/0032-no-config-field-marker.md)).
  For values that don't map onto a plain scalar
  (`u16`, `enum`, `[]const u8`, …), a field's type can itself declare
  `pub fn parse(s: []const u8) E!@This()` instead of relying on `validate` —
  see ADR-0025. Options also accept `delimiter` (explicit list syntax for an
  array) and `stdin` (opt-in stdin resolution for scalar text), described below.
- **`Args`** — positional arguments as a struct; a `[]const []const u8` field is variadic.
- **`Options`** — `bool`/`?bool` fields are flags; other types take values, with defaults from the initializers.
- **`execute`** — the command body, receiving the parsed, typed `Args` and `Options` plus the app context.

The parser is generated from these structs at compile time, so option types are checked when parsing and reading a nonexistent field fails to compile.

For the full contract — variadic rules, boolean negation (`--no-flag`) and how it shapes help, typing `context` for editor autocomplete, and runnable command groups — see **[zcli.sh/docs](https://zcli.sh/docs/#commands)**.

## Repeatable options and stdin text

Array options collect one literal element per occurrence. `--ac "a, b" --ac c`
therefore produces two values: `"a, b"` and `"c"`. Add `.delimiter = ','` when
an option intentionally supports `--tag a,b`; empty delimited segments are
rejected. Long and short forms use the same rules. Delimiters do not implement
CSV quoting, escaping, or whitespace trimming. See [ADR-0024](adr/0024-multi-value-options.md).

```zig
pub const Options = struct {
    ac: []const []const u8 = &.{},
    tags: []const []const u8 = &.{},
    body: ?[]const u8 = null,
};
pub const meta = .{ .options = .{
    .ac = .{ .description = "Acceptance criterion; repeat for each" },
    .tags = .{ .delimiter = ',', .short = 't' },
    .body = .{ .stdin = true },
} };
```

Only an explicit final CLI value of `-` for a `.stdin = true` text option reads
stdin. `--body - --body text` uses `text` without reading; values from config,
environment, and defaults remain literal. Resolution preserves all bytes,
including trailing newlines and empty input, before content validation and
`prepare`. Two requested consumers fail before either reads. The default bound
is 16 MiB, configurable with `GenerateConfig.stdin_max_bytes`. Help/version do
not consume the stream. Standalone parsing records the request but performs no
I/O; test resolution with `runInvocation`. See [ADR-0037](adr/0037-stdin-text-input.md).

Invalid array elements and empty delimited segments produce structured usage
diagnostics and use the configured usage exit status. See
[Error Handling](ERROR_HANDLING.md).
