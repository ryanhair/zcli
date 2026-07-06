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
    all: bool = false,                  // --all / -a (flag)
    output: []const u8 = "text",        // --output <value>
    count: u32 = 1,                     // --count <number>
    verbose: ?bool = null,              // optional flag
};

pub fn execute(args: Args, options: Options, context: *Context) !void {
    // context.stdout(), context.stderr(), context.allocator, context.theme,
    // context.plugins.<plugin_id>, etc. — all typed and autocompletable.
}
```

- **`meta`** — help text and parsing metadata: `description`, `examples`, per-argument descriptions (`args`), per-option metadata (`options`, including `short` flags), and `aliases`.
- **`Args`** — positional arguments as a struct. A `[]const []const u8` field is variadic and captures all remaining arguments.
- **`Options`** — flags and options as a struct. `bool` fields are flags, other types take values, defaults come from the struct initializers, and optional types (`?T`) distinguish "not passed" from "passed the default".
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
