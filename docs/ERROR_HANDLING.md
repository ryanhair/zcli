# Error Handling in zcli

> **Full guide: [zcli.sh/errors](https://zcli.sh/errors/).** This is a quick
> orientation; the website is the single source of truth for the error model
> and the standalone-parsing API.

The framework parses and validates arguments and options before `execute()` runs, renders structured diagnostics, and picks the exit code. A mistyped option or command gets a "did you mean?" suggestion computed by edit distance — the same machinery your commands get for free:

```
$ myapp deploy --verbos
Error: Unknown option '--verbos'
Did you mean:
  --verbose

Run 'myapp deploy --help' for usage.
```

The default exit codes are: `0` success, `2` misuse (a bad/unknown/missing option or argument, or a constraint/validation failure), `3` an unknown (sub)command, and `1` a general failure a command reported itself via `context.fail()`. A closed downstream pipe (`myapp cmd | head`) exits `141` like any well-behaved unix program.

Configure `.exit_codes = .{ .usage = 64, .command_not_found = 64 }` in
`GenerateConfig` to change framework statuses. An application failure policy can
map domain errors and render structured output; see [build configuration](BUILD.md#invocation-policy-configuration).
`Failure.isUsage()` classifies retained failures by origin rather than a copied
list of Zig error names.

Parsing functions return a Zig error union (`ZcliError`) and can populate an optional `ZcliDiagnostic` carrying the field, position, and expected type. The invocation result retains the underlying error together with its framework category, origin, stage, and diagnostic. When you parse outside the framework with `zcli.parseCommandLine`, `formatDiagnostic` renders the same messages.

## Reporting errors from a command

Inside `execute()`, return `context.fail` to report an expected failure:

```zig
pub fn execute(args: Args, options: Options, context: anytype) !void {
    if (!std.mem.eql(u8, args.env, "prod") and !std.mem.eql(u8, args.env, "staging")) {
        return context.fail("unknown environment '{s}'", .{args.env});
    }
    // ...
}
```

`context.fail(comptime fmt, args)` records the formatted explanation and returns
`error.CommandFailed`. The invocation engine chooses the status (default `1`) and
renderer after the command unwinds. Returning this error reports a failure even
when an application renderer handles its output; printing a message and returning
normally would report success.

`context.exit(code: u8) noreturn` flushes buffered stdout/stderr and calls `std.process.exit(code)` directly, for the rarer case where a command needs to terminate with a specific exit code immediately rather than propagating an error up through `execute()`.

Normal failures should use the invocation result and application exit policy:
`context.exit()` bypasses normal unwinding and cannot be intercepted by an
in-process test. The non-exiting invocation interface returns an owned result
with outcome and status; a failure outcome contains cause, origin, stage, and
retained diagnostics. Release it with `deinit()`. Framework classification comes from the operation that failed,
not just the error's name.

Help/version, input configuration, and operational preparation are separate
lifecycle stages. Help completes before `loadConfig` and `prepare`; keep
initialization and startup lightweight because those still run. Invalid command
inputs do not run operational preparation. Every
fallible stage enters the same failure path, and secondary failures do not hide
the primary cause. See [ADR-0036](adr/0036-invocation-outcomes.md).

Use `runCommand` for a command body with typed inputs and `runInvocation` for the
full argv-to-outcome contract, including injected stdin and plugin behavior.

For the full `ZcliError` set, diagnostic-driven messages, memory/cleanup rules, and a complete standalone parser, see **[zcli.sh/errors](https://zcli.sh/errors/)**.

## Rendering and unexpected errors

A failure policy module may export `error_codes: []const zcli.failure.ErrorRule`,
`describeFailure(context, failure) !?zcli.failure.Description`, and
`renderFailure(context, failure, status) !void`. An array of `ErrorRule` values
also works. Rules apply only to command/plugin failures, never framework usage
errors. A command scope uses its canonical registered path (space-separated for
nested commands); a plugin scope uses its `plugin_id`. An unscoped rule applies
across command and plugin origins. Overlapping rules and status zero are rejected
at compile time. Scoped names must match their registered targets exactly.

The policy renderer owns the complete output when called: returning successfully,
even without writing bytes, marks the failure reported. It cannot decline by
returning `false`. A plugin's `renderFailure(context, failure) !bool` can decline;
`true` claims output, and `false` allows the next renderer or human fallback.
When an application renderer is registered, it takes precedence over plugins.
Choose and implement all desired output formats inside it, or use a plugin
renderer for conditional handling.

Renderers run only after all global option handling succeeds. Failures during
startup, argument preprocessing, or global handling use human fallback, since
output-mode state may be incomplete. Describers can still run at those stages
and must tolerate default state. Plugin description/rendering hooks run only for
successfully initialized plugins. Renderer writes through context stdout/stderr
are staged: an error discards that renderer's buffered bytes and records a
secondary failure before trying fallback.

`run()` propagates an unexpected error to `main` with its original trace only
when the failure remains unreported and has neither a message nor an identity.
A custom renderer that reports an unexpected error suppresses the default Zig
trace; the status remains nonzero and the retained result still has its cause
and trace (when tracing is enabled). A description with a message or identity
classifies an otherwise unexpected error as an application failure.
`invoke()`/`invokeWithStdio()` return the owned result instead of exiting.
Their argv excludes the executable name; `run()` receives the complete process
argv and removes that first element.
