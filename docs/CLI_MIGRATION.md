# CLI experience migration

These changes ship together in the next minor release. The command contract stays
`Args`, `Options`, `meta`, and `execute`; the changes concern input syntax, plugin
lifecycle, failure reporting, and reusable input/output operations.

## Repeatable options preserve their values

An array option collects one element per occurrence. Commas and whitespace inside
an argument remain literal:

```text
--ac "a, b" --ac c     => ["a, b", "c"]
```

To retain delimiter shorthand, declare it explicitly:

```zig
pub const Options = struct { tags: []const []const u8 = &.{} };
pub const meta = .{ .options = .{
    .tags = .{ .delimiter = ',', .description = "Tags" },
} };
```

This option accepts both `--tags a,b` and `--tags a --tags b`. Delimited empty
segments remain errors. There is no CSV quote grammar, automatic trimming, or
greedy consumption of following arguments. Structured config arrays keep their
element boundaries. Audit options individually: free text usually should not
declare a delimiter. See ADR-0024.

## Plugin hooks describe their actual stage

| Previous use | New declaration |
| --- | --- |
| `preExecute` prints help/version and returns null | `handleInformation(context) !zcli.InvocationAction`, returning `.complete` after successful output or `.proceed` |
| `preExecute` loads configuration for options | `loadConfig(context) !void`; retain `applyConfigDefaults` for applying it |
| `preExecute` connects/authenticates/starts a service | `prepare(context) !void`, after validation |
| `preExecute` rewrites raw arguments | `preParse`, `transformArgs`, or `postParse`, according to when the rewrite is needed |
| `postExecute(context, success)` | `onFinish(context, success) !void`, including setup failures |
| `onError` attaches an explanation | `describeFailure(context, failure: zcli.Failure) !?zcli.failure.Description` |
| `onError` prints custom output | `renderFailure(context, failure: zcli.Failure) !bool`; true means rendered, never successful |
| `onError` calls `context.exit(code)` | Application failure policy selects the status; the invocation unwinds normally |

Commands and hooks still return ordinary Zig errors. Do not catch an operational
failure merely to print it and return success. Help/version complete before input
configuration and operational preparation. `postParse` still operates on routed
raw positionals, not the command's final typed options.

`onFinish` must tolerate an invocation that failed before preparation. It is not a
substitute for `deinitContextData`, which remains the unconditional resource
release hook and must be safe on default plugin state. A secondary completion or
renderer failure cannot replace the primary failure.

For resources used by only some commands, prefer lazy acquisition through a
`ContextData` method. A command that never requests a client then neither reads its
configuration nor starts its service. Typed per-command plugin configuration is
available when a hook actually needs declarative policy; it does not require a
command-path skip list.

## Application exit policy

Set framework categories in the ordinary build configuration:

```zig
const registry = try zcli.generate(b, exe, zcli_dep, .{
    .commands_dir = "src/commands",
    .app_name = "board",
    .app_description = "Project board",
    .exit_codes = .{ .usage = 64, .command_not_found = 64 },
    .failure_policy_module = b.createModule(.{
        .root_source_file = b.path("src/failure_policy.zig"),
    }),
});
```

The policy module receives the framework's `zcli` import. For a manual registry,
pass the policy type as `.failure_policy` in `zcli.Registry.init(...)`.

```zig
// src/failure_policy.zig
const zcli = @import("zcli");

pub const error_codes = [_]zcli.failure.ErrorRule{
    .{ .cause = error.NotFound, .command = "card show", .code = 2,
       .id = "card_not_found", .message = "Card not found" },
    .{ .cause = error.Unauthorized, .plugin = "baton", .code = 10,
       .id = "unauthorized", .message = "Sign in before using the board" },
};
```

Omitting both scopes deliberately applies a rule across application/plugin
origins. Framework usage failures are classified by provenance, not error name.
Overlapping rules and zero failure statuses are rejected. Applications own numeric
status policy; plugins can contribute explanations. Command scopes name the
canonical command path, so aliases receive the same status; retained diagnostics
still identify the path the caller used.

`context.fail(fmt, args)` now records an explanation and returns
`error.CommandFailed`; it does not print immediately. Use
`context.failWith(error.NotFound, fmt, args)` to preserve a domain error while
attaching contextual details. Return the error so the invocation can report it.

For structured output, a policy may implement:

```zig
const std = @import("std");

pub fn renderFailure(context: anytype, failure: zcli.Failure, status: u8) !void {
    try std.json.Stringify.value(.{
        .id = failure.id,
        .message = failure.message,
        .status = status,
    }, .{}, context.stderr());
    try context.stderr().writeByte('\n');
}
```

This example always renders JSON; an application may choose its renderer using
successfully handled global state. Before global handling succeeds, failures use
the default renderer. Do not add a second ad hoc argv scan to guess whether a
malformed early invocation requested JSON.

`context.exit()` still exits immediately and bypasses normal cleanup. Normal
reported failures should use the application policy instead.

## Test complete invocations without exiting

The in-process testing module (`zcli_testing_unit`) exports `runInvocation` beside
`runCommand`. The latter still directly calls a command with typed inputs.

```zig
var result = try testing.runInvocation(@import("command_registry"), .{
    .argv = &.{ "card", "show", "missing" },
});
defer result.deinit();
try std.testing.expectEqual(@as(u8, 2), result.invocation.status);
```

Use a test module wired to the real generated registry, not the isolated command
test stub. A compiled registry type also works. `argv` excludes the executable;
stdin defaults to EOF and environment defaults to empty. The result owns captured
streams and retained failure details until `deinit()`.

The production registry also exposes non-exiting `invoke` and `invokeWithStdio`
methods. Error-returning execution methods use the same engine. Process `run()`
applies the final status; subprocess tests remain appropriate for that boundary.

## Explicit stdin text

Mark a scalar or optional text option with `.stdin = true`:

```zig
pub const Options = struct { goal: ?[]const u8 = null };
pub const meta = .{ .options = .{ .goal = .{ .stdin = true } } };
```

`--goal -`, `--goal=-`, and equivalent short forms read stdin once. A config,
environment, or default `"-"` remains literal. Multiple final stdin requests fail
before reading. Existing last-wins scalar semantics apply, so a later literal
value cancels an earlier request. Input is not trimmed or recursively expanded;
`printf '%s' '-' | app --goal -` supplies a literal hyphen.

The default cap is 16 MiB, overridable through `GenerateConfig.stdin_max_bytes`
or the manual registry config. Empty input is a present empty string; validators
see the resolved content. The standalone parser only records requests and performs
no stream reads.

## Project-local imports

Local plugins under `plugins_dir` now receive the project's `shared_modules`, just
like commands and command tests. Remove `b.modules.get(...).addImport(...)`
workarounds for those imports. Framework built-ins and dependency-provided plugins
keep their own dependency declarations.

## Open an editor directly

Use `context.prompts().edit(config)` for an explicit edit command. Unlike the
invitation prompt, it opens immediately and attaches the editor to the controlling
terminal even when the command's stdout is redirected:

```zig
var result = try context.prompts().edit(.{
    .io = context.io,
    .environ = context.environ,
    .default = initial_document,
    .extension = ".md",
});
defer result.deinit(context.allocator);
switch (result) {
    .edited => |document| try saveDocument(document),
    .failed => |failure| {
        if (failure.recovery_path) |path|
            return context.fail("Editor failed; recover your changes from {s}", .{path});
        return context.fail("Editor failed", .{});
    },
}
```

Successful empty and unchanged documents are valid; bytes and final newlines are
preserved. Failure data distinguishes launch, terminal, exit, and read-back
problems. Changed or unreadable scratch files survive failures by default;
`deinit` frees the recovery path without deleting the saved file.

Supply `.argv` for programmatic editor configuration. `editor_cmd`, VISUAL, and
EDITOR use shell-word quoting without shell expansion, so `code --wait` and an
explicit `sh -c '...'` work. The existing `editor` prompt retains its invitation
and noninteractive stdin fallback; `.immediate = true` skips the invitation when
interactive. Use `edit` directly when stdout redirection must not change behavior.
See ADR-0038 for ownership, limits, and platform behavior.

## Print a static table

Use the context's output capability for ordinary list commands:

```zig
try context.table().print(&.{
    .{ .header = "ID" },
    .{ .header = "Title", .shrink_priority = 1, .overflow = .wrap },
}, rows);
```

Columns support left/right alignment, preferred minimum and maximum widths, and
shrink priority. Terminal output fits the detected width; a column can truncate
or wrap. Redirected output preserves full multiline cell content without color.
Input ANSI control sequences are removed and widths use visible graphemes.
Standalone callers can construct `zcli.ui.StaticTable` with a writer, allocator,
theme, and optional terminal width. No interactive UI session is created.

## Typed command configuration for plugins

Prefer lazy resource acquisition when a command can simply request what it needs.
For declarative policy, a plugin declares a defaulted schema:

```zig
pub const plugin_id = "baton";
pub const CommandConfig = struct { needs_daemon: bool = true };

pub fn prepare(context: anytype) !void {
    if (context.command_config.baton.needs_daemon) {
        // Acquire the client used by this command.
    }
}
```

A command overrides fields within that plugin's namespace:

```zig
pub const meta = .{
    .description = "Print the version",
    .plugins = .{ .baton = .{ .needs_daemon = false } },
};
```

Unknown plugin names and fields are compile errors. Commands without overrides
receive the plugin defaults; group configuration does not implicitly cascade to
children. Aliases resolve to the same command configuration. Context types depend
on plugin schemas, so adding command metadata does not change their type identity.
