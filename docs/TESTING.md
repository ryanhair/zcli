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

For the full VTerm assertion API, the integration/E2E tiers, snapshot testing, and the recommended per-command strategy, see **[zcli.sh/testing](https://zcli.sh/testing/)**.
