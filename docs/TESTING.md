# Testing zcli Applications

> **Full guide: [zcli.sh/testing](https://zcli.sh/testing/).** This is a quick
> orientation; the website is the single source of truth for the testing API.

zcli provides three tiers of testing — use them together for coverage without slow feedback loops:

| Tier | What it tests | Speed |
|------|--------------|-------|
| **Unit** | Command logic in isolation — `execute()` only, in-process | Fast |
| **Integration** | The full CLI binary via subprocess — arg parsing, routing, output | Medium |
| **E2E** | Interactive terminal behavior — prompts, signals, TTY output | Slow |

Unit tests run against a real virtual terminal (`vterm`) that parses ANSI output, so you assert on colors and formatting, not raw escape codes:

```zig
const testing = @import("zcli-testing");

test "deploy command" {
    var result = try testing.runCommand(DeployCommand, .{
        .args = .{ .service = "api" },
        .options = .{ .env = "staging" },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Deploying api to staging\n", result.stdout);
    try std.testing.expect(result.term.hasAttribute(0, 0, .bold));
}
```

Beyond `.args`/`.options`, the config carries `.plugins` (plugin `ContextData`),
`.environ`, `.stdin`, `.app_name`/`.app_version`/`.app_description`, and
`.allocator`:

```zig
var result = try testing.runCommand(SetupCommand, .{
    // One line per answer; an empty line takes the prompt's default.
    .stdin = "Ada\n\n",
    // What a real run would get from the registry's Config, rather than
    // the context defaults ("app" / "unknown" / ""). In place before
    // plugin initContextData hooks run.
    .app_name = "myapp",
    .app_version = "1.2.3",
});
```

`.stdin` is an in-memory stream that ends at EOF, and `context.prompts()`
reports non-interactive whenever stdout is captured or stdin injected — so
prompts take their **line-based** branch no matter what the process's own
descriptors are, and a `runCommand` test can never reach the real terminal.
Raw-mode keystrokes (arrows through a `select`, hidden input, Ctrl-C) are not
modeled by a byte stream and belong in the PTY-backed E2E tier.

Unit tests only run under `zig build test` if `build.zig` wires
`zcli.addCommandTests(b, exe, zcli_dep, .{ .commands_dir = "src/commands", ... })` —
a scaffolded project (`zcli init`) already does this. See
[BUILD.md](BUILD.md#command-unit-tests-addcommandtests) for the full config
and how commands are compiled for testing.

For the full VTerm assertion API, the integration/E2E tiers, snapshot testing, and the recommended per-command strategy, see **[zcli.sh/testing](https://zcli.sh/testing/)**.
