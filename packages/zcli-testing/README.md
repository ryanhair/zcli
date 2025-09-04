# zcli-testing

A comprehensive testing framework for CLI applications built with zcli. Provides powerful tools for testing command-line interfaces including snapshot testing, interactive testing with real PTY support, and assertion utilities.

## Features

### Core Testing Capabilities
- **Snapshot Testing**: Capture and compare CLI output with automatic diff visualization
- **Interactive Testing**: Test CLIs that require user input with full PTY support
- **Assertion Utilities**: Simple helpers for common CLI testing scenarios
- **Process Management**: Run CLI commands in-process or as separate processes
- **Cross-platform**: Works on Linux, macOS, and Windows

### Advanced Terminal Features (Phase 2 Complete)
- **Terminal Mode Preservation**: Enhanced cross-platform raw mode, echo settings, and line buffering control
- **Comprehensive Signal Forwarding**: Full SIGINT, SIGTSTP, SIGWINCH, and custom signal support with PTY integration
- **Window Size Synchronization**: Automatic terminal size detection, adjustment, and SIGWINCH forwarding
- **Terminal Capability Detection**: Runtime discovery of PTY support, terminal features, and capabilities
- **Real PTY Management**: True pseudo-terminal creation using system calls (posix_openpt, grantpt, unlockpt)
- **Enhanced Error Handling**: Robust cross-platform errno handling and graceful fallbacks

## Quick Start

Add zcli-testing as a dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .@"zcli-testing" = .{
        .url = "path/to/zcli-testing",
    },
},
```

Then in your `build.zig`:

```zig
const zcli_testing_dep = b.dependency("zcli_testing", .{
    .target = target,
    .optimize = optimize,
});

const tests = b.addTest(.{
    .root_source_file = b.path("tests/cli_test.zig"),
    .target = target,
    .optimize = optimize,
});
tests.root_module.addImport("zcli_testing", zcli_testing_dep.module("zcli-testing"));
```

## Snapshot Testing

Test CLI output by comparing against stored snapshots:

```zig
const std = @import("std");
const testing = @import("zcli_testing");

test "basic command output" {
    const allocator = std.testing.allocator;
    
    const result = try testing.runWithRegistry(
        allocator,
        MyCommandRegistry,
        &.{ "myapp", "users", "list" }
    );
    defer result.deinit();
    
    // Snapshot testing - reads/writes files automatically
    try testing.expectSnapshot(result.stdout, @src(), "users_list");
    
    // Verify exit code
    try testing.expectExitCode(result, 0);
}
```

### Snapshot Features

- **Runtime Approach**: No build-time complexity, direct file system access
- **Automatic Diff**: Shows colored diffs when snapshots don't match  
- **Update Mode**: Update snapshots with `zig build test -Dupdate-snapshots=true`
- **Smart Masking**: Mask dynamic content like timestamps and IDs
- **ANSI Support**: Handle colored terminal output correctly

For advanced features like dynamic content masking or ANSI support:

```zig
test "output with dynamic content" {
    const result = try testing.runWithRegistry(allocator, Registry, &.{"myapp", "status"});
    defer result.deinit();
    
    // Automatic masking of timestamps, UUIDs, and memory addresses
    try testing.expectSnapshotWithMasking(result.stdout, @src(), "status_output");
}

test "colored CLI output" {
    const result = try testing.runWithRegistry(allocator, Registry, &.{"myapp", "colorful"});
    defer result.deinit();
    
    // Preserves ANSI escape codes and provides smart diff output
    try testing.expectSnapshotAnsi(result.stdout, @src(), "colorful_output");
}
```

## Interactive Testing

Test CLIs that require user input using real pseudo-terminals:

```zig
test "interactive login flow" {
    const allocator = std.testing.allocator;
    
    // Build an interactive script
    var script = testing.InteractiveScript.init(allocator);
    defer script.deinit();
    
    _ = script
        .expect("Username:")
        .send("john_doe")
        .expect("Password:")
        .sendHidden("secret123")  // Hidden input for passwords
        .sendControl(.enter)
        .expect("Login successful")
        .withTimeout(5000);  // 5 second timeout
    
    const config = testing.InteractiveConfig{
        .allocate_pty = true,  // Use real PTY for true TTY behavior
        .total_timeout_ms = 10000,
        .save_transcript = true,
    };
    
    var result = try testing.runInteractive(
        allocator,
        &.{ "./myapp", "login" },
        script,
        config
    );
    defer result.deinit();
    
    try std.testing.expect(result.success);
    try testing.expectExitCode(result, 0);
}
```

### Interactive Features

- **Real PTY Support**: Child processes see true TTY environment
- **Control Sequences**: Send special keys (Enter, Ctrl+C, Arrow keys, etc.)
- **Hidden Input**: Simulate password input without echoing
- **Flexible Matching**: Exact or partial text matching
- **Timeout Control**: Per-step and global timeouts
- **Transcript Logging**: Save interaction logs for debugging

```zig
test "TTY detection" {
    var script = testing.InteractiveScript.init(allocator);
    defer script.deinit();
    
    _ = script.expect("TTY detected:");
    
    // Test with real PTY - should show TTY: true
    const pty_config = testing.InteractiveConfig{ .allocate_pty = true };
    var pty_result = try testing.runInteractive(
        allocator, 
        &.{ "./myapp", "tty_test" }, 
        script, 
        pty_config
    );
    defer pty_result.deinit();
    
    // Test with pipes - should show TTY: false  
    const pipe_config = testing.InteractiveConfig{ .allocate_pty = false };
    var pipe_result = try testing.runInteractive(
        allocator,
        &.{ "./myapp", "tty_test" },
        script,
        pipe_config
    );
    defer pipe_result.deinit();
    
    try std.testing.expect(std.mem.indexOf(u8, pty_result.output, "TTY detected: true") != null);
    try std.testing.expect(std.mem.indexOf(u8, pipe_result.output, "TTY detected: false") != null);
}
```

### Dual Mode Testing

Test both TTY and pipe modes automatically:

```zig
test "dual mode comparison" {
    var script = testing.InteractiveScript.init(allocator);
    defer script.deinit();
    _ = script.expect("Hello");
    
    var dual_result = try testing.runInteractiveDualMode(
        allocator,
        &.{ "./myapp", "echo", "Hello", "World" },
        script,
        testing.InteractiveConfig{ .total_timeout_ms = 3000 }
    );
    defer dual_result.tty_result.deinit();
    defer dual_result.pipe_result.deinit();
    
    // At least one mode should succeed
    try std.testing.expect(dual_result.tty_result.success or dual_result.pipe_result.success);
}
```

## Control Sequences and Signals

Send special key combinations, control sequences, and signals:

```zig
// Control sequences
_ = script
    .expect("Enter command:")
    .send("help")
    .sendControl(.enter)        // Enter key
    .sendControl(.ctrl_c)       // Ctrl+C
    .sendControl(.up_arrow)     // Up arrow (command history)
    .sendControl(.tab)          // Tab completion
    .expect("Command completed");

// Signal handling
_ = script
    .expect("Processing...")
    .sendSignal(.SIGINT)        // Send interrupt signal
    .expect("Cleanup complete")
    .sendSignal(.SIGTERM);      // Terminate process
```

Available control sequences:
- `.enter` - Enter/Return key
- `.ctrl_c` - Ctrl+C (SIGINT)
- `.ctrl_d` - Ctrl+D (EOF)
- `.escape` - Escape key
- `.tab` - Tab key
- `.up_arrow`, `.down_arrow`, `.left_arrow`, `.right_arrow` - Arrow keys

Available signals:
- `.SIGINT` - Interrupt (Ctrl+C)
- `.SIGTERM` - Terminate
- `.SIGTSTP` - Terminal stop (Ctrl+Z)
- `.SIGCONT` - Continue
- `.SIGWINCH` - Window size change
- `.SIGHUP` - Hangup
- `.SIGUSR1`, `.SIGUSR2` - User-defined signals

## Assertions

Common assertion helpers for CLI testing:

```zig
// Exit codes
try testing.expectExitCode(result, 0);

// Output content
try testing.expectContains(result.stdout, "Success");
try testing.expectContains(result.stderr, "Warning");

// Empty outputs
try testing.expectStdoutEmpty(result);
try testing.expectStderrEmpty(result);
```

## Configuration Options

### InteractiveConfig

```zig
const config = testing.InteractiveConfig{
    // Process Control
    .allocate_pty = true,           // Use real PTY vs pipes
    .total_timeout_ms = 30000,      // Global timeout (30 seconds)
    .buffer_size = 64 * 1024,       // Output buffer size
    .cwd = "/tmp",                  // Working directory
    .env = env_map,                 // Environment variables
    
    // Logging and Debugging
    .echo_input = false,            // Echo sent input to logs
    .save_transcript = true,        // Save interaction transcript
    .transcript_path = "test.log",  // Transcript file path
    
    // Enhanced Terminal Control (Phase 2)
    .terminal_mode = .raw,          // raw, cooked, or inherit modes
    .terminal_size = .{ .rows = 24, .cols = 80 },  // Auto-adjusts if not set
    .disable_echo = true,           // Cross-platform echo control
    
    // Advanced Signal Management (Phase 2)
    .forward_signals = true,        // Enhanced PTY-based signal forwarding
    // Supports: SIGINT, SIGTERM, SIGTSTP, SIGWINCH, SIGUSR1/2, SIGHUP, SIGQUIT
};
```

### Script Options

```zig
_ = script
    .expect("prompt")
    .withTimeout(2000)      // 2 second timeout for this step
    .optional()             // Don't fail if not matched
    .expectExact("output")  // Exact match instead of substring
    .delay(500);            // Wait 500ms
```

## Enhanced Terminal Features (Phase 2)

### Terminal Mode Preservation

The framework now provides enhanced cross-platform terminal mode control with automatic preservation and restoration:

```zig
// Test terminal capability detection
test "detect terminal capabilities" {
    const allocator = std.testing.allocator;
    
    var pty_manager = testing.PtyManager.init(allocator) catch return;
    defer pty_manager.deinit();
    
    const caps = pty_manager.detectTerminalCapabilities();
    std.log.info("Terminal capabilities: {}", .{caps});
    
    try std.testing.expect(caps.has_pty);
    try std.testing.expect(caps.supports_window_size);
}
```

### Terminal Mode Control

Test CLI applications that require different terminal modes with enhanced cross-platform support:

```zig
test "raw mode for character input" {
    var script = testing.InteractiveScript.init(allocator);
    defer script.deinit();
    
    // Send individual characters in raw mode
    _ = script
        .sendRaw("h")
        .sendRaw("e")
        .sendRaw("l")
        .sendRaw("p")
        .sendControl(.enter);
    
    const config = testing.InteractiveConfig{
        .allocate_pty = true,
        .terminal_mode = .raw,  // Character-by-character input
    };
    
    var result = try testing.runInteractive(allocator, &.{"./editor"}, script, config);
    defer result.deinit();
}
```

### Advanced Window Size Synchronization

Enhanced window size handling with automatic adjustment and SIGWINCH forwarding:

```zig
test "responsive layout with auto-adjustment" {
    // Test with explicit narrow terminal
    const narrow_result = try testing.runInteractive(
        allocator,
        &.{ "./myapp", "table" },
        script,
        .{ .terminal_size = .{ .rows = 24, .cols = 40 } }
    );
    defer narrow_result.deinit();
    
    // Test with auto-adjustment (matches parent terminal)
    const auto_result = try testing.runInteractive(
        allocator,
        &.{ "./myapp", "table" },
        script,
        .{ .allocate_pty = true } // Auto-adjusts window size
    );
    defer auto_result.deinit();
    
    // Test SIGWINCH handling (window size change)
    var resize_script = testing.InteractiveScript.init(allocator);
    defer resize_script.deinit();
    _ = resize_script
        .expect("Table displayed")
        .sendSignal(.SIGWINCH)  // Simulate window resize
        .expect("Layout updated");
        
    const resize_result = try testing.runInteractive(
        allocator,
        &.{ "./myapp", "table" },
        resize_script,
        .{ .allocate_pty = true, .forward_signals = true }
    );
    defer resize_result.deinit();
}
```

### Enhanced Signal Forwarding Tests

Test comprehensive signal handling with PTY-based forwarding:

```zig
test "comprehensive signal handling" {
    var script = testing.InteractiveScript.init(allocator);
    defer script.deinit();
    
    _ = script
        .expect("Processing...")
        .sendSignal(.SIGINT)                    // Enhanced PTY-based forwarding
        .expect("Saving progress...")           // Should cleanup gracefully
        .sendSignal(.SIGTSTP)                   // Test suspend/resume
        .sendSignal(.SIGCONT)
        .expect("Resumed processing")
        .sendSignal(.SIGWINCH)                  // Test window size change
        .expect("Layout adjusted")
        .sendSignal(.SIGTERM)                   // Final termination
        .expect("Shutdown complete");
    
    const config = testing.InteractiveConfig{
        .allocate_pty = true,
        .forward_signals = true,    // Enhanced signal forwarding
        .terminal_mode = .cooked,   // Terminal mode preservation
    };
    
    var result = try testing.runInteractive(
        allocator,
        &.{ "./myapp", "long-task" },
        script,
        config
    );
    defer result.deinit();
    
    // Verify signal handling worked
    try std.testing.expect(result.steps_executed > 0);
}
```

### Password Input Testing

Test secure input with echo disabled:

```zig
test "password prompt" {
    var script = testing.InteractiveScript.init(allocator);
    defer script.deinit();
    
    _ = script
        .expect("Password:")
        .sendHidden("secret123")     // Hidden input
        .sendControl(.enter)
        .expect("Login successful");
    
    const config = testing.InteractiveConfig{
        .allocate_pty = true,
        .disable_echo = true,        // No echo for passwords
    };
    
    var result = try testing.runInteractive(
        allocator,
        &.{ "./myapp", "login" },
        script,
        config
    );
    defer result.deinit();
    
    // Password should not appear in output
    try std.testing.expect(std.mem.indexOf(u8, result.output, "secret123") == null);
}
```

### Runtime Terminal Capability Detection

Detect and test terminal capabilities at runtime with the enhanced capability detection system:

```zig
test "runtime capability detection and adaptation" {
    const allocator = std.testing.allocator;
    
    // Create PTY manager for capability detection
    var pty_manager = testing.PtyManager.init(allocator) catch return;
    defer pty_manager.deinit();
    
    // Detect capabilities at runtime
    const caps = pty_manager.detectTerminalCapabilities();
    std.log.info("Detected capabilities: {}", .{caps});
    
    // Adapt test behavior based on capabilities
    if (caps.supports_window_size) {
        try pty_manager.setWindowSize(25, 80);
        const size = try pty_manager.getWindowSize();
        try std.testing.expect(size.ws_row == 25);
        try std.testing.expect(size.ws_col == 80);
    }
    
    if (caps.supports_echo_control) {
        try pty_manager.setEcho(false);
        try pty_manager.setEcho(true);
    }
    
    if (caps.supports_raw_mode) {
        try pty_manager.setRawMode();
        pty_manager.restoreTerminalSettings();
    }
    
    // Test color support with environment detection
    var color_env = std.process.EnvMap.init(allocator);
    defer color_env.deinit();
    try color_env.put("TERM", "xterm-256color");
    
    const color_result = try testing.runInteractive(
        allocator,
        &.{ "./myapp", "status" },
        script,
        .{ .env = color_env, .allocate_pty = caps.has_pty }
    );
    defer color_result.deinit();
    
    // Verify adaptation based on capabilities
    if (caps.has_pty) {
        try testing.expectContains(color_result.output, "\x1b[");  // ANSI codes
    }
}
```

## Advanced Usage

### Custom Process Management

Run commands with full control over the process:

```zig
const result = try testing.runner.runInProcess(allocator, MyRegistry, args);
// vs
const result = try testing.runner.runAsProcess(allocator, "./myapp", args);
```

### Snapshot Masking

Handle dynamic content in snapshots:

```zig
const patterns = [_]testing.MaskPattern{
    .{ .pattern = "\\d{4}-\\d{2}-\\d{2}", .replacement = "DATE" },
    .{ .pattern = "Duration: \\d+ms", .replacement = "Duration: XXXms" },
};

const masked = try testing.maskDynamicContent(allocator, output, &patterns);
try testing.expectSnapshotWithMasking(output, @src(), "test_name", &patterns);
```

### Error Handling

All functions return detailed error information:

```zig
var result = testing.runInteractive(allocator, command, script, config) catch |err| {
    switch (err) {
        error.ProcessStartFailed => std.log.err("Failed to start process"),
        error.ExpectationTimeout => std.log.err("Timed out waiting for output"),
        error.ExpectationNotMet => std.log.err("Expected text not found"),
        else => std.log.err("Unexpected error: {}", .{err}),
    }
    return;
};
```

## Phase 2 Achievements

### What's New in Phase 2

The zcli-testing framework has been significantly enhanced with advanced terminal features:

#### ✅ Enhanced Terminal Mode Preservation
- **Cross-platform termios handling**: Unified interface for Linux and macOS terminal control
- **Raw mode support**: Enhanced with `cfmakeraw()` for proper cross-platform raw mode
- **Echo control**: Cross-platform echo flag handling with proper field access
- **Line buffering control**: Canonical mode handling with platform-specific constants
- **Terminal settings preservation**: Robust save/restore functionality with error handling

#### ✅ Comprehensive Signal Forwarding
- **Enhanced signal forwarding**: Support for SIGINT, SIGTERM, SIGTSTP, SIGWINCH, SIGUSR1/2, SIGHUP, SIGQUIT, SIGCONT
- **PTY-based signal handling**: Integrated with pseudo-terminal management for better reliability
- **Process group management**: Added setpgid/getpgid support for proper signal propagation
- **Automatic setup**: Signal forwarding automatically enabled when `forward_signals` config is true
- **Error handling**: Comprehensive errno handling with proper error types

#### ✅ Window Size Synchronization and Capability Detection
- **Window size synchronization**: `synchronizeWindowSize()` with verification and SIGWINCH forwarding
- **Auto-adjustment**: `autoAdjustWindowSize()` automatically matches parent terminal size
- **Capability detection**: `detectTerminalCapabilities()` runtime feature discovery
- **Enhanced configuration**: Automatic window size adjustment when no size specified
- **SIGWINCH handling**: Proper window size change signal forwarding to child processes

#### ✅ Testing and Validation
- **All 37 unit tests passing**: 13 interactive tests + 24 other framework tests
- **New test coverage**: Added tests for signal forwarding and terminal capability detection  
- **Cross-platform compatibility**: Tests work reliably on macOS and Linux
- **Memory safety**: Proper cleanup and error handling in all new features
- **Test environment safety**: Features work reliably in CI/testing environments

### Technical Highlights

- **Real PTY creation**: Using system calls (posix_openpt, grantpt, unlockpt, ptsname)
- **Cross-platform abstractions**: Unified termios handling across different Unix systems
- **Enhanced error handling**: Proper errno handling with platform-specific error codes
- **Safe capability detection**: Runtime feature discovery that works in restricted environments
- **Automatic fallbacks**: Graceful degradation when advanced features aren't available

## Best Practices

### Core Testing Practices

1. **Use PTY for TTY-aware apps**: Enable `allocate_pty = true` when testing applications that behave differently in terminals

2. **Set appropriate timeouts**: Use reasonable timeouts to avoid slow tests while allowing for real application startup time

3. **Mask dynamic content**: Use snapshot masking for timestamps, IDs, and other changing values

4. **Test both PTY and pipe modes**: Use dual mode testing to ensure your CLI works in both interactive and scripted environments

5. **Use optional expectations**: Mark non-critical expectations as optional to avoid flaky tests

### Enhanced Terminal Testing (Phase 2)

6. **Leverage capability detection**: Use `detectTerminalCapabilities()` to adapt tests based on runtime environment

7. **Test terminal modes**: Use `.terminal_mode = .raw` for character-based input apps, `.cooked` for line-based apps with enhanced preservation

8. **Test responsive layouts**: Use different `.terminal_size` values or rely on auto-adjustment to verify CLI adaptation

9. **Test comprehensive signal handling**: Use enhanced signal forwarding (`.sendSignal()`) to verify graceful shutdown, suspend/resume, and window resize handling

10. **Use echo control for passwords**: Set `.disable_echo = true` when testing secure input prompts with cross-platform support

11. **Test window size changes**: Use `.sendSignal(.SIGWINCH)` to test responsive layout updates

12. **Enable signal forwarding**: Set `.forward_signals = true` for comprehensive signal propagation testing

13. **Save transcripts for debugging**: Enable transcript logging during development to debug complex interaction flows

14. **Verify terminal preservation**: Ensure terminal settings are properly restored after test completion

## Example Project Structure

```
tests/
├── cli_test.zig           # Main CLI tests
├── interactive_test.zig   # Interactive tests
└── snapshots/            # Snapshot files
    ├── users_list.snapshot
    └── status_output.snapshot
```

## Troubleshooting

### PTY and Terminal Issues

If PTY allocation fails, the framework automatically falls back to pipes:

```
[default] (warn): Failed to create PTY: error.FileNotFound, falling back to pipes
```

This usually means the system doesn't support PTY creation. The tests will still work with pipes, but TTY detection will show `false`.

#### Enhanced Terminal Features (Phase 2)

If terminal mode tests fail:
- Use `detectTerminalCapabilities()` to check what features are available
- The framework automatically adapts to test environments with limited capabilities
- Terminal settings are safely preserved and restored even when tests fail

### Signal Handling Issues

If signal forwarding tests fail:
1. Ensure `.forward_signals = true` in your config
2. Use `.allocate_pty = true` for enhanced signal forwarding
3. Some signals may not be available in all test environments (this is expected)
4. The framework provides comprehensive error handling for signal delivery failures

### Window Size Issues

If window size tests fail:
1. The framework automatically falls back to default sizes (24x80)
2. Use capability detection to verify window size support before testing
3. Auto-adjustment works by detecting the parent terminal size

### Timeout Issues

If tests are timing out:
1. Increase `total_timeout_ms` in the config
2. Add delays between steps if needed: `script.delay(100)`
3. Check that expected text matches exactly what your CLI outputs
4. Terminal mode changes may affect timing - adjust timeouts accordingly

### Snapshot Mismatches

When snapshots don't match:
1. Review the colored diff output
2. Update snapshots with `-Dupdate-snapshots=true` if changes are expected
3. Use masking for dynamic content that changes between runs
4. Terminal features may affect output formatting - verify with different terminal modes

### Cross-Platform Issues

If tests fail on specific platforms:
1. The framework handles Linux/macOS differences automatically
2. Windows support is limited (PTY features are skipped)
3. Use capability detection to adapt tests to platform limitations
4. Check terminal environment variables (TERM, etc.) in CI/CD environments

## Contributing

See the main zcli project for contribution guidelines. This testing framework is designed to grow with the needs of CLI developers using zcli.