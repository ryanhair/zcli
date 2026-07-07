# Commands

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

## Command structure

Every command has up to four exports:

```zig
const zcli = @import("zcli");
// Name your app's generated context type for full editor autocomplete on `context`.
const Context = @import("command_registry").Context;

pub const meta = .{
    .description = "Add files to the index",
    .examples = &.{ "add file.txt", "add --all" },
    .args = .{ .files = "Files to add" },
    .options = .{
        .all = .{ .short = 'a', .description = "Add all files" },
    },
    .aliases = &.{ "a" },
};

pub const Args = struct {
    files: []const []const u8,          // variadic: captures remaining args
};

pub const Options = struct {
    all: bool = false,                  // --all / -a (flag), or --no-all to force false
    output: []const u8 = "text",        // --output <value>
    count: u32 = 1,                     // --count <number>
    verbose: ?bool = null,              // three-state flag: absent=null, --verbose, --no-verbose
};

pub fn execute(args: Args, options: Options, context: *Context) !void {
    // context.stdout(), context.stderr(), context.allocator, context.theme,
    // context.plugins.<plugin_id>, etc. — all typed and autocompletable.
}
```

- **`meta`** — help text and parsing metadata: `description`, `examples`, per-argument descriptions (`args`), per-option metadata (`options`, including `short` flags), and `aliases`.
- **`Args`** — positional arguments as a struct. A `[]const []const u8` field is variadic and captures all remaining arguments.
- **`Options`** — flags and options as a struct. `bool` and `?bool` fields are **flags** (they never take a value); other types take values, and defaults come from the struct initializers.
  - **Boolean negation.** Every boolean flag `--flag` gets an auto-generated `--no-flag` that sets it to `false`. This is what lets a `bool = true` default be turned off, and it makes `?bool` a genuine three-state flag: absent → `null`, `--flag` → `true`, `--no-flag` → `false`. A boolean may be passed at most once — repeating it, or combining `--flag` with `--no-flag`, is an error. In `--help`, a flag is shown by whichever spelling is useful: a default-`false` flag lists `--flag`, and a default-`true` flag lists `--no-flag` (turning off is the only meaningful action); the other spelling is accepted but hidden.
  - **Write the description for the spelling that shows.** A description says what *passing the shown flag does*. For a default-`false` bool that's the positive form, so describe turning it on (`--verbose` → "Enable verbose output"). For a default-`true` bool only `--no-flag` shows, so describe turning it **off** (`push: bool = true` → "Create the tag but don't push to remote", displayed against `--no-push`). Since the shown spelling is fixed by the default, you always know which direction to write for. Keep the field's own `///` doc comment describing the field for source readers; the meta `description` is the user-facing help text.
  - **Two rules the compiler enforces.** A boolean field's name may not start with `no_` (it would collide with another flag's `--no-` negation). And an optional field (`?T`) must default to `null` — that `null` is the "not passed" state; use a non-optional field with a default when you want a guaranteed value.
- **`execute`** — the command body. Receives the parsed, typed `Args` and `Options` plus the app context.

The parser is generated from these structs at compile time, so an option's type is checked when parsing its value, and code that reads a nonexistent field fails to compile.

## Typing `context`

`Context` is generated per-app from your config and plugin set, so it carries a
typed field for every plugin's data (`context.plugins.<plugin_id>`). You can type
the parameter two ways:

- **`context: *Context`** (above) — import `@import("command_registry").Context`.
  Best for app-local commands: full autocomplete, go-to-definition, and errors at
  the definition site. There's no import cycle — `Context` depends only on your
  config and plugins, not on the command files.
- **`context: anytype`** — portable across apps with no editor hints. Use this for
  reusable/library commands and inside plugin hooks (a plugin is compiled
  independently of the app that hosts it).

## Command groups

Add an `index.zig` to give a directory a description:

```zig
// src/commands/users/index.zig
pub const meta = .{ .description = "Manage users" };
// No execute — running "myapp users" shows subcommands
```

Give `index.zig` an `execute` and the group itself becomes runnable — `myapp users` runs it, while `myapp users create` still routes to the subcommand. A runnable group must declare an empty `Args` struct (positional arguments would be ambiguous with subcommand names, so the compiler rejects them); `Options` work as usual.
