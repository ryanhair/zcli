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
descriptors are. That rules out raw mode: a `runCommand` test can never take
over the terminal it was launched from or read its keystrokes. It does *not*
make a prompting command safe to run without `.stdin` — the line path still
reads whatever `context.stdin()` is, and with no injection that is the
process's own stdin, which at a terminal blocks until someone types a line.
Give any command that prompts an explicit `.stdin`.

Raw-mode keystrokes (arrows through a `select`, hidden input, Ctrl-C) are not
modeled by a byte stream and belong in the PTY-backed E2E tier.

For the complete argv-to-outcome lifecycle without a subprocess, the same
in-process module also exports `runInvocation`:

```zig
var result = try testing.runInvocation(@import("command_registry"), .{
    .argv = &.{ "log", "card-7", "--body", "-" },
    .stdin = "hello\n",
});
defer result.deinit();
try std.testing.expectEqual(@as(u8, 0), result.invocation.status);
```

Wire the real generated registry into this test module, not the isolated command
test stub. A compiled registry type works as well. Arguments exclude the binary
name; omitted stdin is EOF and omitted environment is empty. The result captures
stdout/stderr and owns the invocation outcome and diagnostics until `deinit()`.
This exercises production parsing, plugins, resolution, and failure policy;
`runCommand` remains a direct test of typed command inputs.

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

The generated-registry process fixture runs with `zig build test-invocation-policy`
(requires Python 3). It checks configured statuses, mapped failures, original
unexpected-error traces, and real output failures at the process boundary.

`Prompts.edit` explicitly acquires a controlling terminal; captured stdout in
`runCommand` or `runInvocation` does not replace that terminal. Test direct editor
interaction in the PTY tier. For a deterministic noninteractive child fixture,
supply explicit editor argv and `.attachment = .inherit`. The invitation prompt
(`Prompts.editor`) still respects captured/noninteractive streams.

`zig build test-metadata-validation` (Python 3) compiles a generated application
with valid metadata, then checks rejection diagnostics for unknown plugin
namespaces/fields, incorrect values, missing defaults, invalid stdin/delimiter
option declarations, and unknown command/option metadata fields.
