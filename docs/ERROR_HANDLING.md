# Error Handling in zcli

> **Full guide: [zcli.sh/errors](https://zcli.sh/errors/).** This is a quick
> orientation; the website is the single source of truth for the error model
> and the standalone-parsing API.

Parsing errors are handled for you. The framework parses and validates every argument and option before `execute()` runs, prints a user-friendly diagnostic on failure, and picks the exit code. A mistyped option or command gets a "did you mean?" suggestion computed by edit distance — the same machinery your commands get for free:

```
$ myapp deploy --verbos
Unknown option '--verbos'
Did you mean:
  --verbose
```

The exit code follows the conventional CLI split: `0` success, `2` misuse (a bad/unknown/missing option or argument, or a constraint/validation failure), `3` an unknown (sub)command, and `1` a general failure a command reported itself via `context.fail()`. A closed downstream pipe (`myapp cmd | head`) exits `141` like any well-behaved unix program.

Under the hood everything is a standard Zig error union — a structured `ZcliError` plus an optional `ZcliDiagnostic` carrying the field, position, and expected type. When you parse outside the framework with `zcli.parseCommandLine`, `formatDiagnostic` renders the same messages.

## Reporting errors from a command

Inside `execute()`, use `context.fail` and `context.exit` to report failures yourself:

```zig
pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    if (!std.mem.eql(u8, args.env, "prod") and !std.mem.eql(u8, args.env, "staging")) {
        return context.fail("unknown environment '{s}'", .{args.env});
    }
    // ...
}
```

`context.fail(comptime fmt, args)` prints the formatted message to stderr and returns `error.CommandFailed`, which the framework maps to exit code `1` (see the exit-code table above). It's the standard way for a command to report a general failure of its own without hand-rolling stderr writes and error values.

`context.exit(code: u8) noreturn` flushes buffered stdout/stderr and calls `std.process.exit(code)` directly, for the rarer case where a command needs to terminate with a specific exit code immediately rather than propagating an error up through `execute()`.

For the full `ZcliError` set, diagnostic-driven messages, memory/cleanup rules, and a complete standalone parser, see **[zcli.sh/errors](https://zcli.sh/errors/)**.
