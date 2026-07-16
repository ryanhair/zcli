# zcli Framework Design

## Core Concept

A Zig CLI framework that uses comptime introspection to automatically discover and wire commands based on folder structure, eliminating dispatch overhead and providing type-safe command handling. The framework supports a plugin architecture for extensibility while keeping command discovery and routing entirely at compile time through code generation. (Argument parsing itself runs at invocation, type-checked via comptime introspection.)

## 1. Folder Structure & Command Mapping

```
myapp/
├── build.zig
├── src/
│   ├── main.zig         # Entry point, minimal runtime code
│   └── commands/
│       ├── root.zig      # Optional root command (when no subcommand given)
│       ├── version.zig   # `myapp version` command (leaf command)
│       └── users/
│           ├── index.zig  # `myapp users` command (optional for command groups)
│           ├── list.zig   # `myapp users list`
│           ├── search.zig # `myapp users search <query>`
│           └── create.zig # `myapp users create --name <name>`
```

**Naming Convention Rules:**

- Leaf commands (no subcommands): Use a `.zig` file directly
- Command groups (has subcommands): Use a folder with optional `index.zig`
- File names map directly to command names (kebab-case supported)
- Special file: `root.zig` for base command (optional, executed when no subcommand given)
- Hidden directories (starting with `.`) are automatically skipped
- Underscore-prefixed files and directories (e.g. `_helpers.zig`, `_render/`) are helper code a command imports, never commands themselves
- Maximum nesting depth: 6 levels (configurable)

## 2. Build-Time Command Discovery

Since Zig's comptime cannot access the filesystem, zcli provides a build function that scans the commands directory during the build process:

```zig
// In user's build.zig
const std = @import("std");
const zcli = @import("zcli");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Get zcli dependency
    const zcli_dep = b.dependency("zcli", .{
        .target = target,
        .optimize = optimize,
    });
    const zcli_module = zcli_dep.module("zcli");

    exe.root_module.addImport("zcli", zcli_module);

    // Build with plugins and command discovery
    const cmd_registry = try zcli.generate(b, exe, zcli_dep, .{
        .commands_dir = "src/commands",
        .app_name = "myapp",
        .app_description = "My CLI application",
        // Note: Version is automatically read from build.zig.zon
        .plugins = &.{
            zcli.builtin(.help, .{}),
            zcli.builtin(.version, .{}),
            zcli.builtin(.not_found, .{}),
        },
        // Global options (e.g. --verbose) are declared by plugins,
        // not here — see the Global Options section.
    });

    exe.root_module.addImport("command_registry", cmd_registry);
    b.installArtifact(exe);
}
```

This generates a comptime registry using the Registry builder pattern:

```zig
// Generated command_registry.zig
const std = @import("std");
const zcli = @import("zcli");

// Command imports
const cmd_init = @import("cmd_init");
const cmd_version = @import("cmd_version");
const users_list = @import("users_list");
// ... more command imports

// Plugin imports
const zcli_help = @import("zcli_help");
const zcli_not_found = @import("zcli_not_found");

pub const registry = zcli.Registry.init(.{
    .app_name = "myapp",
    .app_version = "1.0.0",  // This comes from build system
    .app_description = "My CLI application",
})
    .register("init", cmd_init)
    .register("version", cmd_version)
    .register("users list", users_list)
    // ... more command registrations
    .registerPlugin(zcli_help)
    .registerPlugin(zcli_not_found)
    .build();
```

The framework uses comptime introspection on this registry to:

- Build a static command routing table with hierarchical command paths
- Generate all necessary dispatch code without runtime reflection
- Create type-safe argument and option parsing based on command signatures
- Validate plugin conflicts and command uniqueness at compile time

## 3. Command Interface Contract

Each command file exports a standardized structure:

```zig
// Optional: name the app's generated context type for editor hints.
// Omit this and use `context: anytype` for a reusable, app-agnostic command.
const Context = @import("command_registry").Context;

pub const meta = .{
    .description = "Search for users by name",
    .usage = "search <query> [files...] [--limit <n>]",
    .examples = &.{
        "search John",
        "search Jane --limit 10",
        "search Bob file1.txt file2.txt"
    },
    // Optional: document arguments and options
    .args = .{
        .query = "Search query string",
        .files = "Files to search in",
    },
    .options = .{
        .limit = .{ .description = "Maximum number of results" },
        .format = .{ .description = "Output format" },
        .api_key = .{ .description = "API key", .env = "MYAPP_API_KEY" },
    }
};

// Positional arguments (required and optional)
pub const Args = struct {
    query: []const u8,              // Required positional
    files: [][]const u8 = &.{},     // Optional varargs (remaining positionals)
};

// Named options (flags)
pub const Options = struct {
    region: []const u8,             // Required option — must be supplied
    limit: u32 = 10,
    format: enum { json, table } = .table,
    verbose: bool = false,
};

pub fn execute(args: Args, options: Options, context: *Context) !void {
    // Command implementation
    // Access: args.query, args.files, options.limit, etc.
    // Context provides: allocator, io (stdout/stderr/stdin), environment,
    //   plugins.<plugin_id> (type-safe plugin data), and more
}
```

**Positional Arguments Rules:**

- Required args must come before optional args
- Last field can be `[][]const u8` to capture remaining args
- Types supported: `[]const u8`, `u32`, `i32`, `bool`, enums
- Default values make an arg optional

**Options Rules:**

- The field's type says whether it's required. A field with a well-defined
  absent value — `bool` (its declared default, or `false`), optional (`null`), an
  accumulating array (empty), or an explicit default — is **optional**. A field
  with none of those — a non-`bool`, non-optional, non-array field with no default,
  e.g. `region: []const u8` — is a **required option**: the type says a value must
  be provided, so the framework requires one.
- "Required" means *absent after every source*, not *absent from argv*. A required
  option is satisfied by the CLI flag, its declared `.env` variable, or a config
  file (via `zcli_config`); only if none of them supplied it does the command fail,
  with `Missing required option '--region'. Expected text.` and a usage hint.
  (`Args` positionals remain the right home for a value that must appear *on the
  command line* in a fixed position.)
- `bool` and `?bool` are **flags** — they parse by presence and never take a
  value. Each auto-generates a `--no-<flag>` that sets it `false`, so a
  `bool = true` default can be turned off and `?bool` is a true three-state flag
  (absent → `null`, `--flag` → `true`, `--no-flag` → `false`). A boolean may appear
  at most once; repeating it (including `--flag` together with `--no-flag`) is an
  error. `--help` lists the useful spelling: `--flag` for a default-`false` flag,
  `--no-flag` for a default-`true` flag; the other is accepted but hidden.
- An **accumulating array** option (`[][]const u8`, `[]u32`, …) collects multiple
  values two ways, which compose: by **repeating** the flag (`--tag a --tag b`) or
  by a **comma-separated** value (`--tag a,b`, `--tag=a,b`, `-t a,b`). Every value
  token is split on `,`; an empty segment (`a,,b`, `,a`, `a,`) is a value error. A
  literal comma is therefore always a separator here — it cannot appear inside an
  element. `--help` marks these options `(repeatable)`. zcli deliberately does *not*
  support the greedy space-separated form (`--tag a b`): it is ambiguous with zcli's
  interleaved positionals (see ADR-0024).
- Two compile-time guards keep the above coherent: a boolean field's name may not
  start with `no_` (it would collide with a `--no-` negation), and an optional
  field must default to `null` (that `null` is the "not passed" state; use a
  non-optional field with a default for a guaranteed value).

**Environment Variable Fallbacks:**

An option can declare an environment variable as its fallback via
`meta.options.<field>.env`. When the flag is not passed on the command line,
the variable's value is parsed as the field's type. Precedence, highest to
lowest: CLI argument > environment variable > default value.

- `bool`: `1`/`0`, `true`/`false`, `yes`/`no` (case-insensitive)
- strings: used verbatim; integers/floats: parsed; enums: matched by tag name
- A value that doesn't parse as the field's type is ignored (the default stays)

Values come from the environ threaded down from `process.Init` — the
framework performs no ambient `getenv`.

**Option Constraints (cross-field):**

Some rules span more than one option. zcli expresses them with two constraints,
each in its natural home (ADR-0022):

- `meta.exclusive` (command level) — a list of *sets*; at most one member of
  each set may be supplied.
- `meta.options.<field>.requires` (field level) — a list of option field names
  that must also be supplied whenever this field is (a directional dependency).

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
        .{ .json, .yaml, .xml },                        // at most one of these
    },
    .options = .{
        .output_format = .{ .requires = .{.output} },   // needs --output
    },
};
```

Both key off the same notion of "supplied" that required options use — CLI flag,
`.env` variable, or config file — not the option's *value*. Options are named as
enum literals (`.output`) — the same way an option is keyed elsewhere in `meta` —
checked at compile time with `@hasField` (a typo is a build error).
Further comptime guards reject the nonsensical: a field that lists itself in
`requires`, a set with fewer than two members or a duplicated member, and a
*required* option placed in an `exclusive` set (it is always supplied, so it
could never be one of several mutually-exclusive choices).

At runtime the checks run after every source is applied, in order:
missing-required → `requires` → `exclusive`. A violation is reported like any
other parse error and is interceptable by `onError` hooks:

- `Options '--json' and '--yaml' cannot be used together.`
- `Option '--output-format' requires '--output'.`

Exactly-one-of-a-mode needs no constraint: an enum with no default
(`format: enum { json, yaml, xml }`) is already exactly-one, and `?enum … = null`
is at-most-one.

**Per-field validation:**

A field whose *type* is right but whose *value* needs a further rule declares a
`validate` hook — on `meta.options.<field>` or `meta.args.<field>` (ADR-0025):

```zig
pub const Args = struct { name: []const u8 };
pub const Options = struct { port: u16 = 8080 };

pub const meta = .{
    .args = .{ .name = .{ .validate = validateName } },
    .options = .{ .port = .{ .validate = validatePort } },
};

fn validateName(name: []const u8) ?[]const u8 {
    return if (name.len == 0) "must not be empty" else null;
}
fn validatePort(port: u16) ?[]const u8 {
    return if (port == 0) "must be between 1 and 65535" else null;
}
```

The hook is `fn(Base) ?[]const u8`, where `Base` is the field type with one
optional level removed (a `?T` field's hook sees a present value, never null, and
is skipped when absent). Returning `null` means valid; a returned string is the
reason shown to the user. Unlike the constraints above, validation keys off the
*value*: it runs on the finally-resolved value from any source — CLI, env, config,
or default — so no source can slip an invalid value through. A failure is reported
like any other bad-value parse error, with the offending value and a usage hint:

- `Invalid value '0' for option '--port': must be between 1 and 65535.`

Reach for `validate` when the field's native type already parses the input and you
only need an extra rule. When turning the string into your value needs custom
logic (`"5m30s"` → a duration), that is *parsing*, and belongs in a custom type —
see below.

**Custom parse types:**

When the argument string doesn't map straight to a native scalar, give the field a
type that constructs itself, by declaring `pub fn parse`:

```zig
const Duration = struct {
    secs: u64,
    pub const hint = "a duration like 5m30s";
    pub fn parse(s: []const u8) error{ BadFormat, TooLong }!Duration { … }
    pub fn describe(err: error{ BadFormat, TooLong }) []const u8 {
        return switch (err) {
            error.BadFormat => "use a form like 5m30s",
            error.TooLong => "must be under an hour",
        };
    }
};

pub const Options = struct { timeout: Duration = .{ .secs = 30 } };
```

A field type is *custom-parsed* when (after unwrapping one optional level) it is a
struct/union/enum with `pub fn parse(s: []const u8) E!@This()` — an error union, so
it composes with `try` over sub-parsers. `execute` then receives the domain type
itself, valid by construction. Optional companions: `pub const hint` (the
"Expected …" phrase and help placeholder) and `pub fn describe(err)` (a humane
message per failure variant). Every source builds it the same way — CLI and env
parse the string through `parse`, and config does too when the value is a string
(env/config stay lenient: an unparseable value is ignored, never injected). A parse
failure is reported like any other bad value, showing `describe`'s reason when
present, else the hint:

- `Invalid value 'nope' for option '--timeout': use a form like 5m30s.`

This is the division: `validate` refines a value of an existing type; a custom
type *is* the value and owns how it's built. See ADR-0025.

**Context Structure:**

The context provides access to system resources and framework features:

```zig
// Generated per-app as ContextFor(plugins) — sketch of the real thing
// (packages/core/src/context.zig):
pub const Context = struct {
    allocator: std.mem.Allocator,        // arena-per-command (ADR-0001)
    io: std.Io,                          // the explicit-I/O entry point
    environ: *const std.process.Environ.Map,
    theme: zcli.theme.ThemeContext,      // app theme + detected terminal capabilities

    // App metadata (filled by the registry)
    app_name: []const u8,
    app_version: []const u8,
    app_description: []const u8,

    // Command execution context
    command_path: []const []const u8,
    available_commands: []const []const []const u8,

    // Structured detail for the most recent parse/routing error (onError hooks)
    diagnostic: ?zcli.ZcliDiagnostic,

    // Plugin introspection + type-safe per-plugin state
    global_options: []const zcli.OptionInfo,
    plugins: PluginData,                 // context.plugins.<plugin_id>

    // Convenience accessors (buffered — flush before exiting early)
    pub fn stdout(self: *Self) *std.Io.Writer { ... }
    pub fn stderr(self: *Self) *std.Io.Writer { ... }
    pub fn stdin(self: *Self) *std.Io.Reader { ... }
};
```

## 4. Global Options

Global options are declared by plugins: a plugin exports a `global_options` list and a `handleGlobalOption` hook, and the generated registry parses those options before command dispatch (they are consumed by the plugin, not passed to your command):

```zig
// In a plugin (see packages/core/src/plugins/zcli_help/plugin.zig)
pub const global_options = [_]zcli.GlobalOption{
    zcli.option("verbose", bool, .{ .short = 'v', .default = false, .description = "Enable verbose output" }),
};

pub fn handleGlobalOption(context: anytype, option_name: []const u8, value: anytype) !void {
    // stash it on the context (or your plugin's state) for later hooks
}
```

**Framework-Provided Options:**

Plugins can provide global options. For example, the zcli_help plugin provides:

- `--help/-h`: Shows command help
- `--version/-V`: Shows app version (if version plugin is included)

**Naming Convention:**

- CLI flags: underscores become dashes (`no_color` → `--no-color`)
- Zig access: read the value back from the declaring plugin's `ContextData`

**Context Access:**

There is no generated `context.globals` struct. A global option is owned by
the plugin that declares it: `handleGlobalOption` stashes the value on that
plugin's own `ContextData` (see §12, "Type-Safe Context Extensions"), and any
command or hook reads it back through `context.plugins.<plugin_id>`:

```zig
// In the declaring plugin:
pub const plugin_id = "my_plugin";

pub const ContextData = struct {
    verbose: bool = false,
    config: ?[]const u8 = null,
};

pub fn handleGlobalOption(context: anytype, option_name: []const u8, value: anytype) !void {
    if (std.mem.eql(u8, option_name, "verbose")) {
        context.plugins.my_plugin.verbose = value;
    } else if (std.mem.eql(u8, option_name, "config")) {
        context.plugins.my_plugin.config = value;
    }
}
```

```zig
// In any command file (e.g., commands/deploy.zig)
pub fn execute(args: Args, options: Options, context: *Context) !void {
    // Access global options through the plugin that owns them.
    if (context.plugins.my_plugin.verbose) {
        try context.stdout().print("Verbose mode enabled\n", .{});
    }

    // Optional globals use Zig's optional syntax
    if (context.plugins.my_plugin.config) |config_path| {
        try loadConfig(config_path);
    }
}
```

**Global vs Command-Specific Options:**

- **Global options**: Declared by a plugin, stored on that plugin's `ContextData`, and read via `context.plugins.<plugin_id>`
- **Command-specific options**: Defined per-command in the `Options` struct
- **Plugin-provided globals**: Handled by plugins (like `--help`, owned by `zcli_help`'s `ContextData`) and typically don't need explicit access from your own commands

```zig
// Command-specific options stay in the Options struct
pub const Options = struct {
    force: bool = false,        // Only for this command
    output: enum { json, yaml } = .json,
};

pub fn execute(args: Args, options: Options, context: *Context) !void {
    // Mix command-specific options with a plugin-owned global naturally
    if (context.plugins.my_plugin.verbose or options.force) {
        try context.stdout().print("Executing with force\n", .{});
    }
}
```

## 5. Comptime Processing Flow

1. **Discovery Phase**: Build step scans `commands/` directory and generates registry
2. **Validation Phase**: Ensure all command files conform to the interface
3. **Code Generation Phase**: Generate:

   - Command routing table
   - Argument parsing code for each command
   - Help text generation
   - Autocompletion data structures
   - Global options parsing

4. **Runtime Phase**: Minimal code that:
   - Parses argv
   - Handles --help and --version automatically
   - Parses global options
   - Looks up command in static table
   - Calls appropriate handler with parsed args and options (plugins read their own globals off `context.plugins.<plugin_id>`)

## 6. Option Parsing Behavior

**Option Formats:**

- Long options: `--option value` or `--option=value`
- Short options: `-o value` or `-ovalue` (no space). A short exists **only** when
  explicitly declared via `meta.options.<field>.short` — a field never derives a
  short from the first letter of its name. An undeclared short is an unknown
  option (this mirrors global options, which are also explicit-only).
- Boolean flags: `--verbose` (presence = true), `--no-verbose` (= false).
  Negation is long-form only; short flags have no negation.

**Short Option Bundling:**

- Allow: `-abc` equals `-a -b -c` (for boolean flags only)
- Error if bundled with value-taking option: `-abf file` is ambiguous

**Special Handling:**

- `--` stops option parsing (everything after is positional)
- Unknown options: compile-time error if possible, runtime error otherwise
- Case sensitive (no automatic case conversion)

**Value Types and Parsing:**

```zig
// String: --name "John Doe"
name: []const u8

// Optional string: --config file.toml
config: ?[]const u8

// Number: --port 8080
port: u16

// Boolean: --verbose (presence = true)
verbose: bool = false

// Enum: --format json
format: enum { json, yaml, toml }

// Array: --file a.txt --file b.txt
files: [][]const u8
```

**Option Conflicts:**

- Build-time validation prevents two options in one command from declaring the
  same short flag, or resolving to the same long name (`@compileError`)
- Global vs command options with same name: command wins

## 7. Key Design Decisions

**Type-Safe Arguments:**

- Use Zig's type system to define command options
- Generate parsing code at comptime based on struct fields
- Support common types: strings, numbers, enums, optionals, arrays

**Error Handling:**

- Compile-time errors for malformed commands
- Runtime errors only for user input issues
- Clear error messages with suggestions

**Context System:**

- Pass a context struct to all commands
- Contains: stdout, stderr, stdin, environment, and per-plugin `ContextData` (via `context.plugins.<plugin_id>`)
- Enables testing and different output modes

**Progressive Enhancement:**

- Start with basic command mapping
- Add features like middleware, plugins, hooks
- Support async commands naturally with Zig's async

## 8. Help Generation

Help is automatically generated from command metadata and type information:

**App-Level Help (`myapp --help`):**

```
MyApp v1.0.0
A description of what the app does

USAGE:
    myapp [GLOBAL OPTIONS] <COMMAND> [ARGS]

COMMANDS:
    users     Manage users
    config    Configure the application
    version   Show version information

GLOBAL OPTIONS:
    -h, --help       Show help information
    -V, --version    Show version information
    -v, --verbose    Enable verbose output
    --config FILE    Path to config file

Run 'myapp <command> --help' for more information on a command.
```

**Command Group Help (`myapp users --help`):**

```
Manage users

USAGE:
    myapp users <SUBCOMMAND>

SUBCOMMANDS:
    list      List all users
    search    Search for users
    create    Create a new user
```

**Command Help (`myapp users search --help`):**

```
Search for users by name

USAGE:
    myapp users search [OPTIONS] <QUERY> [FILES]...

ARGS:
    <QUERY>       Search query
    [FILES]...    Optional files to search in

OPTIONS:
    --limit N     Maximum results to return (default: 10)
    --format FMT  Output format: json, table (default: table)

EXAMPLES:
    myapp users search John
    myapp users search Jane --limit 10
    myapp users search Bob file1.txt file2.txt
```

**Error Context Help:**
When a user makes an error, show relevant help subset:

```
Error: Unknown subcommand 'searh' for 'users'

Did you mean 'search'?

Available subcommands for 'users':
    list      List all users
    search    Search for users
    create    Create a new user
```

**Generation Rules:**

- Help text is 100% auto-generated from types and metadata
- Examples in `meta.examples` are optional but recommended
- Descriptions come from `meta.description`
- Argument/option help from struct field comments or metadata
- Type information determines argument format (required vs optional)

## 9. Error Context and Recovery

Smart error handling helps users recover from mistakes:

**Command Not Found:**

```
Error: Unknown command 'ustats'

Did you mean one of these?
    stats    Show statistics
    status   Show current status
    users    Manage users

Run 'myapp --help' to see all available commands.
```

**Subcommand Errors:**

```
Error: 'myapp users delete' expects at least 1 argument

USAGE:
    myapp users delete [OPTIONS] <USER-ID>

Run 'myapp users delete --help' for more information.
```

**Invalid Option Values:**

```
Error: Invalid value 'abc' for option '--port'
Expected: u16 (number between 0 and 65535)
```

**Unknown Options:**

```
Error: Unknown option '--formt'

Did you mean '--format'?

Run 'myapp users list --help' to see available options.
```

**Error Design:**

- Similarity matching using edit distance for suggestions
- Only suggest if distance < 3 edits, max 3 suggestions
- Always show what was expected
- Provide path to relevant help

**Exit Codes:**

- 0: Success
- 1: General error
- 2: Misuse (wrong arguments/options)
- 3: Command not found

## 10. Build System Integration

**Package Setup:**

```zig
// build.zig.zon
.{
    .name = "myapp",
    .version = "1.0.0",
    .dependencies = .{
        .zcli = .{
            .url = "https://github.com/user/zcli/archive/v0.1.0.tar.gz",
            .hash = "...",
        },
    },
}
```

**Complete build.zig:**

```zig
const std = @import("std");
const zcli = @import("zcli");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const zcli_dep = b.dependency("zcli", .{
        .target = target,
        .optimize = optimize,
    });
    const zcli_module = zcli_dep.module("zcli");
    exe.root_module.addImport("zcli", zcli_module);

    // zcli build integration
    const cmd_registry = try zcli.generate(b, exe, zcli_dep, .{
        .commands_dir = "src/commands",
        .app_name = "myapp",
        .app_description = "My awesome CLI app",
        // Version automatically read from build.zig.zon
    });
    exe.root_module.addImport("command_registry", cmd_registry);

    b.installArtifact(exe);
}
```

**Minimal main.zig:**

```zig
const std = @import("std");
const registry = @import("command_registry");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var app = registry.init();
    try app.run(init.gpa, init.io, init.environ_map, args);
}
```

`run` already reports the error, dispatches `onError` hooks, and calls
`std.process.exit` with the appropriate status (see "Exit Codes" above) —
there is no error to catch in `main`.

## 11. Plugin System

Plugins extend zcli functionality through lifecycle hooks and can provide commands, global options, and custom behavior:

**Plugin Interface:**

```zig
// Example plugin structure
pub const global_options = [_]zcli.GlobalOption{
    zcli.option("verbose", bool, .{ .short = 'v', .default = false, .description = "Verbose output" }),
};

// Lifecycle hooks (all optional). Plugins are compiled independently of the
// host app, so hooks take `context: anytype` rather than a named Context type.
pub fn handleGlobalOption(context: anytype, name: []const u8, value: anytype) !void { }
pub fn preParse(context: anytype, args: []const []const u8) ![]const []const u8 { }
pub fn transformArgs(context: anytype, args: []const []const u8) !zcli.TransformResult { }
pub fn postParse(context: anytype, args: zcli.ParsedArgs) !?zcli.ParsedArgs { }
pub fn preExecute(context: anytype, args: zcli.ParsedArgs) !?zcli.ParsedArgs { }
pub fn postExecute(context: anytype, result: anytype) !void { }
pub fn onError(context: anytype, err: anyerror) !bool { }

// Fill option fields from a lower-precedence source (e.g. a config file) after
// CLI + env parsing but before required/dependency validation. `provided` has
// one flag per Options field (declaration order), true when CLI or the field's
// env fallback already set it — the hook MUST skip those fields, which is what
// makes CLI > env > config hold. `options` is mutated in place; no error union,
// so a malformed source warns-and-skips rather than bricking the command. Any
// values written must outlive execution (zcli_config uses a ContextData arena).
pub fn applyConfigDefaults(context: anytype, comptime OptionsType: type, options: *OptionsType, provided: []const bool) void { }

// Plugin can provide commands (also app-agnostic, so `context: anytype`)
pub const commands = struct {
    pub const help = struct {
        pub const Args = struct { command: ?[]const u8 = null };
        pub const Options = struct {};
        pub const meta = .{ .description = "Show help for commands" };
        pub fn execute(args: Args, options: Options, context: anytype) !void { }
    };
};
```

**Plugin Registration:**

Plugins are registered in build.zig:

```zig
const cmd_registry = try zcli.generate(b, exe, zcli_dep, .{
    .plugins = &.{
        zcli.builtin(.help, .{}),                                 // ships with zcli
        zcli.builtin(.not_found, .{}),
        // third-party plugin shipped as its own Zig package:
        .{ .name = "my_plugin", .dependency = b.dependency("my_plugin", .{ .target = target, .optimize = optimize }) },
    },
    // A plugin in your OWN source tree is auto-discovered instead — drop it
    // under `.plugins_dir` (not listed here). See ADR-0006 and examples/ext-plugin.
    .plugins_dir = "src/plugins",
    // ... other config
});
```

**Plugin Execution Order:**

1. Plugins are sorted by priority at compile time — a plugin may declare `pub const priority: i32` (default 50); higher values run first, and ties keep registration order
2. All `preParse` hooks called, threading each plugin's rewritten argv into the next
3. Global options are extracted from argv and dispatched to each declaring plugin's `handleGlobalOption`
4. All `transformArgs` hooks called (each may rewrite argv or stop processing)
5. Command resolution routes to the matched command, then all `postParse` hooks called, threading each plugin's replacement `ParsedArgs`
6. All `preExecute` hooks called before command execution (a plugin may cancel execution by returning `null`)
7. Argv is parsed into the command's `Args`/`Options`
8. All `applyConfigDefaults` hooks called after CLI/env parse — filling options no higher-precedence source set — then required/dependency/exclusive/per-field validation runs
9. Command executes
10. All `postExecute` hooks called after execution (success or a handled failure)
11. On error at any stage above, `onError` hooks called until one handles the error

**Built-in Plugins:**

- **zcli_help**: Provides `--help` flag and help command
- **zcli_not_found**: Provides command suggestions using edit distance

## 12. Advanced Features

**Subcommand Inheritance:**

- Commands can inherit options from parent commands
- Shared validation and preprocessing

**Command Aliases:**

- Define aliases in command metadata
- Multiple paths to same handler

**Interactive Mode:**

- Optional REPL for command exploration
- Tab completion using comptime-generated data

**Type-Safe Context Extensions:**

Plugins attach their own state to the context with full compile-time type
safety — there is no `StringHashMap` or runtime key lookup. A plugin declares a
`plugin_id` and a `ContextData` struct; the generated `Context` contains one
field per plugin, named by `plugin_id`, and accessed as
`context.plugins.<plugin_id>`. Because `plugin_id` becomes that field name
verbatim it must be a valid Zig identifier — declaring `ContextData` without a
`plugin_id`, or giving one that isn't (`"my-plugin"`), is a compile-time error
naming the plugin and the fix; there is no silent rewriting:

```zig
// In the plugin:
pub const plugin_id = "my_plugin";

pub const ContextData = struct {
    allocator: ?std.mem.Allocator = null,
    database: ?*Database = null,
    verbose: bool = false,
};

// Optional setup hook, called once per invocation after the framework fills the
// core context fields (allocator, io, app_name, environ, streams) and before any
// lifecycle hook. Capture borrowed references off `context` here so the methods
// on `context.plugins.<plugin_id>` can serve calls without the command
// re-threading `context`. Requires ContextData; may fail (aborts the command):
pub fn initContextData(data: *ContextData, context: anytype) !void {
    data.allocator = context.allocator;
}

// Optional cleanup hook, called from Context.deinit(). Runs for every plugin
// that declares one, whether or not its initContextData ran or succeeded, so it
// must be safe on default-valued data:
pub fn deinitContextData(data: *ContextData, allocator: std.mem.Allocator) void {
    if (data.database) |db| db.close(allocator);
}

// Access in any hook or command:
pub fn execute(args: Args, options: Options, context: *Context) !void {
    if (context.plugins.my_plugin.database) |db| {
        // Use db — fully typed, no casts, no lookups
    }
}
```

`ContextData` structs must be default-constructible; the generated `Context`
initializes each plugin's field to `.{}`, then — for plugins that declare
`initContextData` — the dispatcher calls that hook once per invocation (via
`context.initPluginData()`) before any lifecycle hook. See `ContextFor`
in `packages/core/src/context.zig`.

**Typing the `context` parameter:**

The `Context` type is computed per-app from your `config` + plugin set, so each
app has its own concrete type. A command can name it in two ways — both receive
the same value (a `*Context`, passed by the dispatcher):

```zig
// Option A — concrete type (recommended for app-local commands).
// Full autocomplete, go-to-definition, and errors at the definition site.
const Context = @import("command_registry").Context;

pub fn execute(args: Args, options: Options, context: *Context) !void { ... }
```

```zig
// Option B — generic (for reusable/library commands and plugin hooks).
// Portable across any app, but no editor hints on `context`.
pub fn execute(args: Args, options: Options, context: anytype) !void { ... }
```

Naming the concrete type does **not** create an import cycle: `command_registry`
imports the command modules, but `Context` depends only on `config` + plugins —
never on the commands — so the back-reference resolves cleanly. The build wires
`command_registry` as an available import for every command module (see
`createDiscoveredModules` in `packages/core/src/build_utils/module_creation.zig`).
Plugin hooks stay `anytype` because a plugin is compiled independently of the
app that hosts it.

## 13. Terminal Output & Rendering

Beyond command dispatch, zcli ships a family of terminal-output packages that a
command reaches through its `context`:

- **`theme`** — semantic styling. A comptime `Palette` maps roles
  (`success`, `command`, `path`, …) to styles; component tokens
  (`prompts.cursor`, `progress.spinner`, `surface.border`/`surface.panel`)
  default to those roles. Every styling default derives from the root
  `zcli_theme` at comptime (ADR-0020), so `ui.panel` and bordered boxes need no
  call-site style and `ui.role(r)` styles by meaning in one word. Everything
  resolves against the detected terminal capability, from true color down to
  `NO_COLOR`. See ADR-0012, ADR-0020.
- **`prompts`** — eight interactive prompt types (`text`, `select`,
  `multiSelect`, `search`, …) with grapheme-aware line editing, falling back to
  line input when stdin is not a TTY.
- **`progress`** — spinners for indeterminate work and progress/multi-bars for
  known totals; animations on a TTY, plain lines when piped.
- **`markdown`** — comptime-baked ANSI formatting used by the help pipeline
  (zero runtime cost; ADR-0012).

**The layout engine (`packages/ui`, ADR-0013).** `prompts` and `progress` do
not hand-roll cursor movement or repainting — they render on a shared
terminal-native layout engine. Output splits into a **static stream** that flows
into scrollback (`app.emit`) and a **live region** that repaints in place just
above it (`app.frame`) — a full layout area, from a single line up to the whole
viewport, positioned above committed scrollback rather than a fixed bottom strip.
This is the same static-above / live-below split as Ink's `<Static>` and dynamic
render: in this hybrid mode the engine shares the screen instead of taking it
over (no alternate screen buffer), so scrollback is preserved (ADR-0013). The
live region is immediate-mode: a
component is a function returning a `Node`; each frame the tree is rebuilt into a
per-frame arena, measured, painted onto a cell `Surface`, and diffed against the
previous frame, so only changed cells reach the terminal. Four node kinds
(`box`, `text`, `spacer`, `custom`) and three sizing words (`fit`, `len`,
`fill`) cover the vocabulary; the region re-measures against the terminal each
frame, so it re-lays-out on resize and clamps to the viewport. This is the
CLI/TUI hybrid — the shape of modern agent-style CLIs — exposed directly as
`zcli.ui` / `context.ui(.{})`. Even a hybrid `App` hides the cursor and (for a
prompt) rides the caller's raw mode, so every `App` requires a `pub const panic =
zcli.ui.panic` hook in the root source file — enforced at compile time in
`App.init` so a panic can't strand the terminal past a skipped `deinit`.

**Full-screen mode (ADR-0015).** When an app wants the whole terminal instead of
sharing it — a `top`-style dashboard, an interactive form — the same node tree,
layout, and diff run on the alternate screen: `context.uiFullScreen(.{})` (or
`App.initFullScreen` standalone). The same panic hook every `App` requires
matters most here — a wedged alt-screen needs `reset`, not merely a lost cursor.
`App.run` owns the
`frame → nextEvent → update` loop — `view(arena, state)` builds the tree,
`update(state, event)` mutates state for a key/resize/mouse/focus/paste event or
a deadline-scheduled `null` tick and returns `keep`/`quit`, and an optional
post-frame hook places the hardware cursor. On top sit focusable widgets
(`TextInput`/`Select`/`Checkbox`/`Button`, immediate-mode structs routed by a
single `handle`-returns-`bool` contract with caller-owned focus), overlays (a
`stack` of z-layers with `center`), scrollable `viewport`s, and anchored popups
(`probe`/`positioned`/`anchored`, flipping and clamping to stay on screen). On
exit the shell's screen and scrollback return exactly as they were — the final
frame does not persist. `emit` is a compile-time error here; everything is the
frame.

**Construction idiom (ADR-0014).** `context.X()` is the single front door for
every output capability: `context.theme`, `context.prompts()`,
`context.progress()`, `context.markdown()`, `context.ui(.{})` each hand back an
instance already wired to the command's streams, allocator, io, and theme. The
stateless packages (`prompts`, `progress`, `markdown`) are value bundles — the
import *is* the type — so standalone use fills the same fields by hand;
stateful ones (`ui.App`) keep `init`/`deinit`. Each package also works without
the framework and is published independently.

## 14. Developer Experience

**Zero-Cost Dispatch:**

- All discovery and wiring happens at compile time
- Final binary has direct function calls — no reflection, no runtime filesystem scan
- No dynamic dispatch (argument parsing still runs at invocation)

**Type Safety:**

- Command arguments are fully type-checked
- Impossible to call commands with wrong types
- IDE support through Zig's type system

**Testing:**

- Commands are just functions, easy to unit test
- Mock context for isolated testing
- Integration test helpers

This design leverages Zig's unique comptime capabilities to create a framework that's both developer-friendly (automatic discovery, type safety) and extremely efficient (zero-cost static dispatch, no reflection).
