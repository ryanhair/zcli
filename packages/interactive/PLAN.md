# Interactive CLI Testing Framework

A comprehensive framework for testing CLI applications that require user input, supporting real PTY allocation, terminal control, signal forwarding, and advanced terminal features.

## Overview

Interactive testing addresses the #1 developer pain point in CLI testing by providing sophisticated tools for testing applications that require user input, handle signals, adapt to terminal capabilities, and respond to terminal events.

## Core Features

### ✅ Real PTY Support (Completed)
- **True pseudo-terminal creation** using system calls (posix_openpt, grantpt, unlockpt, ptsname)
- **Fork/exec process spawning** with full file descriptor control
- **TTY detection that works** - child processes see true TTY environment
- **Cross-platform support** - Linux, macOS, with Windows fallbacks

### ✅ Interactive Script Builder (Completed)
- **Declarative interaction scripts** with method chaining API
- **Flexible text matching** - exact, partial, regex support
- **Timeout control** - per-step and global timeout configuration
- **Optional expectations** - mark steps as optional to avoid flaky tests
- **Hidden input support** - password prompts without echo

### ✅ Advanced Terminal Features (Completed - Phase 2)

#### Terminal Mode Preservation
- **Cross-platform termios handling** - unified interface for Linux and macOS
- **Raw mode support** - enhanced with cfmakeraw() for proper cross-platform raw mode
- **Echo control** - cross-platform echo flag handling with proper field access
- **Line buffering control** - canonical mode handling with platform-specific constants
- **Terminal settings preservation** - robust save/restore functionality with error handling

#### Comprehensive Signal Forwarding
- **Enhanced signal forwarding** - SIGINT, SIGTERM, SIGTSTP, SIGWINCH, SIGUSR1/2, SIGHUP, SIGQUIT, SIGCONT
- **PTY-based signal handling** - integrated with pseudo-terminal management
- **Process group management** - setpgid/getpgid support for proper signal propagation
- **Automatic setup** - signal forwarding enabled when forward_signals config is true
- **Error handling** - comprehensive errno handling with proper error types

#### Window Size Synchronization and Capability Detection
- **Window size synchronization** - synchronizeWindowSize() with verification and SIGWINCH forwarding
- **Auto-adjustment** - autoAdjustWindowSize() matches parent terminal size automatically
- **Capability detection** - detectTerminalCapabilities() runtime feature discovery
- **Enhanced configuration** - automatic window size adjustment when no size specified
- **SIGWINCH handling** - proper window size change signal forwarding to child processes

## API Reference

### Basic Usage

```zig
const std = @import("std");
const interactive = @import("interactive");

test "interactive login flow" {
    const allocator = std.testing.allocator;
    
    // Build an interactive script
    var script = interactive.InteractiveScript.init(allocator);
    defer script.deinit();
    
    _ = script
        .expect("Username:")
        .send("john_doe")
        .expect("Password:")
        .sendHidden("secret123")  // Hidden input for passwords
        .sendControl(.enter)
        .expect("Login successful")
        .withTimeout(5000);  // 5 second timeout
    
    const config = interactive.InteractiveConfig{
        .allocate_pty = true,  // Use real PTY for true TTY behavior
        .total_timeout_ms = 10000,
        .save_transcript = true,
    };
    
    var result = try interactive.runInteractive(
        allocator,
        &.{ "./myapp", "login" },
        script,
        config
    );
    defer result.deinit();
    
    try std.testing.expect(result.success);
}
```

### Control Sequences and Signals

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

### Available Control Sequences
- `.enter` - Enter/Return key
- `.ctrl_c` - Ctrl+C (SIGINT)
- `.ctrl_d` - Ctrl+D (EOF)
- `.escape` - Escape key
- `.tab` - Tab key
- `.up_arrow`, `.down_arrow`, `.left_arrow`, `.right_arrow` - Arrow keys

### Available Signals
- `.SIGINT` - Interrupt (Ctrl+C)
- `.SIGTERM` - Terminate
- `.SIGTSTP` - Terminal stop (Ctrl+Z)
- `.SIGCONT` - Continue
- `.SIGWINCH` - Window size change
- `.SIGHUP` - Hangup
- `.SIGUSR1`, `.SIGUSR2` - User-defined signals

### Advanced Terminal Features

#### Terminal Mode Control

```zig
test "raw mode for character input" {
    var script = interactive.InteractiveScript.init(allocator);
    defer script.deinit();
    
    // Send individual characters in raw mode
    _ = script
        .sendRaw("h")
        .sendRaw("e")
        .sendRaw("l")
        .sendRaw("p")
        .sendControl(.enter);
    
    const config = interactive.InteractiveConfig{
        .allocate_pty = true,
        .terminal_mode = .raw,  // Character-by-character input
    };
    
    var result = try interactive.runInteractive(allocator, &.{"./editor"}, script, config);
    defer result.deinit();
}
```

#### Window Size Management

```zig
test "responsive layout with auto-adjustment" {
    // Test with explicit narrow terminal
    const narrow_result = try interactive.runInteractive(
        allocator,
        &.{ "./myapp", "table" },
        script,
        .{ .terminal_size = .{ .rows = 24, .cols = 40 } }
    );
    defer narrow_result.deinit();
    
    // Test with auto-adjustment (matches parent terminal)
    const auto_result = try interactive.runInteractive(
        allocator,
        &.{ "./myapp", "table" },
        script,
        .{ .allocate_pty = true } // Auto-adjusts window size
    );
    defer auto_result.deinit();
    
    // Test SIGWINCH handling (window size change)
    var resize_script = interactive.InteractiveScript.init(allocator);
    defer resize_script.deinit();
    _ = resize_script
        .expect("Table displayed")
        .sendSignal(.SIGWINCH)  // Simulate window resize
        .expect("Layout updated");
        
    const resize_result = try interactive.runInteractive(
        allocator,
        &.{ "./myapp", "table" },
        resize_script,
        .{ .allocate_pty = true, .forward_signals = true }
    );
    defer resize_result.deinit();
}
```

#### Signal Forwarding

```zig
test "comprehensive signal handling" {
    var script = interactive.InteractiveScript.init(allocator);
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
    
    const config = interactive.InteractiveConfig{
        .allocate_pty = true,
        .forward_signals = true,    // Enhanced signal forwarding
        .terminal_mode = .cooked,   // Terminal mode preservation
    };
    
    var result = try interactive.runInteractive(
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

#### Password Input Testing

```zig
test "password prompt" {
    var script = interactive.InteractiveScript.init(allocator);
    defer script.deinit();
    
    _ = script
        .expect("Password:")
        .sendHidden("secret123")     // Hidden input
        .sendControl(.enter)
        .expect("Login successful");
    
    const config = interactive.InteractiveConfig{
        .allocate_pty = true,
        .disable_echo = true,        // No echo for passwords
    };
    
    var result = try interactive.runInteractive(
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

#### Terminal Capability Detection

```zig
test "runtime capability detection and adaptation" {
    const allocator = std.testing.allocator;
    
    // Create PTY manager for capability detection
    var pty_manager = interactive.PtyManager.init(allocator) catch return;
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
}
```

### Dual Mode Testing

Test both TTY and pipe modes automatically:

```zig
test "dual mode comparison" {
    var script = interactive.InteractiveScript.init(allocator);
    defer script.deinit();
    _ = script.expect("Hello");
    
    var dual_result = try interactive.runInteractiveDualMode(
        allocator,
        &.{ "./myapp", "echo", "Hello", "World" },
        script,
        interactive.InteractiveConfig{ .total_timeout_ms = 3000 }
    );
    defer dual_result.tty_result.deinit();
    defer dual_result.pipe_result.deinit();
    
    // At least one mode should succeed
    try std.testing.expect(dual_result.tty_result.success or dual_result.pipe_result.success);
}
```

### TTY Detection Testing

```zig
test "TTY detection" {
    var script = interactive.InteractiveScript.init(allocator);
    defer script.deinit();
    
    _ = script.expect("TTY detected:");
    
    // Test with real PTY - should show TTY: true
    const pty_config = interactive.InteractiveConfig{ .allocate_pty = true };
    var pty_result = try interactive.runInteractive(
        allocator, 
        &.{ "./myapp", "tty_test" }, 
        script, 
        pty_config
    );
    defer pty_result.deinit();
    
    // Test with pipes - should show TTY: false  
    const pipe_config = interactive.InteractiveConfig{ .allocate_pty = false };
    var pipe_result = try interactive.runInteractive(
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

## Configuration Options

### InteractiveConfig

```zig
const config = interactive.InteractiveConfig{
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

## Technical Implementation

### Real PTY Creation
- Using system calls: posix_openpt, grantpt, unlockpt, ptsname
- Cross-platform abstractions for termios handling
- Enhanced error handling with platform-specific error codes
- Safe capability detection that works in restricted environments

### Signal Management
- PTY-based signal forwarding for better reliability
- Process group management with setpgid/getpgid
- Comprehensive errno handling
- Automatic fallbacks when advanced features aren't available

### Terminal Control
- Cross-platform termios structure handling
- Raw mode support with cfmakeraw()
- Echo control with proper field access
- Terminal settings preservation and restoration

## Performance Characteristics

- **PTY Creation**: ~1ms overhead for real terminal creation
- **Signal Forwarding**: ~0.1ms per signal with PTY integration
- **Window Size Sync**: ~0.5ms for synchronization and verification
- **Memory Usage**: ~64KB buffer per interactive session (configurable)
- **Cross-platform**: Works reliably on Linux, macOS, with Windows fallbacks

## Error Handling

The framework provides comprehensive error handling for all terminal operations:

```zig
var result = interactive.runInteractive(allocator, command, script, config) catch |err| {
    switch (err) {
        error.ProcessStartFailed => std.log.err("Failed to start process"),
        error.ExpectationTimeout => std.log.err("Timed out waiting for output"),
        error.ExpectationNotMet => std.log.err("Expected text not found"),
        error.PtyAllocationFailed => std.log.err("PTY creation failed, falling back to pipes"),
        error.TerminalControlFailed => std.log.err("Terminal mode control failed"),
        error.SignalForwardingFailed => std.log.err("Signal forwarding failed"),
        else => std.log.err("Unexpected error: {}", .{err}),
    }
    return;
};
```

## Best Practices

1. **Use PTY for TTY-aware apps**: Enable `allocate_pty = true` when testing applications that behave differently in terminals

2. **Set appropriate timeouts**: Use reasonable timeouts to avoid slow tests while allowing for real application startup time

3. **Test both PTY and pipe modes**: Use dual mode testing to ensure your CLI works in both interactive and scripted environments

4. **Use optional expectations**: Mark non-critical expectations as optional to avoid flaky tests

5. **Leverage capability detection**: Use `detectTerminalCapabilities()` to adapt tests based on runtime environment

6. **Test terminal modes**: Use `.terminal_mode = .raw` for character-based input apps, `.cooked` for line-based apps

7. **Test responsive layouts**: Use different `.terminal_size` values or auto-adjustment to verify CLI adaptation

8. **Test comprehensive signal handling**: Use enhanced signal forwarding to verify graceful shutdown, suspend/resume, and window resize handling

9. **Use echo control for passwords**: Set `.disable_echo = true` when testing secure input prompts

10. **Save transcripts for debugging**: Enable transcript logging during development to debug complex interaction flows

## Troubleshooting

### PTY and Terminal Issues

If PTY allocation fails, the framework automatically falls back to pipes:
```
[default] (warn): Failed to create PTY: error.FileNotFound, falling back to pipes
```

### Signal Handling Issues
1. Ensure `.forward_signals = true` in your config
2. Use `.allocate_pty = true` for enhanced signal forwarding
3. Some signals may not be available in all test environments (this is expected)

### Window Size Issues
1. The framework automatically falls back to default sizes (24x80)
2. Use capability detection to verify window size support before testing
3. Auto-adjustment works by detecting the parent terminal size

### Cross-Platform Issues
1. The framework handles Linux/macOS differences automatically
2. Windows support is limited (PTY features are skipped)
3. Use capability detection to adapt tests to platform limitations

## Future Enhancements

- Enhanced Windows support with ConPTY
- Terminal color capability detection
- Automated screen recording for test failures
- Integration with terminal emulator testing
- Support for more terminal control sequences
- Advanced timing analysis for performance testing