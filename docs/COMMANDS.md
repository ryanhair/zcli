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

## Option constraints

Rules that span more than one option live in `meta`, keyed off whether an option was *supplied* (by CLI flag, `.env` variable, or config) — not its value:

```zig
pub const Options = struct {
    json: bool = false,
    yaml: bool = false,
    xml: bool = false,
    output: ?[]const u8 = null,
    output_format: ?enum { pretty, compact } = null,
};

pub const meta = .{
    // At most one member of each set may be supplied.
    .exclusive = .{
        .{ .json, .yaml, .xml },
    },
    .options = .{
        // --output-format is meaningless without --output.
        .output_format = .{ .requires = .{.output} },
    },
};
```

- **`meta.exclusive`** — a list of *sets*; supplying two members of one set is an error (`Options '--json' and '--yaml' cannot be used together.`). Write a two-element set for a one-off "A conflicts with B".
- **`meta.options.<field>.requires`** — the options that must accompany this one. Directional: `output_format` needs `output`, but `output` alone is fine (`Option '--output-format' requires '--output'.`).

Options are named as enum literals (`.output`), the same way an option is keyed elsewhere in `meta` — verified at compile time (`@hasField`), so a typo is a build error. The compiler also rejects the nonsensical: a field that requires itself, an `exclusive` set with fewer than two (or duplicated) members, and a *required* option in an `exclusive` set (it's always supplied, so it could never be the "at most one"). You don't need a constraint for exactly-one-of-a-mode — an enum with no default (`format: enum { json, yaml, xml }`) already is exactly-one, and `?enum … = null` is at-most-one.

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
