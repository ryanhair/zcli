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

Under the hood everything is a standard Zig error union — a structured `ZcliError` plus an optional `ZcliDiagnostic` carrying the field, position, and expected type. When you parse outside the framework (`zcli.parseCommandLine`, `parseArgs`, `parseOptions`), `formatDiagnostic` renders the same messages.

For the full `ZcliError` set, diagnostic-driven messages, memory/cleanup rules, and a complete standalone parser, see **[zcli.sh/errors](https://zcli.sh/errors/)**.
