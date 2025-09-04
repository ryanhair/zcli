# zcli-testing Design Document

## Overview

`zcli-testing` is a testing framework specifically designed for testing CLI applications built with zcli. It provides snapshot testing, in-process execution, ANSI-aware output comparison, and other CLI-specific testing utilities.

## Goals

1. **Zero Configuration**: Testing should work out of the box with sensible defaults
2. **Compile-Time Safety**: Leverage Zig's compile-time features for robust testing
3. **Fast Execution**: In-process testing for zcli apps, subprocess only when necessary
4. **Developer Experience**: Clear error messages, easy snapshot updates, intuitive API
5. **Cross-Platform**: Tests work identically on all platforms zcli supports

## Non-Goals

1. **General CLI Testing**: This is specifically for zcli-built applications
2. **Shell Script Testing**: We test CLI binaries, not shell scripts
3. **GUI Testing**: Terminal/console applications only

## Architecture

### Package Structure

```
packages/zcli-testing/
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig           # Public API surface
│   ├── snapshot.zig       # Snapshot testing implementation
│   ├── runner.zig         # Test execution (in-process & subprocess)
│   ├── ansi.zig          # ANSI escape sequence handling
│   ├── diff.zig          # Smart diffing for snapshots
│   └── utils.zig         # Helper utilities
├── examples/
│   └── basic/            # Example test suite
└── tests/                # Tests for the testing framework itself
```

### Core Components

#### 1. Test Runner
- **In-Process Mode**: Direct execution using zcli Registry (default for zcli apps)
- **Subprocess Mode**: External process execution (for integration tests)
- **Automatic Mode Selection**: Choose optimal mode based on test requirements

#### 2. Snapshot System
- **Compile-Time Embedding**: Snapshots embedded via `@embedFile`
- **Automatic Organization**: Snapshots organized by test file/function
- **Update Mechanism**: `--update-snapshots` flag for regeneration
- **Dynamic Content Masking**: Auto-detect timestamps, UUIDs, temp paths

#### 3. ANSI-Aware Comparison
- **Smart Diffing**: Understand terminal escape sequences
- **Style Preservation**: Maintain colors/styles in snapshots
- **Readable Diffs**: Show human-readable differences

## API Design

### Basic Testing API

```zig
const std = @import("std");
const zcli = @import("zcli");
const testing = @import("zcli-testing");

test "help command" {
    // Create test context
    var ctx = testing.Context.init(std.testing.allocator);
    defer ctx.deinit();
    
    // Run command
    const result = try ctx.run(&.{"--help"});
    
    // Verify output
    try testing.expectSnapshot(result.stdout, @src(), "help_output");
}
```

### In-Process Testing (zcli apps)

```zig
test "users list command" {
    var ctx = testing.Context.init(std.testing.allocator);
    defer ctx.deinit();
    
    // Uses zcli Registry for in-process execution
    var registry = try zcli.Registry.init(allocator);
    defer registry.deinit();
    
    const result = try ctx.runWithRegistry(&registry, &.{"users", "list", "--format=json"});
    
    // Assertions
    try testing.expectExitCode(result, 0);
    try testing.expectSnapshot(result.stdout, @src(), "users_list_json");
    try testing.expectStderrEmpty(result);
}
```

### Subprocess Testing

```zig
test "external binary integration" {
    var ctx = testing.Context.init(std.testing.allocator);
    defer ctx.deinit();
    
    // Force subprocess mode for external binary
    const result = try ctx.runSubprocess("/usr/bin/git", &.{"status"});
    
    try testing.expectContains(result.stdout, "On branch");
}
```

### Snapshot Management

```zig
// Snapshots stored in: tests/snapshots/<test_file>/<test_name>.txt

// Basic snapshot
try testing.expectSnapshot(output, @src(), "snapshot_name");

// ANSI-aware snapshot (preserves colors)
try testing.expectSnapshotAnsi(output, @src(), "colored_output");

// Masked snapshot (dynamic content)
try testing.expectSnapshotMasked(output, @src(), "with_timestamps", .{
    .masks = &.{
        .{ .pattern = "\\d{4}-\\d{2}-\\d{2}", .replacement = "YYYY-MM-DD" },
        .{ .pattern = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", .replacement = "UUID" },
    },
});
```

### Assertions

```zig
// Exit codes
try testing.expectExitCode(result, 0);
try testing.expectExitCodeNot(result, 0);

// Output content
try testing.expectStdoutEmpty(result);
try testing.expectStderrEmpty(result);
try testing.expectContains(result.stdout, "success");
try testing.expectNotContains(result.stderr, "error");

// Regex matching
try testing.expectMatches(result.stdout, "user_id: \\d+");

// JSON output
try testing.expectValidJson(result.stdout);
const json = try testing.parseJson(result.stdout, UserListResponse);
```

## Implementation Phases

### Phase 1: Core Snapshot Testing (MVP)
- [x] Basic snapshot comparison
- [x] Compile-time embedding via `@embedFile`
- [x] `--update-snapshots` mechanism
- [x] In-process execution for zcli apps
- [x] Basic assertions (exit code, contains)

### Phase 2: Enhanced Snapshots
- [ ] ANSI-aware comparison
- [ ] Dynamic content masking
- [ ] Smart diff output
- [ ] Snapshot organization by test

### Phase 3: Advanced Features
- [ ] Interactive testing support
- [ ] Performance benchmarking
- [ ] Coverage tracking
- [ ] Parallel test execution

### Phase 4: Developer Experience
- [ ] Rich error messages with suggestions
- [ ] Test generation from examples
- [ ] IDE integration helpers
- [ ] Documentation generation

## Snapshot Update Workflow

1. **Development Time**:
   ```bash
   # Developer changes CLI output
   $ zig build test
   ❌ Snapshot mismatch: help_output
      Expected: "MyApp v1.0.0"
      Actual:   "MyApp v1.1.0"
   
   # Review and update if intentional
   $ zig build test --update-snapshots
   ✅ Updated 1 snapshot
   ```

2. **CI/CD Time**:
   ```bash
   # CI runs tests - no updates allowed
   $ zig build test
   ❌ Snapshot mismatch - run with --update-snapshots locally
   ```

3. **Review Process**:
   - Snapshot changes appear in git diff
   - Reviewers see exactly what output changed
   - Intentional changes are approved and merged

## Build System Integration

```zig
// In user's build.zig
const testing = @import("zcli-testing");

pub fn build(b: *std.Build) void {
    // ... regular build setup ...
    
    // Add CLI tests
    const cli_tests = testing.addCliTests(b, .{
        .name = "cli-tests",
        .root_source_file = .{ .path = "tests/cli_test.zig" },
        .target = target,
        .optimize = optimize,
        .cli_exe = exe,  // The CLI executable to test
    });
    
    // Enable snapshot updates
    const update_snapshots = b.option(bool, "update-snapshots", "Update test snapshots") orelse false;
    cli_tests.update_snapshots = update_snapshots;
    
    const test_step = b.step("test-cli", "Run CLI tests");
    test_step.dependOn(&cli_tests.step);
}
```

## Error Messages

```zig
// Clear, actionable error messages

// Snapshot mismatch
error: Snapshot mismatch for 'help_output'
  Location: tests/cli_test.zig:42
  
  Expected (snapshot):
  | MyApp v1.0.0
  | Usage: myapp [command]
  |
  | Commands:
  |   users    Manage users
  
  Actual (current output):
  | MyApp v1.1.0          ← Different
  | Usage: myapp [command]
  |
  | Commands:
  |   users    Manage users
  +   posts    Manage posts  ← Added
  
  To update: zig build test-cli --update-snapshots

// Missing snapshot
error: No snapshot exists for 'new_command_output'
  Location: tests/cli_test.zig:56
  
  Create with: zig build test-cli --update-snapshots
```

## Example Test Suite

```zig
// tests/cli_test.zig
const std = @import("std");
const zcli = @import("zcli");
const testing = @import("zcli-testing");

test "help displays version and commands" {
    var ctx = testing.Context.init(std.testing.allocator);
    defer ctx.deinit();
    
    const result = try ctx.run(&.{"--help"});
    
    try testing.expectExitCode(result, 0);
    try testing.expectSnapshot(result.stdout, @src(), "help");
}

test "invalid command shows error" {
    var ctx = testing.Context.init(std.testing.allocator);
    defer ctx.deinit();
    
    const result = try ctx.run(&.{"invalid-command"});
    
    try testing.expectExitCode(result, 1);
    try testing.expectContains(result.stderr, "Unknown command");
    try testing.expectSnapshot(result.stderr, @src(), "invalid_command_error");
}

test "users list formats" {
    var ctx = testing.Context.init(std.testing.allocator);
    defer ctx.deinit();
    
    // Test JSON format
    {
        const result = try ctx.run(&.{"users", "list", "--format=json"});
        try testing.expectValidJson(result.stdout);
        try testing.expectSnapshot(result.stdout, @src(), "users_list_json");
    }
    
    // Test table format
    {
        const result = try ctx.run(&.{"users", "list", "--format=table"});
        try testing.expectSnapshot(result.stdout, @src(), "users_list_table");
    }
}
```

## Success Criteria

1. **Adoption**: Used by all zcli example projects
2. **Performance**: Tests run 10x faster than subprocess equivalent
3. **Reliability**: Zero flaky tests in CI/CD
4. **Developer Satisfaction**: Positive feedback on ease of use
5. **Coverage**: Can test 100% of CLI functionality

## Open Questions

1. Should we support testing of shell completions?
2. How to handle binary files in snapshots?
3. Should we provide a migration tool from other testing frameworks?
4. How to handle very large outputs (>1MB)?
5. Should we support video/screenshot capture for documentation?

## References

- [zcli Framework](../core/README.md)
- [Testing Research](../../docs/TESTING_RESEARCH.md)
- [Zig Testing Documentation](https://ziglang.org/documentation/master/#Zig-Test)