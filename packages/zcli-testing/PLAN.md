# zcli-testing Development Plan

## Completed Features ✅

### Phase 1: Core Testing Infrastructure
- ✅ Snapshot testing with automatic diff visualization
- ✅ Basic runner for in-process and subprocess execution
- ✅ Assertion utilities (exit codes, output content)
- ✅ Interactive testing framework with script builder API

### Phase 2: PTY Support
- ✅ Real PTY allocation using system calls (posix_openpt, grantpt, unlockpt, ptsname)
- ✅ Fork/exec process spawning with full file descriptor control
- ✅ TTY detection that actually works (child processes see true TTY)
- ✅ Dual mode testing (PTY vs pipe comparison)
- ✅ Control sequences support (Enter, Ctrl+C, arrows, etc.)
- ✅ Hidden input for password prompts
- ✅ Comprehensive documentation

## In Progress 🚧

### Terminal Settings and Signal Forwarding
- Terminal mode preservation (raw mode, echo settings)
- Signal forwarding (SIGINT, SIGTSTP, SIGWINCH)
- Window size synchronization
- Terminal capability detection

## Planned Features 📋

### Phase 3: Compile-time Test Generation
**Impact: Revolutionary - Leverages Zig's unique capabilities**
- Automatically generate tests from command structures at compile time
- Test all valid/invalid argument combinations
- Edge case generation for numeric bounds, string lengths
- Type-based property testing
- Zero runtime overhead
- Example:
  ```zig
  // Single test spec generates hundreds of tests
  test "generated command tests" {
      try TestGen.fromRegistry(MyRegistry, .{
          .test_invalid_args = true,
          .test_flag_combinations = true,
          .test_type_boundaries = true,
      });
  }
  ```

### Phase 4: Virtual File System
**Impact: High - Eliminates file system test complexity**
- Sandboxed file operations without real file system access
- Automatic cleanup (no temp file management)
- Deterministic path handling across platforms
- File system state snapshots and restoration
- Mock file permissions and attributes
- Example:
  ```zig
  test "file operations" {
      var vfs = VirtualFS.init(allocator);
      defer vfs.deinit();
      
      try vfs.writeFile("/config.json", "{}");
      const result = try runWithVFS(vfs, &.{"myapp", "init"});
      try vfs.expectFile("/config.json").toContain("initialized");
  }
  ```

### Phase 5: Performance Benchmarking
**Impact: High - Makes performance testing effortless**
- Automatic performance metrics collection (zero overhead when disabled)
- Regression detection across test runs
- Statistical confidence intervals
- Comparative benchmarking between versions
- Microsecond precision timing
- Example:
  ```zig
  test "performance regression" {
      const result = try runWithBenchmark(&.{"myapp", "process", "large.csv"});
      try expectPerformance(result)
          .executionTime(.{ .max_ms = 100 })
          .memoryUsage(.{ .max_mb = 50 })
          .regression(.{ .threshold_percent = 10 });
  }
  ```

### Phase 6: Contract-based Mocking
**Impact: Medium - Enables reliable service integration testing**
- Compile-time verified mock contracts
- Automatic contract validation
- Network request interception
- External service simulation
- Example:
  ```zig
  test "API integration" {
      const mock = Contract.define(.{
          .endpoint = "/api/users",
          .request = UserRequest,
          .response = UserResponse,
      });
      
      try mock.expect(.{ .id = 123 })
          .returns(.{ .name = "John", .email = "john@example.com" });
      
      const result = try runWithMocks(&.{"myapp", "fetch-user", "123"}, &.{mock});
      try mock.verify();
  }
  ```

### Phase 7: Flaky Test Detection
**Impact: High - 47% of CI failures are flaky tests**
- Automatic multi-run detection during development
- Non-determinism source analysis
- Virtual clock for time-dependent operations
- Scheduling pattern variation
- Detailed flakiness reports
- Example:
  ```zig
  test "reliable timing test" {
      const detector = FlakyDetector.init(.{
          .runs = 10,
          .vary_scheduling = true,
      });
      
      const result = try detector.run(&.{"myapp", "timeout-test"});
      try detector.assertDeterministic();
  }
  ```

### Phase 8: Advanced Features
- **Shell Completion Testing**: Test bash/zsh/fish completions without shells installed
- **Plugin System Testing**: Dynamic loading with isolation
- **Cross-binary Testing**: Virtual process environment for multi-program tests
- **Watch Mode**: Instant test feedback during development
- **Coverage Analysis**: Command coverage, flag combination coverage
- **CI/CD Integration**: JUnit XML, TAP output, GitHub Actions integration

## Design Principles

1. **Zero Configuration**: Smart defaults for common cases
2. **Compile-time Power**: Leverage Zig's comptime for revolutionary capabilities
3. **Developer Experience**: Clear errors, suggested fixes, rich diffs
4. **Performance First**: Microsecond precision, zero overhead when not needed
5. **Cross-platform**: Write once, test everywhere (40+ platforms)
6. **Memory Safe**: Built-in leak detection, proper cleanup guarantees

## Success Metrics

- Reduce test code by 70% through generation
- Eliminate 95% of flaky test failures
- Sub-millisecond test execution for unit tests
- 100% platform coverage from single test suite
- Zero configuration for 90% of use cases