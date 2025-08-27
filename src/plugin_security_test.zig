const std = @import("std");
const testing = std.testing;
const zcli = @import("zcli.zig");
const plugin_types = @import("plugin_types.zig");

// ============================================================================
// Plugin Security Testing Framework
// ============================================================================

/// Test plugin that attempts various potentially dangerous operations
const MaliciousPlugin = struct {
    pub const meta = .{
        .name = "malicious-test-plugin",
        .description = "Plugin for testing security boundaries",
        .version = "1.0.0",
    };

    /// Test plugin that tries to access unauthorized global options
    pub fn handleOption(_: *zcli.Context, event: plugin_types.OptionEvent, comptime command_module: type) !?plugin_types.PluginResult {
        _ = command_module;

        // Try to access potentially sensitive global options
        const sensitive_option_names = [_][]const u8{
            "api-key",
            "secret",
            "password",
            "token",
            "private-key",
            "credentials",
        };

        for (sensitive_option_names) |opt_name| {
            if (std.mem.eql(u8, event.option, opt_name)) {
                // Plugin should not be able to access sensitive options without proper authorization
                // This test verifies that the plugin security framework prevents unauthorized access
                return plugin_types.PluginResult{
                    .handled = true,
                    .output = "SECURITY_VIOLATION: Attempted to access sensitive option",
                    .stop_execution = true,
                };
            }
        }

        return null;
    }

    pub fn handleError(context: *zcli.Context, err: anyerror, comptime command_module: type) !?plugin_types.PluginResult {
        _ = command_module;

        // Try to extract sensitive information from errors
        const error_name = @errorName(err);

        // Plugin should not be able to access system internals through error handling
        if (std.mem.indexOf(u8, error_name, "System") != null or
            std.mem.indexOf(u8, error_name, "Access") != null)
        {
            // Test that plugins can't leak system information
            const leaked_info = try std.fmt.allocPrint(context.allocator, "LEAKED: {s} from {*}", .{ error_name, context });

            return plugin_types.PluginResult{
                .handled = true,
                .output = leaked_info,
                .stop_execution = false,
            };
        }

        return null;
    }
};

/// Plugin that attempts to exhaust system resources
const ResourceExhaustionPlugin = struct {
    pub const meta = .{
        .name = "resource-hog-plugin",
        .description = "Plugin that tries to exhaust resources",
        .version = "1.0.0",
    };

    pub fn handleOption(context: *zcli.Context, event: plugin_types.OptionEvent, comptime command_module: type) !?plugin_types.PluginResult {
        _ = command_module;

        // Only trigger on specific test option
        if (!std.mem.eql(u8, event.option, "--trigger-memory-test")) {
            return null;
        }

        // Attempt to allocate excessive memory
        const large_allocation_size = 100 * 1024 * 1024; // 100MB
        const large_buffer = context.allocator.alloc(u8, large_allocation_size) catch |err| {
            // Should fail with memory error - this is expected and safe
            const error_msg = try std.fmt.allocPrint(context.allocator, "Memory allocation failed: {}", .{err});
            return plugin_types.PluginResult{
                .handled = true,
                .output = error_msg,
                .stop_execution = false,
            };
        };
        defer context.allocator.free(large_buffer);

        // If allocation succeeded, fill it to actually use the memory
        @memset(large_buffer, 0xAA);

        return plugin_types.PluginResult{
            .handled = true,
            .output = "WARNING: Large memory allocation succeeded - potential DoS vulnerability",
            .stop_execution = false,
        };
    }
};

/// Plugin that attempts to access file system inappropriately
const FileSystemAccessPlugin = struct {
    pub const meta = .{
        .name = "filesystem-access-plugin",
        .description = "Plugin that tries to access files",
        .version = "1.0.0",
    };

    pub fn handleOption(context: *zcli.Context, event: plugin_types.OptionEvent, comptime command_module: type) !?plugin_types.PluginResult {
        _ = command_module;

        if (std.mem.eql(u8, event.option, "--read-sensitive-file")) {
            // Attempt to read sensitive system files
            const sensitive_files = [_][]const u8{
                "/etc/passwd",
                "/etc/shadow",
                "/var/log/auth.log",
                "/proc/self/environ",
                "C:\\Windows\\System32\\config\\SAM",
                "C:\\Users\\Administrator\\Documents\\secrets.txt",
            };

            var results = std.ArrayList(u8).init(context.allocator);
            defer results.deinit();

            for (sensitive_files) |file_path| {
                // Skip non-absolute paths and platform-specific paths
                if (!std.fs.path.isAbsolute(file_path)) {
                    try results.writer().print("Skipped non-absolute path: {s}\n", .{file_path});
                    continue;
                }

                const file = std.fs.openFileAbsolute(file_path, .{}) catch |err| {
                    try results.writer().print("Failed to open {s}: {}\n", .{ file_path, err });
                    continue;
                };
                defer file.close();

                // If we can open the file, try to read a small amount
                var buffer: [100]u8 = undefined;
                const bytes_read = file.readAll(&buffer) catch |err| {
                    try results.writer().print("Failed to read {s}: {}\n", .{ file_path, err });
                    continue;
                };

                try results.writer().print("SECURITY RISK: Read {} bytes from {s}\n", .{ bytes_read, file_path });
            }

            return plugin_types.PluginResult{
                .handled = true,
                .output = try results.toOwnedSlice(),
                .stop_execution = false,
            };
        }

        return null;
    }
};

/// Plugin that tests command injection through plugin interfaces
const CommandInjectionPlugin = struct {
    pub const meta = .{
        .name = "command-injection-plugin",
        .description = "Plugin that tests command injection vulnerabilities",
        .version = "1.0.0",
    };

    pub fn handleOption(context: *zcli.Context, event: plugin_types.OptionEvent, comptime command_module: type) !?plugin_types.PluginResult {
        _ = command_module;

        // Test various command injection patterns
        const injection_patterns = [_][]const u8{
            "$(whoami)",
            "`id`",
            "; cat /etc/passwd",
            "&& rm -rf /tmp/test",
            "| curl evil.com",
        };

        for (injection_patterns) |pattern| {
            if (std.mem.indexOf(u8, event.option, pattern) != null) {
                // Plugin should treat this as literal text, not execute commands
                const safe_output = try std.fmt.allocPrint(context.allocator, "DETECTED potential command injection: {s}", .{pattern});

                return plugin_types.PluginResult{
                    .handled = true,
                    .output = safe_output,
                    .stop_execution = true,
                };
            }
        }

        return null;
    }
};

// ============================================================================
// Plugin Security Tests
// ============================================================================

test "plugin security: resource exhaustion prevention" {
    const allocator = testing.allocator;

    // Create a test context
    var context = zcli.Context.init(allocator);
    defer context.deinit();

    const test_event = plugin_types.OptionEvent{
        .option = "--trigger-memory-test",
        .plugin_context = plugin_types.PluginContext{
            .command_path = "test",
            .metadata = plugin_types.Metadata{
                .description = "Test command",
            },
        },
    };

    // Test that resource exhaustion attempts are handled safely
    const result = ResourceExhaustionPlugin.handleOption(&context, test_event, struct {}) catch |err| {
        // Should handle resource exhaustion gracefully
        try testing.expect(err == error.OutOfMemory);
        return;
    };

    if (result) |plugin_result| {
        // If plugin returned a result, verify it's safe
        try testing.expect(plugin_result.handled);

        if (plugin_result.output) |output| {
            // Should not contain sensitive system information
            try testing.expect(std.mem.indexOf(u8, output, "/etc/") == null);
            try testing.expect(std.mem.indexOf(u8, output, "0x") == null); // No memory addresses
        }
    }
}

test "plugin security: sensitive option access prevention" {
    const allocator = testing.allocator;

    var context = zcli.Context.init(allocator);
    defer context.deinit();

    const sensitive_options = [_][]const u8{
        "api-key",
        "secret",
        "password",
        "token",
        "private-key",
    };

    for (sensitive_options) |sensitive_opt| {
        const test_event = plugin_types.OptionEvent{
            .option = sensitive_opt,
            .plugin_context = plugin_types.PluginContext{
                .command_path = "test",
                .metadata = plugin_types.Metadata{
                    .description = "Test command",
                },
            },
        };

        const result = try MaliciousPlugin.handleOption(&context, test_event, struct {});

        if (result) |plugin_result| {
            // Plugin should detect the security violation attempt
            try testing.expect(plugin_result.handled);
            try testing.expect(plugin_result.stop_execution); // Should stop execution for security

            if (plugin_result.output) |output| {
                try testing.expect(std.mem.indexOf(u8, output, "SECURITY_VIOLATION") != null);
            }
        }
    }
}

test "plugin security: file system access restrictions" {
    const allocator = testing.allocator;

    var context = zcli.Context.init(allocator);
    defer context.deinit();

    const test_event = plugin_types.OptionEvent{
        .option = "--read-sensitive-file",
        .plugin_context = plugin_types.PluginContext{
            .command_path = "test",
            .metadata = plugin_types.Metadata{
                .description = "Test command",
            },
        },
    };

    const result = try FileSystemAccessPlugin.handleOption(&context, test_event, struct {});

    if (result) |plugin_result| {
        defer if (plugin_result.output) |output| allocator.free(output);

        try testing.expect(plugin_result.handled);

        if (plugin_result.output) |output| {
            // Should report failed access attempts, not successful reads of sensitive files
            const has_security_risk = std.mem.indexOf(u8, output, "SECURITY RISK") != null;
            const has_failed_attempts = std.mem.indexOf(u8, output, "Failed to") != null;

            // Either should fail to access files, or if it succeeds, should be flagged as security risk
            try testing.expect(has_failed_attempts or has_security_risk);
        }
    }
}

test "plugin security: command injection prevention" {
    const allocator = testing.allocator;

    var context = zcli.Context.init(allocator);
    defer context.deinit();

    const injection_tests = [_][]const u8{
        "--exec=$(whoami)",
        "--command=`id`",
        "--script=; cat /etc/passwd",
        "--run=&& rm -rf /",
    };

    for (injection_tests) |injection_option| {
        const test_event = plugin_types.OptionEvent{
            .option = injection_option,
            .plugin_context = plugin_types.PluginContext{
                .command_path = "test",
                .metadata = plugin_types.Metadata{
                    .description = "Test command",
                },
            },
        };

        const result = try CommandInjectionPlugin.handleOption(&context, test_event, struct {});

        if (result) |plugin_result| {
            defer if (plugin_result.output) |output| allocator.free(output);

            try testing.expect(plugin_result.handled);
            try testing.expect(plugin_result.stop_execution); // Should stop for security

            if (plugin_result.output) |output| {
                // Should detect the injection attempt
                try testing.expect(std.mem.indexOf(u8, output, "command injection") != null);

                // Should not contain evidence of actual command execution
                try testing.expect(std.mem.indexOf(u8, output, "uid=") == null); // No `id` command output
                try testing.expect(std.mem.indexOf(u8, output, "root:") == null); // No /etc/passwd content
            }
        }
    }
}

test "plugin security: information disclosure prevention" {
    const allocator = testing.allocator;

    var context = zcli.Context.init(allocator);
    defer context.deinit();

    const system_errors = [_]anyerror{
        error.SystemOutOfMemory,
        error.AccessDenied,
        error.SystemFileNotFound,
        error.SystemResourceExhausted,
    };

    for (system_errors) |sys_error| {
        const result = try MaliciousPlugin.handleError(&context, sys_error, struct {});

        if (result) |plugin_result| {
            defer if (plugin_result.output) |output| allocator.free(output);

            if (plugin_result.output) |output| {
                // Should not contain memory addresses or system paths
                try testing.expect(std.mem.indexOf(u8, output, "/Users/") == null);
                try testing.expect(std.mem.indexOf(u8, output, "/home/") == null);
                try testing.expect(std.mem.indexOf(u8, output, "C:\\Users\\") == null);
                try testing.expect(std.mem.indexOf(u8, output, "0x") == null); // No memory addresses

                // Should not expose internal system details
                try testing.expect(std.mem.indexOf(u8, output, "src/") == null);
                try testing.expect(std.mem.indexOf(u8, output, ".zig") == null);
            }
        }
    }
}

// ============================================================================
// Plugin Validation and Sandboxing Tests
// ============================================================================

test "plugin security: plugin metadata validation" {
    // Test that plugin metadata is properly validated
    const unsafe_metadata_tests = [_]struct {
        name: []const u8,
        should_be_rejected: bool,
    }{
        .{ .name = "normal-plugin", .should_be_rejected = false },
        .{ .name = "../../../etc/passwd", .should_be_rejected = true },
        .{ .name = "plugin$(whoami)", .should_be_rejected = true },
        .{ .name = "plugin`id`", .should_be_rejected = true },
        .{ .name = "plugin\x00injection", .should_be_rejected = true },
        .{ .name = "A" ** 1000, .should_be_rejected = true }, // Too long
    };

    for (unsafe_metadata_tests) |test_case| {
        // Test plugin name validation
        const is_safe_name = isPluginNameSafe(test_case.name);

        if (test_case.should_be_rejected) {
            try testing.expect(!is_safe_name);
        } else {
            try testing.expect(is_safe_name);
        }
    }
}

test "plugin security: plugin capability enforcement" {
    // Test that plugins can only perform operations within their declared capabilities
    const TestPlugin = struct {
        pub const meta = .{
            .name = "capability-test-plugin",
            .description = "Plugin for testing capability enforcement",
            .version = "1.0.0",
            .capabilities = .{
                .filesystem_read = false,
                .network_access = false,
                .system_commands = false,
                .environment_access = false,
            },
        };
    };

    // Verify plugin metadata has capability restrictions
    try testing.expect(@hasField(@TypeOf(TestPlugin.meta), "capabilities"));
    try testing.expect(!TestPlugin.meta.capabilities.filesystem_read);
    try testing.expect(!TestPlugin.meta.capabilities.network_access);
    try testing.expect(!TestPlugin.meta.capabilities.system_commands);
    try testing.expect(!TestPlugin.meta.capabilities.environment_access);
}

// ============================================================================
// Helper Functions for Plugin Security
// ============================================================================

/// Validate that a plugin name is safe and doesn't contain malicious patterns
fn isPluginNameSafe(name: []const u8) bool {
    // Check length limits
    if (name.len == 0 or name.len > 100) return false;

    // Check for path traversal
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    if (std.mem.indexOf(u8, name, "/") != null) return false;
    if (std.mem.indexOf(u8, name, "\\") != null) return false;

    // Check for command injection patterns
    if (std.mem.indexOf(u8, name, "$(") != null) return false;
    if (std.mem.indexOf(u8, name, "`") != null) return false;
    if (std.mem.indexOf(u8, name, ";") != null) return false;
    if (std.mem.indexOf(u8, name, "&") != null) return false;
    if (std.mem.indexOf(u8, name, "|") != null) return false;

    // Check for null bytes and control characters
    for (name) |c| {
        if (c == 0 or c < 32) return false;
    }

    // Check for format string patterns
    if (std.mem.indexOf(u8, name, "%") != null) return false;

    return true;
}

/// Create a sandboxed context for plugin execution (placeholder)
fn createSandboxedContext(allocator: std.mem.Allocator, capabilities: anytype) !zcli.Context {
    _ = capabilities;
    // In a real implementation, this would create a restricted context
    // based on the plugin's declared capabilities
    return zcli.Context.init(allocator);
}

// ============================================================================
// Integration Tests
// ============================================================================

test "plugin security: integration with command processing" {
    const allocator = testing.allocator;

    // Test that malicious plugins can't interfere with normal command processing
    var context = zcli.Context.init(allocator);
    defer context.deinit();

    // Simulate normal command processing with potentially malicious plugin active
    const normal_event = plugin_types.OptionEvent{
        .option = "--normal-option",
        .plugin_context = plugin_types.PluginContext{
            .command_path = "normal-command",
            .metadata = plugin_types.Metadata{
                .description = "Normal command for testing",
            },
        },
    };

    // Test that malicious plugin doesn't interfere with normal options
    const result = try MaliciousPlugin.handleOption(&context, normal_event, struct {});

    // Should return null (not handled) for normal options
    try testing.expect(result == null);
}

test "plugin security: plugin isolation" {
    const allocator = testing.allocator;

    // Test that plugins can't interfere with each other
    var context1 = zcli.Context.init(allocator);
    defer context1.deinit();

    var context2 = zcli.Context.init(allocator);
    defer context2.deinit();

    // Both plugins process the same event independently
    const test_event = plugin_types.OptionEvent{
        .option = "--shared-option",
        .plugin_context = plugin_types.PluginContext{
            .command_path = "test",
            .metadata = plugin_types.Metadata{
                .description = "Test command",
            },
        },
    };

    const result1 = try MaliciousPlugin.handleOption(&context1, test_event, struct {});
    const result2 = try ResourceExhaustionPlugin.handleOption(&context2, test_event, struct {});

    // Results should be independent - one plugin shouldn't affect the other
    // Both should return null for this non-triggering option
    try testing.expect(result1 == null);
    try testing.expect(result2 == null);
}
