# Ticket 04: Sanitize Error Messages for Production

## Priority

🔴 **Critical**

## Component

`src/structured_errors.zig`, `src/errors.zig`

## Description

Error messages may expose sensitive information including internal file paths, system information, and implementation details. In production environments, this information disclosure could aid attackers in understanding the system structure and finding vulnerabilities.

## Information Disclosure Examples

### 1. File Path Exposure

```zig
// Current code in structured_errors.zig
.build_command_discovery_failed => |ctx| std.fmt.allocPrint(allocator,
    "Command discovery failed in '{s}': {s}",
    .{ ctx.file_path.?, ctx.details })  // Exposes internal paths
```

### 2. System Details

```zig
// Memory addresses, system paths, internal state
.system_out_of_memory => std.fmt.allocPrint(allocator,
    "System out of memory during {s} allocation", .{context})
```

### 3. Implementation Details

```zig
// Plugin internals, build paths, etc.
.plugin_error => |ctx| std.fmt.allocPrint(allocator,
    "Plugin '{s}' failed at {s}:{d}", .{ctx.plugin_name, ctx.file, ctx.line})
```

## Proposed Solution

### Error Message Levels

```zig
pub const ErrorVerbosity = enum {
    production,  // Minimal, safe messages
    development, // Full details for debugging
    debug,      // Maximum verbosity
};
```

### Sanitization Framework

```zig
pub const ErrorSanitizer = struct {
    verbosity: ErrorVerbosity,

    pub fn sanitizeMessage(self: @This(), error_type: anytype, context: anytype) ![]const u8 {
        return switch (self.verbosity) {
            .production => self.getProductionMessage(error_type),
            .development => self.getDevelopmentMessage(error_type, context),
            .debug => self.getDebugMessage(error_type, context),
        };
    }

    fn getProductionMessage(self: @This(), error_type: anytype) []const u8 {
        return switch (error_type) {
            .build_command_discovery_failed => "Command discovery failed",
            .system_out_of_memory => "Insufficient memory available",
            .plugin_error => "Plugin operation failed",
            .file_access_error => "File access error",
            // Generic fallback
            else => "An error occurred",
        };
    }
};
```

### Configuration Integration

#### Build-time Configuration

```zig
// In build.zig
const cmd_registry = zcli.build(b, exe, zcli_module, .{
    .error_verbosity = if (optimize == .ReleaseFast or optimize == .ReleaseSmall) .production else .development,
});
```

## Implementation Plan

### Phase 1: Core Sanitization (Week 1)

- [ ] Define `ErrorVerbosity` enum and `ErrorSanitizer` struct
- [ ] Implement production-safe messages for all error types
- [ ] Update `StructuredError.toString()` to use sanitizer
- [ ] Add build-time configuration

### Phase 2: Context-Aware Sanitization (Week 2)

- [ ] Implement path sanitization (remove system-specific parts)
- [ ] Add user-friendly error codes/references
- [ ] Implement development-mode enhanced messages

### Phase 3: Testing and Documentation (Week 3)

- [ ] Security testing for information disclosure
- [ ] User experience testing with production messages
- [ ] Documentation updates
- [ ] Error message localization framework

## Specific Error Categories

### 1. File System Errors

```zig
// Production: "Configuration file not found"
// Development: "Configuration file not found: ~/.myapp/config.toml"
// Debug: "Configuration file not found: /Users/john/.myapp/config.toml (errno=2)"
```

### 2. Plugin Errors

```zig
// Production: "Plugin failed to load"
// Development: "Plugin 'my-plugin' failed to load: invalid interface"
// Debug: "Plugin 'my-plugin' at /usr/lib/myapp/plugins/my-plugin.so failed: missing execute function"
```

### 3. Command Errors

```zig
// Production: "Command not found"
// Development: "Command 'deploy' not found. Similar: ['dev', 'delete']"
// Debug: "Command 'deploy' not found in registry. Available: [list of all commands] Discovery path: /path/to/commands"
```

## Security Considerations

### Path Sanitization

```zig
fn sanitizePath(allocator: std.mem.Allocator, path: []const u8, verbosity: ErrorVerbosity) ![]const u8 {
    return switch (verbosity) {
        .production => "<redacted>",
        .development => std.fs.path.basename(path),  // filename only
        .debug => path,  // full path
    };
}
```

### User Data Protection

```zig
// Never expose user input in production errors
fn sanitizeUserInput(input: []const u8, verbosity: ErrorVerbosity) []const u8 {
    return switch (verbosity) {
        .production => "<input>",
        .development => if (input.len > 50) input[0..47] ++ "..." else input,
        .debug => input,
    };
}
```

## Error Reference System

### Error Codes

```zig
pub const ErrorCode = enum {
    E001, // Command not found
    E002, // Invalid argument
    E003, // Plugin error
    E004, // System error

    pub fn getMessage(self: @This()) []const u8 {
        return switch (self) {
            .E001 => "Command not found. Use --help to see available commands.",
            .E002 => "Invalid argument provided. Check command usage with --help.",
            // ...
        };
    }
};
```

### User-Friendly References

```zig
// Production message
"Error E001: Command not found. Visit https://docs.myapp.com/errors/E001 for more information."
```

## Testing Strategy

### Information Disclosure Testing

- [ ] Scan all error messages for sensitive patterns
- [ ] Test with various system configurations
- [ ] Verify no internal paths leak in production mode
- [ ] Test error handling under different user privileges

### User Experience Testing

- [ ] Verify production messages are helpful
- [ ] Test that development messages aid debugging
- [ ] Ensure error codes provide useful guidance

## Backward Compatibility

- Development builds maintain current verbosity by default
- Production builds use sanitized messages
- All error types remain functional

## Impact

- **Security**: Eliminates information disclosure vulnerabilities
- **User Experience**: Cleaner, more professional error messages in production
- **Debugging**: Enhanced information available in development
- **Compliance**: Meets security requirements for production deployments

## Acceptance Criteria

- [ ] No sensitive information disclosed in production mode
- [ ] All error types have appropriate production messages
- [ ] Development mode preserves debugging information
- [ ] Configuration works at build-time
- [ ] Performance impact negligible
- [ ] Documentation updated with error handling guide

## Estimated Effort

**2-3 weeks** (1 week implementation, 1-2 weeks testing and refinement)
