# testing

Three tiers of testing for zcli-built CLIs, from fast in-process command tests to full pseudo-terminal sessions:

1. **Unit** — `runCommand` executes a command's `execute()` in-process and captures stdout/stderr (plus a `vterm` screen for rendered-output assertions). No binary, fastest loop.
2. **Integration** — `runSubprocess` runs the compiled binary and asserts on the full stack: parsing, routing, plugin hooks, exit codes. Includes snapshot testing.
3. **E2E (PTY)** — `e2e.runInteractive` drives the binary through a real pseudo-terminal for prompts, hidden input, signals, and TTY-dependent formatting.

The complete guide with worked examples per tier is [docs/TESTING.md](../../docs/TESTING.md).

## Getting it

The testing tiers ship with the zcli dependency — no separate dependency entry:

- **Scaffolded projects are already wired**: `zcli.addCommandTests(...)` (emitted by `zcli init`) compiles each command file as its own test root with `zcli-testing` importable, so `zig build test` just works.
- **Manual wiring** for any other test module:

  ```zig
  test_module.addImport("zcli-testing", zcli_dep.module("zcli_testing"));
  ```

- **PTY harness alone**: `zcli_dep.module("testing_e2e")` exposes just the e2e tier (std-only — no zcli/vterm) for driving a TTY from a project's own e2e suite.

## API surface

- **Unit**: `runCommand(Command, .{ .args = ..., .options = ... })` → `CommandResult` (`.stdout`, `.stderr`, `.success`, `.err`, `.term`)
- **Integration**: `runSubprocess(allocator, io, exe_path, args)` → `Result` (`.stdout`, `.stderr`, `.exit_code`)
- **Assertions**: `expectExitCode`, `expectExitCodeNot`, `expectContains`, `expectNotContains`, `expectEqualStrings`, `expectValidJson`, `expectStdoutEmpty`, `expectStderrEmpty`
- **Snapshots**: `expectSnapshot(...)` against golden files, with `maskDynamicContent` (UUIDs, timestamps, addresses) and `stripAnsi`; update with `UPDATE_SNAPSHOTS=1`
- **E2E**: `e2e.InteractiveScript` builder (`.expect`, `.send`, `.sendHidden`, `.sendControl`, `.sendSignal`, `.delay`, `.withTimeout`, `.optional`), executed by `e2e.runInteractive(...)` → `InteractiveResult` (`.exit_code`, `.output`, `.success`, `.transcript`); `runInteractiveDualMode` runs the same script with and without a PTY

## Quick taste

```zig
const testing = @import("zcli-testing");

test "add command prints confirmation" {
    var result = try testing.runCommand(add, .{
        .args = .{ .name = "widget" },
        .options = .{ .verbose = true },
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("Added widget\n", result.stdout);
}

test "login prompts for credentials" {
    var script = testing.e2e.InteractiveScript.init(allocator);
    _ = script
        .expect("Username:")
        .send("alice")
        .expect("Password:")
        .sendHidden("secret123")
        .expect("Login successful");
    var result = try testing.e2e.runInteractive(
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

## Dependencies

- [`core`](../core/) — `Stdio`, `TestContext` for in-process execution
- [`vterm`](../vterm/) — terminal emulation for rendered-output assertions
