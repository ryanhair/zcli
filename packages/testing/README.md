# testing

Three tiers of testing for zcli-built CLIs, from fast in-process command tests to full pseudo-terminal sessions:

1. **Unit** — `runCommand` executes a command's `execute()` in-process and captures stdout/stderr (plus a `vterm` screen for rendered-output assertions). No binary, fastest loop.
2. **Integration** — `runSubprocess` runs the compiled binary and asserts on the full stack: parsing, routing, plugin hooks, exit codes. Includes snapshot testing.
3. **E2E (PTY)** — `e2e.runInteractive` drives the binary through a real pseudo-terminal for prompts, hidden input, signals, and TTY-dependent formatting. Assert on the raw byte stream (`.expect`) *or* on the rendered screen (`.expectFrameContains` / `.expectRow` / `.expectFrame`): the harness feeds the PTY/ConPTY output through a `vterm` sized to the session, so a frame assertion only passes if the text is actually visible where it was drawn — closing the gap where a cursor-movement regression leaves the expected bytes *somewhere* in the stream and a raw substring still matches.

Alongside the tiers there is one test double: **`HttpFixture`** — a scripted loopback HTTP server for the adapter layer that talks to an API. Queue the responses, point the code under test at an ephemeral `127.0.0.1` URL, assert on the requests it actually sent. Ships in the std-only `zcli_testing` module.

The complete guide with worked examples per tier is [zcli.sh/testing](https://zcli.sh/testing/).

## Runnable examples

`examples/` has a heavily-commented sample test file per tier, each importing the
tier under the same alias a real project uses:

- [`examples/unit_example.zig`](examples/unit_example.zig) — `runCommand`: args/options, failure and `context.fail`, vterm rendered-output assertions, plugin state, injected stdin, app metadata.
- [`examples/snapshot_example.zig`](examples/snapshot_example.zig) — `runSubprocess` + assertions, and `expectSnapshot` compare/update with masking and `ansi=false`.
- [`examples/e2e_example.zig`](examples/e2e_example.zig) — `InteractiveScript` + `runInteractive` over pipes and a real PTY (the PTY case skips gracefully where no TTY exists).
- [`examples/http_fixture_example.zig`](examples/http_fixture_example.zig) — `HttpFixture` driving a real `zcli.http` adapter: scripted success and failure responses, and request assertions.

Run them with `zig build examples` (they're also folded into `zig build test`, so
they can't drift from the API they document).

## Getting it

The testing tiers ship with the zcli dependency — no separate dependency entry. Each
tier is its own module, so you only pull the dependencies the tier actually needs: the
**unit** tier (`zcli_testing_unit`) and the **e2e** tier (`testing_e2e`, for its
rendered-frame assertions) need vterm — the unit tier also needs zcli; the
**integration/snapshot** tier (`zcli_testing`) is std-only.

- **Scaffolded projects are already wired**: `zcli.addCommandTests(...)` (emitted by `zcli init`) compiles each command file as its own test root with the unit tier importable as `zcli-testing`, so `zig build test` just works.
- **Manual wiring** — pick the tier your test module uses (the import name is just a local alias):

  ```zig
  // In-process unit tests (runCommand): pulls in zcli + vterm.
  test_module.addImport("zcli-testing", zcli_dep.module("zcli_testing_unit"));

  // Subprocess + snapshot tests (runSubprocess, expectSnapshot): std-only.
  test_module.addImport("zcli-testing", zcli_dep.module("zcli_testing"));

  // PTY harness alone (e2e.runInteractive): pulls in vterm for frame assertions.
  test_module.addImport("testing_e2e", zcli_dep.module("testing_e2e"));
  ```

  A test module that uses more than one tier just adds more than one import.

## API surface

- **Unit**: `runCommand(Command, .{ .args = ..., .options = ... })` → `CommandResult` (`.stdout`, `.stderr`, `.success`, `.err`, `.term`). Also configurable: `.plugins` (plugin `ContextData`), `.environ`, `.stdin` (input bytes for `context.stdin()`/`context.prompts()`; injecting it also puts prompts on their line-based branch, so they read these bytes instead of the real stdin and never enter raw mode — keystroke behavior stays with the PTY tier), `.app_name`/`.app_version`/`.app_description` (context app metadata, in place before plugin `initContextData` runs), `.allocator`
- **Integration**: `runSubprocess(allocator, io, exe_path, args)` → `Result` (`.stdout`, `.stderr`, `.exit_code`)
- **Assertions**: `expectExitCode`, `expectExitCodeNot`, `expectContains`, `expectNotContains`, `expectEqualStrings`, `expectValidJson`, `expectStdoutEmpty`, `expectStderrEmpty`
- **Snapshots**: `expectSnapshot(...)` against golden files, with `maskDynamicContent` (UUIDs, timestamps, addresses) and `stripAnsi`; update by threading `.update = true` from a build option (`zig build test -Dupdate-snapshots`)
- **HTTP fixture**: `HttpFixture.init(allocator, io, .{ .concurrency, .max_request_body_bytes })` → `*HttpFixture`; `respondWith(.{ .status, .headers, .body })` queues a response, `baseUrl()` / `url("/path")` give the loopback URL, `try requests()` returns a snapshot of every recording (`.method`, `.target`, `.headers`, `.body`, `.body_truncated`, `.header(name)`), and `deinit()` releases the socket, the serving tasks, and every byte the fixture allocated. Once the queue runs dry, further requests get `unscripted_status` / `unscripted_body` instead of hanging
- **E2E**: `e2e.InteractiveScript` builder — stream steps (`.expect`, `.send`, `.sendHidden`, `.sendControl`, `.sendSignal`, `.delay`, `.withTimeout`, `.optional`) and rendered-frame steps (`.expectFrameContains(text)`, `.expectRow(index, expected)`, `.expectFrame(snapshot_name)`) — executed by `e2e.runInteractive(...)` → `InteractiveResult` (`.exit_code`, `.output`, `.success`, `.transcript`); `runInteractiveDualMode` runs the same script with and without a PTY. Frame steps poll until the rendered screen matches or the step times out (no fixed sleeps); `.expectFrame` reuses the snapshot masking/update flow (`config.snapshot_root` + `config.update_snapshots`)

## Quick taste

```zig
// Unit tier — module `zcli_testing_unit`, wired as `zcli-testing`.
const testing = @import("zcli-testing");

test "add command prints confirmation" {
    var result = try testing.runCommand(add, .{
        .args = .{ .name = "widget" },
        .options = .{ .verbose = true },
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("Added widget\n", result.stdout);
}

// E2E tier — module `testing_e2e` (std-only), a separate import.
const e2e = @import("testing_e2e");

test "login prompts for credentials" {
    var script = e2e.InteractiveScript.init(allocator);
    _ = script
        .expect("Username:")
        .send("alice")
        .expect("Password:")
        .sendHidden("secret123")
        .expect("Login successful");
    var result = try e2e.runInteractive(
        allocator,
        std.testing.io,
        &.{ "./zig-out/bin/myapp", "login" },
        script,
        .{ .allocate_pty = true },
    );
    defer result.deinit();
    try std.testing.expect(result.success);
}
```

## Behavior notes

- PTY allocation degrades to a skip (not a failure) on hosts without working PTYs; CI greps for the skip marker so the interactive tier can't go silently vacuous.
- Snapshot files are masked and ANSI-stripped by default (`SnapshotOptions`), so dynamic content doesn't churn goldens.
- `HttpFixture` serves plain HTTP and answers every request from one queue — it does not route on method or path; assert on `requests()` instead. Its serving tasks run concurrently with the test, so the allocator must be usable from more than one thread (`std.testing.allocator` is).

## Dependencies

The **unit** tier (`zcli_testing_unit`) depends on both; the **e2e** tier
(`testing_e2e`) depends on vterm alone (for rendered-frame assertions); the
subprocess/snapshot tier (`zcli_testing`) is std-only.

- [`core`](../core/) — `Stdio`, `TestContext` for in-process execution (unit tier only)
- [`vterm`](../vterm/) — terminal emulation for rendered-output assertions (unit + e2e tiers)
