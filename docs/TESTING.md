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

Commands that talk to an HTTP API get a fourth tool alongside the tiers: `HttpFixture`, a scripted loopback server for testing the adapter layer. Queue the responses, point the adapter at an ephemeral `127.0.0.1` URL, assert on what it sent:

```zig
const HttpFixture = @import("zcli-testing").HttpFixture;

test "fetchWidget sends the token" {
    const allocator = std.testing.allocator;

    var fixture = try HttpFixture.init(allocator, std.testing.io, .{});
    defer fixture.deinit();

    try fixture.respondWith(.{ .body = "{\"id\":7,\"name\":\"sprocket\"}" });

    var widget = try fetchWidget(allocator, std.testing.io, fixture.baseUrl(), "secret-token", 7);
    defer widget.deinit(allocator);

    const sent = try fixture.requests();
    try std.testing.expectEqualStrings("/widgets/7", sent[0].target);
    try std.testing.expectEqualStrings("Bearer secret-token", sent[0].header("authorization").?);
}
```

For the full VTerm assertion API, the integration/E2E tiers, snapshot testing, the `HttpFixture` reference, and the recommended per-command strategy, see **[zcli.sh/testing](https://zcli.sh/testing/)**.
