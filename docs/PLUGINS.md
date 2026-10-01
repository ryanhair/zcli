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

A plugin is a Zig module with optional lifecycle exports (`onStartup`, `preParse`, `handleGlobalOption`, `transformArgs`, `postParse`, `handleInformation`, `loadConfig`, `applyConfigDefaults`, `prepare`, `onFinish`, `describeFailure`, `renderFailure`); it can also ship its own commands. Declare a stable `plugin_id` when exposing `ContextData` or `CommandConfig`. The context parameter is `anytype` — a plugin is compiled independently of the app that hosts it.

Informational handling runs before application configuration and operational setup.
`loadConfig` supplies input data before validation; `prepare` runs afterward.
Failures in any stage retain their failure status when described or rendered.
`onFinish(context, success)` runs for initialized plugins on success,
informational completion, or failure, including failures before `prepare`.
Its boolean reflects whether a primary error exists when that hook starts;
a completion error makes later hooks receive `false`. Resource teardown must
be safe on default or partially initialized state. Keep startup/initialization
lightweight: those stages run even for help. Operational I/O belongs in
`prepare` or a lazy resource accessor.
See [the invocation lifecycle decision](adr/0036-invocation-outcomes.md).

For the full built-in list, `plugins_dir` auto-discovery, and the complete plugin-authoring guide, see **[zcli.sh/plugins](https://zcli.sh/plugins/)**; config-file discovery and the value cascade have their own guide at **[zcli.sh/docs/config](https://zcli.sh/docs/config/)**. For how plugins are discovered and merged into the generated registry, see [BUILD.md](BUILD.md).

## Acquire resources when commands need them

Put a lazy accessor on `ContextData` when only some commands need a resource.
Capture the invocation's allocator, I/O, and environment during initialization;
connect only when a command calls the accessor:

```zig
// src/plugins/daemon.zig
const std = @import("std");
const Client = @import("app_core").Client;
pub const plugin_id = "daemon";

pub const ContextData = struct {
    allocator: ?std.mem.Allocator = null,
    io: ?std.Io = null,
    environ: ?*const std.process.Environ.Map = null,
    connection: ?Client = null,

    pub fn client(self: *@This()) !*Client {
        if (self.connection == null) {
            self.connection = try Client.connect(self.allocator.?, self.io.?, self.environ.?);
        }
        return &self.connection.?;
    }
};

pub fn initContextData(data: *ContextData, context: anytype) !void {
    data.* = .{ .allocator = context.allocator, .io = context.io, .environ = context.environ };
}

pub fn deinitContextData(data: *ContextData, _: std.mem.Allocator) void {
    if (data.connection) |*connection| connection.deinit();
}

// Inside a command's execute():
const client = try context.plugins.daemon.client();
try client.listCards(context.stdout());
```

`Client.connect`, `listCards`, and `deinit` here are your application's API.
Commands such as `version` never request the client, so they work without reading
its configuration or starting a daemon. Cleanup is safe even if no connection
was acquired. Supply `app_core` through `shared_modules`; project plugins under
`plugins_dir` receive those imports just like commands.

## Command-specific plugin settings

When a plugin needs policy before a command runs, declare a typed config with
defaults. Commands override only the fields they need:

```zig
// src/plugins/audit.zig
pub const plugin_id = "audit";
pub const CommandConfig = struct {
    record: bool = true,
};

pub fn prepare(context: anytype) !void {
    if (context.command_config.audit.record) {
        // Record this routed command.
    }
}

// src/commands/version.zig
pub const meta = .{
    .description = "Show version",
    .plugins = .{ .audit = .{ .record = false } },
};
```

The registry checks plugin names, fields, and values at compile time. Commands
without an override use `CommandConfig` defaults. Aliases use their command's
settings; parent command settings do not implicitly apply to children. See
[ADR-0040](adr/0040-typed-plugin-command-config.md).

Use `CommandConfig` for policy a hook must know before command execution, such
as whether a command is auditable. Resource accessors handle acquisition when
the command actually needs it.

Project plugins under `plugins_dir` can import the same `shared_modules` as
commands. `examples/notes/src/plugins/verbose.zig` imports the shared `log`
module without extra build wiring.

## Failure hooks

`describeFailure(context, failure) !?zcli.failure.Description` adds an optional
identity, message, or explicit silence. Numeric exit mappings belong to the
application's failure policy module, not to plugins. A description never turns a
failed invocation into success.

A plugin renderer has signature
`renderFailure(context, failure: zcli.Failure) !bool`: return `true` after
rendering, or `false` to let another renderer handle it. The application policy
renderer has a different signature and precedence; it owns output with
`renderFailure(context, failure, status) !void`. Both run only after global
handling succeeds. See [ERROR_HANDLING.md](ERROR_HANDLING.md#rendering-and-unexpected-errors).

Legacy `preExecute`, `postExecute`, and `onError` exports are rejected at compile
time. Use `prepare`, `onFinish`, and the description/rendering interfaces instead;
see [CLI_MIGRATION.md](CLI_MIGRATION.md) for the complete migration.
