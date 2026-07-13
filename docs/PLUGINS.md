# Plugins

> **Full reference: [zcli.sh/plugins](https://zcli.sh/plugins/).** This is a quick
> orientation; the website is the single source of truth for the built-in list,
> config-file behavior, and the plugin-authoring contract.

Plugins extend every command in an app with lifecycle hooks, global options, and their own commands. zcli ships with a set of built-ins — the help/version/not-found trio is what most apps start with, and completions, config files, OS-keychain secrets, and GitHub self-upgrade are opt-in. Enable them in `build.zig`:

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

Plugins store typed data in `context.plugins.<plugin_id>` on your app's generated `Context`:

```zig
if (context.plugins.zcli_help.help_requested) { ... }
```

A plugin is a Zig module with a `plugin_id` and any of the lifecycle exports (`global_options`, `handleGlobalOption`, `preExecute`, `onError`); it can also ship its own commands. Hook parameters are typed `anytype` — a plugin is compiled independently of the app that hosts it.

For the full built-in list, `plugins_dir` auto-discovery, and the complete plugin-authoring guide, see **[zcli.sh/plugins](https://zcli.sh/plugins/)**; config-file discovery and the value cascade have their own guide at **[zcli.sh/docs/config](https://zcli.sh/docs/config/)**. For how plugins are discovered and merged into the generated registry, see [BUILD.md](BUILD.md).
