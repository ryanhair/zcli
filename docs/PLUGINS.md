# Plugins

Plugins extend every command in an app with lifecycle hooks, global options, and their own commands. zcli ships with eight; the help/version/not-found trio is what most apps start with.

| Plugin | Provides | Default? |
|--------|----------|----------|
| **zcli_help** | `--help` / `-h`, auto-generated help text | Yes |
| **zcli_version** | `--version` / `-V` | Yes |
| **zcli_not_found** | "Did you mean?" suggestions for typos | Yes |
| **zcli_completions** | `completions generate/install/uninstall` for bash, zsh, fish | Optional |
| **zcli_config** | Transparent config file loading (JSON, TOML, YAML) | Optional |
| **zcli_output** | `--output` flag (json, table, plain) | Optional |
| **zcli_secrets** | Opt-in credential storage in the OS keychain (get/set/delete) | Optional |
| **zcli_github_upgrade** | `upgrade` command via GitHub releases | Optional |

Add them in `build.zig`:

```zig
const cmd_registry = try zcli.generate(b, exe, zcli_dep, .{
    .commands_dir = "src/commands",
    .plugins = &.{
        zcli.builtin(.help, .{}),
        zcli.builtin(.version, .{}),
        zcli.builtin(.not_found, .{}),
        zcli.builtin(.config, .{}),
    },
    .app_name = "myapp",
    .app_description = "My CLI application",
});
```

## Plugin context data

Plugins store data in `context.plugins.{plugin_id}` — a typed field on your app's generated `Context`:

```zig
// In a command, check if help was requested
if (context.plugins.zcli_help.help_requested) { ... }
```

## Config file plugin

The `zcli_config` plugin transparently loads option defaults from a config file. Supports JSON, TOML, and YAML — no changes to command code required.

```zig
// In build.zig plugins:
zcli.builtin(.config, .{}),
```

Config file discovery (by extension priority):
1. `--config <path>` flag
2. `.{app_name}.config.json` / `.toml` / `.yaml` / `.yml` (in the current directory)
3. `$XDG_CONFIG_HOME/{app_name}/config.json` / `.toml` / `.yaml` / `.yml`

Values cascade: **CLI flags > command config > global config > struct defaults**.

```json
// .myapp.config.json
{
  "output": "json",         // global — applies to all commands
  "list": {                 // scoped — applies only to "list" command
    "all": true
  }
}
```

```toml
# .myapp.config.toml
output = "json"

[list]
all = true
```

```yaml
# .myapp.config.yaml
output: json
list:
  all: true
```

## Writing plugins

A plugin is a Zig module with a `plugin_id` and any of the lifecycle exports:

```zig
pub const plugin_id = "my_plugin";
pub const ContextData = struct { enabled: bool = false };
```

`plugin_id` becomes the `context.plugins.<id>` field name **verbatim**, so it must be a valid Zig identifier (`[a-zA-Z_][a-zA-Z0-9_]*` — in practice lowercase `snake_case`). A plugin that declares `ContextData` without a `plugin_id`, or gives one that isn't a valid identifier (e.g. `"my-plugin"`), fails at compile time with a message naming the plugin and the fix. zcli does **not** silently rewrite an invalid id — you choose the field name you'll type.

```zig
pub const global_options = [_]zcli.GlobalOption{
    zcli.option("verbose", bool, .{ .short = 'v', .default = false }),
};

pub fn handleGlobalOption(context: anytype, name: []const u8, value: anytype) !void {
    // Store option values in context.plugins.my_plugin
}

pub fn preExecute(context: anytype, args: zcli.ParsedArgs) !?zcli.ParsedArgs {
    // Run before every command. Return null to stop execution.
    return args;
}

pub fn onError(context: anytype, err: anyerror) !bool {
    // Handle errors. Return true if handled.
    return false;
}
```

Plugins can also ship their own commands (the completions plugin's `completions` subcommands work this way). Type hook parameters `anytype` — a plugin is compiled independently of the app that hosts it, so it can't import the app's `Context`.

For how plugins are discovered, merged with native commands, and wired into the generated registry, see [BUILD.md](BUILD.md). Local (in-repo) plugins can be picked up automatically via `plugins_dir`.
