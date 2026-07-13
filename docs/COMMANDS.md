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

- **`meta`** — help text and parsing metadata (`description`, `examples`, per-arg/option descriptions, `short` flags, `aliases`, `.env` fallbacks, cross-field constraints, and per-field `validate` hooks).
- **`Args`** — positional arguments as a struct; a `[]const []const u8` field is variadic.
- **`Options`** — `bool`/`?bool` fields are flags; other types take values, with defaults from the initializers.
- **`execute`** — the command body, receiving the parsed, typed `Args` and `Options` plus the app context.

The parser is generated from these structs at compile time, so option types are checked when parsing and reading a nonexistent field fails to compile.

For the full contract — variadic rules, boolean negation (`--no-flag`) and how it shapes help, typing `context` for editor autocomplete, and runnable command groups — see **[zcli.sh/docs](https://zcli.sh/docs/#commands)**.
