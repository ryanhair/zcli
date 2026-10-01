# Error Handling in zcli

> **Full guide: [zcli.sh/errors](https://zcli.sh/errors/).** This is a quick
> orientation; the website is the single source of truth for the error model
> and the standalone-parsing API.

Parsing errors are handled for you. The framework parses and validates every argument and option before `execute()` runs, prints a user-friendly diagnostic on failure, and picks the exit code. A mistyped option or command gets a "did you mean?" suggestion computed by edit distance — the same machinery your commands get for free:

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
map domain errors and render structured output; see [the migration guide](CLI_MIGRATION.md).
`Failure.isUsage()` classifies retained failures by origin rather than a copied
list of Zig error names.

Under the hood everything is a standard Zig error union — a structured `ZcliError` plus an optional `ZcliDiagnostic` carrying the field, position, and expected type. When you parse outside the framework with `zcli.parseCommandLine`, `formatDiagnostic` renders the same messages.

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
with outcome, status, cause, origin, stage, and retained diagnostics. Release it
with `deinit()`. Framework classification comes from the operation that failed,
not just the error's name.

Help/version, input configuration, and operational preparation are separate
lifecycle stages. Help does not require valid application config or a running
service; invalid command inputs do not run operational preparation. Every
fallible stage enters the same failure path, and secondary failures do not hide
the primary cause. See [ADR-0036](adr/0036-invocation-outcomes.md).

Use `runCommand` for a command body with typed inputs and `runInvocation` for the
full argv-to-outcome contract, including injected stdin and plugin behavior.

For the full `ZcliError` set, diagnostic-driven messages, memory/cleanup rules, and a complete standalone parser, see **[zcli.sh/errors](https://zcli.sh/errors/)**.
