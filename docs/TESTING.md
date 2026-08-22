# Testing zcli Applications

> **Full guide: [zcli.sh/testing](https://zcli.sh/testing/).** This is a quick
> orientation; the website is the single source of truth for the testing API.

zcli provides three tiers of testing — use them together for coverage without slow feedback loops:

| Tier | What it tests | Speed |
|------|--------------|-------|
| **Unit** | Command and shared-module logic in isolation — in-process, no binary | Fast |
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

Unit tests only run under `zig build test` if `build.zig` wires
`zcli.addCommandTests(b, exe, zcli_dep, .{ .commands_dir = "src/commands", ... })` —
a scaffolded project (`zcli init`) already does this. That one step compiles
**two kinds of test root** within the unit tier: every discovered command file,
and every module in the `shared_modules` list you pass it. So the `test` blocks
in a shared helper (`src/store.zig`, `src/greeting.zig`, …) run alongside the
command tests without a second test target — the same list that makes a shared
module importable from a command makes its own tests run. See
[BUILD.md](BUILD.md#command-unit-tests-addcommandtests) for the full config
and how commands are compiled for testing, and `examples/testing-demo` for a
project with both kinds of test.

For the full VTerm assertion API, the integration/E2E tiers, snapshot testing, and the recommended per-command strategy, see **[zcli.sh/testing](https://zcli.sh/testing/)**.
