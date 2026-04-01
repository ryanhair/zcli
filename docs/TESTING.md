# Testing zcli Applications

zcli provides three tiers of testing, each suited to different verification needs. Use them together for comprehensive coverage.

| Tier | What it tests | Speed | Fidelity |
|------|--------------|-------|----------|
| **Unit** | Command logic in isolation | Fast (in-process) | Tests `execute()` only |
| **Integration** | Full CLI binary via subprocess | Medium | Tests arg parsing, routing, output |
| **E2E** | Interactive terminal behavior | Slow | Tests prompts, signals, TTY output |

---

## Unit Testing

Test a single command's `execute()` function without compiling or spawning a binary. This is the fastest feedback loop — use it for command logic, output formatting, and error handling.

### Setup

Unit testing uses `zcli.test_utils` which is built into the core framework. No extra dependencies needed.

### Writing tests

```zig
const std = @import("std");
const zcli = @import("zcli");
const test_utils = zcli.test_utils;

// Import the command you want to test
const add = @import("commands/add.zig");

test "add command prints confirmation" {
    var result = try test_utils.runCommand(add, &.{}, .{
        .args = .{ .name = "widget" },
        .options = .{ .verbose = false },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Added widget\n", result.stdout);
    try std.testing.expect(result.stderr.len == 0);
    try std.testing.expect(result.success);
}

test "add command fails on empty name" {
    var result = try test_utils.runCommand(add, &.{}, .{
        .args = .{ .name = "" },
        .options = .{},
    });
    defer result.deinit();

    try std.testing.expect(!result.success);
    try std.testing.expectEqual(error.InvalidName, result.err.?);
}
```

### Testing with plugins

If your command accesses plugin data through `context.plugins`, pass the plugins to `runCommand`:

```zig
const zcli_output = @import("zcli_output");

test "command respects output mode" {
    var result = try test_utils.runCommand(list, &.{zcli_output}, .{
        .args = .{},
        .options = .{},
    });
    defer result.deinit();

    // Plugin data starts at defaults (output_mode = .table)
    try std.testing.expect(result.success);
}
```

### API reference

**`test_utils.runCommand(Command, plugins, config)`**

| Parameter | Type | Description |
|-----------|------|-------------|
| `Command` | `type` (comptime) | The command module with `Args`, `Options`, `execute` |
| `plugins` | `[]const type` (comptime) | Plugins to register (for `context.plugins` access) |
| `config.args` | `Command.Args` | Positional arguments to pass |
| `config.options` | `Command.Options` | Option values to pass |
| `config.allocator` | `std.mem.Allocator` | Defaults to `std.testing.allocator` |

**Returns `CommandResult`:**

| Field | Type | Description |
|-------|------|-------------|
| `.stdout` | `[]const u8` | Captured standard output |
| `.stderr` | `[]const u8` | Captured standard error |
| `.success` | `bool` | `true` if `execute()` returned without error |
| `.err` | `?anyerror` | The error if `execute()` failed |

Always call `result.deinit()` when done (use `defer`).

### When to use unit tests

- Testing command output formatting
- Testing error handling and validation
- Testing conditional logic based on args/options
- Testing plugin data interactions
- Fast iteration during development

### Limitations

- Does not test argument parsing (args are passed directly as typed structs)
- Does not test command routing or discovery
- Does not test global option handling
- Commands that call `std.process.exit()` will exit the test runner

---

## Integration Testing

Test your compiled CLI binary as a subprocess. This validates the full stack — argument parsing, command routing, plugin hooks, and output generation.

### Setup

Add the testing package as a dependency:

```zig
// build.zig.zon
.dependencies = .{
    .zcli = .{ .path = "path/to/zcli" },
    .@"zcli-testing" = .{ .path = "path/to/zcli/packages/testing" },
},
```

```zig
// build.zig
const testing_dep = b.dependency("zcli-testing", .{});
test_module.addImport("zcli-testing", testing_dep.module("testing"));
```

### Writing tests

```zig
const std = @import("std");
const testing = @import("zcli-testing");

test "help flag shows usage" {
    var result = try testing.runSubprocess(
        std.testing.allocator,
        "./zig-out/bin/myapp",
        &.{"--help"},
    );
    defer result.deinit();

    try testing.expectExitCode(result, 0);
    try testing.expectContains(result.stdout, "USAGE:");
    try testing.expectContains(result.stdout, "COMMANDS:");
}

test "version flag" {
    var result = try testing.runSubprocess(
        std.testing.allocator,
        "./zig-out/bin/myapp",
        &.{"--version"},
    );
    defer result.deinit();

    try testing.expectExitCode(result, 0);
    try testing.expectContains(result.stdout, "myapp v");
}

test "unknown command shows suggestions" {
    var result = try testing.runSubprocess(
        std.testing.allocator,
        "./zig-out/bin/myapp",
        &.{"hlep"},
    );
    defer result.deinit();

    try testing.expectContains(result.stderr, "Unknown command");
    try testing.expectContains(result.stderr, "Did you mean");
}
```

### Assertions

All assertion functions take a `Result` or output string and return `!void`.

| Function | Description |
|----------|-------------|
| `expectExitCode(result, code)` | Exit code matches exactly |
| `expectExitCodeNot(result, code)` | Exit code does not match |
| `expectContains(output, needle)` | Output contains substring |
| `expectNotContains(output, needle)` | Output does not contain substring |
| `expectEqualStrings(expected, actual)` | Exact string match |
| `expectValidJson(allocator, output)` | Output is valid JSON |
| `expectStdoutEmpty(result)` | stdout has no output |
| `expectStderrEmpty(result)` | stderr has no output |

### Snapshot testing

Compare command output against saved golden files. Useful for verifying help text, formatted output, or any output that should remain stable.

```zig
test "help output matches snapshot" {
    var result = try testing.runSubprocess(
        std.testing.allocator,
        "./zig-out/bin/myapp",
        &.{"--help"},
    );
    defer result.deinit();

    try testing.expectSnapshot(
        std.testing.allocator,
        result.stdout,
        @src(),
        "help_output",
        .{},
    );
}
```

Snapshots are stored in `tests/snapshots/{test_file}/{snapshot_name}.txt`.

**Creating and updating snapshots:**

```bash
# First run: creates snapshot files
UPDATE_SNAPSHOTS=1 zig build test

# Or add to build.zig using the build utility:
const testing_build = @import("zcli-testing");
testing_build.setup(b, test_step);
# Then: zig build update-snapshots
```

**Snapshot options:**

| Option | Default | Description |
|--------|---------|-------------|
| `.mask` | `true` | Replace UUIDs, timestamps, and memory addresses with placeholders |
| `.ansi` | `true` | Preserve ANSI color codes in snapshots |

Masking prevents snapshots from breaking due to dynamic content like timestamps or UUIDs.

### When to use integration tests

- Testing argument parsing and validation
- Testing command routing (correct command is dispatched)
- Testing global options (--help, --version, --output)
- Testing plugin behavior end-to-end
- Testing exit codes
- Verifying output stability with snapshots

### Limitations

- Requires the binary to be built first (`zig build` before `zig build test`)
- Slower than unit tests (subprocess overhead)
- Cannot inspect internal state (only stdout, stderr, exit code)
- No TTY — output is piped, so TTY-aware formatting won't activate

---

## E2E Testing

Test interactive terminal behavior with a real pseudo-terminal (PTY). Use this for commands that prompt for input, handle signals, or adapt to terminal size.

### Setup

E2E testing is included in the testing package (same dependency as integration testing). Access it via `testing.e2e`.

### Writing tests

```zig
const std = @import("std");
const testing = @import("zcli-testing");

test "login prompts for credentials" {
    const allocator = std.testing.allocator;

    var script = testing.e2e.InteractiveScript.init(allocator);
    _ = script
        .expect("Username:")
        .send("alice")
        .expect("Password:")
        .sendHidden("secret123")
        .expect("Login successful")
        .withTimeout(5000);

    var result = try testing.e2e.runInteractive(
        allocator,
        &.{"./zig-out/bin/myapp", "login"},
        script,
        .{ .allocate_pty = true },
    );

    try std.testing.expect(result.success);
}

test "ctrl-c triggers graceful shutdown" {
    const allocator = std.testing.allocator;

    var script = testing.e2e.InteractiveScript.init(allocator);
    _ = script
        .expect("Running...")
        .sendSignal(.SIGINT)
        .expect("Shutting down gracefully");

    var result = try testing.e2e.runInteractive(
        allocator,
        &.{"./zig-out/bin/myapp", "serve"},
        script,
        .{ .forward_signals = true },
    );

    try std.testing.expect(result.success);
}
```

### Script builder

The `InteractiveScript` uses a fluent API to describe a sequence of expected outputs and inputs:

| Method | Description |
|--------|-------------|
| `.expect(text)` | Wait for text to appear in output |
| `.expectExact(text)` | Wait for exact text match |
| `.send(text)` | Send text input |
| `.sendHidden(text)` | Send input without echo (passwords) |
| `.sendControl(seq)` | Send control sequence (`.enter`, `.ctrl_c`, `.tab`, `.escape`, arrow keys) |
| `.sendSignal(sig)` | Send a signal (`.SIGINT`, `.SIGTERM`, `.SIGTSTP`, `.SIGWINCH`, etc.) |
| `.sendRaw(bytes)` | Send raw bytes |
| `.delay(ms)` | Wait before next step |
| `.withTimeout(ms)` | Set timeout for current step |
| `.optional()` | Don't fail if this step doesn't match |

### Configuration

```zig
testing.e2e.InteractiveConfig{
    .allocate_pty = true,           // Use real PTY (vs pipes)
    .total_timeout_ms = 30000,      // Global timeout
    .terminal_mode = .cooked,       // .raw, .cooked, or .inherit
    .terminal_size = .{ .rows = 24, .cols = 80 },
    .disable_echo = false,          // Disable echo for password testing
    .forward_signals = false,       // Forward signals to child process
    .save_transcript = false,       // Save full interaction log
    .echo_input = false,            // Debug: echo sent input to stderr
}
```

### Result

```zig
testing.e2e.InteractiveResult{
    .exit_code: u8,
    .output: []const u8,        // Captured output
    .success: bool,             // All script steps matched
    .steps_executed: usize,     // How many steps ran
    .duration_ms: u64,          // Total time
    .transcript: ?[]const u8,   // Full log (if save_transcript=true)
}
```

### Dual-mode testing

Test that your CLI works correctly in both TTY and piped modes:

```zig
test "output works in both modes" {
    var script = testing.e2e.InteractiveScript.init(allocator);
    _ = script.expect("Results:");

    const results = try testing.e2e.runInteractiveDualMode(
        allocator,
        &.{"./zig-out/bin/myapp", "list"},
        script,
        .{},
    );

    try std.testing.expect(results.tty_result.success);
    try std.testing.expect(results.pipe_result.success);
}
```

### When to use E2E tests

- Testing password prompts and masked input
- Testing signal handling (Ctrl+C cleanup, SIGTERM shutdown)
- Testing TTY-aware output (colors, progress bars, column width)
- Testing interactive wizards and menus
- Verifying behavior differs correctly between TTY and pipe modes

### Limitations

- Slowest tier (PTY allocation, process spawning, timeouts)
- Platform-dependent (PTY support varies across OS)
- Flaky if timeouts are too tight
- Requires the binary to be built first

---

## Recommended Testing Strategy

### For most commands

Start with unit tests. They're fast and cover the majority of logic:

```zig
// tests/commands/add_test.zig
test "add creates resource" { ... }
test "add validates name" { ... }
test "add rejects duplicates" { ... }
```

### For the CLI as a whole

Add integration tests for flags, routing, and output:

```zig
// tests/integration_test.zig
test "help flag" { ... }
test "version flag" { ... }
test "unknown command" { ... }
test "subcommand routing" { ... }
```

### For interactive features

Add E2E tests only for commands that interact with the terminal:

```zig
// tests/e2e_test.zig
test "init wizard" { ... }
test "login flow" { ... }
```

### Snapshot tests for output stability

Use snapshots for any output that users depend on (help text, structured output):

```zig
// tests/snapshot_test.zig
test "help output" { ... }
test "json output format" { ... }
```

---

## Project structure

```
myapp/
├── src/
│   ├── main.zig
│   └── commands/
│       ├── add.zig
│       └── list.zig
├── tests/
│   ├── unit/
│   │   ├── add_test.zig          # Unit tests for add command
│   │   └── list_test.zig         # Unit tests for list command
│   ├── integration_test.zig      # Subprocess tests
│   ├── e2e_test.zig              # Interactive tests
│   └── snapshots/                # Auto-generated snapshot files
│       └── integration_test/
│           └── help_output.txt
├── build.zig
└── build.zig.zon
```
