# Future Features for zcli

This document tracks features that are planned for future iterations of zcli.

## Async/Streaming Support

- Handle long-running commands gracefully
- Progress indicators for operations
- Streaming output support
- Integration with Zig's async story as it evolves

## Configuration Management

- Define where config files live (e.g., `~/.config/myapp/`)
- Config file format (likely TOML or custom)
- How commands access configuration
- Config file validation and migration
- Environment variable integration

## Shell Completion Generation

- Generate completion scripts for bash, zsh, fish, PowerShell
- Dynamic completions based on current state
- Completion for:
  - Commands and subcommands
  - Option names and values
  - File paths where appropriate
  - Custom completion functions

## Additional Future Considerations

### Color and Formatting

- ANSI color support with automatic detection
- Markdown rendering in help text
- Table formatting utilities
- Progress bars and spinners

### Interactive Mode

- REPL for command exploration
- Interactive prompts for missing arguments
- Command history

### Middleware System

- Pre/post command hooks
- Authentication/authorization middleware
- Logging and telemetry hooks

## Error Message Sanitization for CLI Applications

### Motivation

CLI applications built with zcli may handle sensitive information that shouldn't be exposed in error messages when deployed to production environments. Examples include:

- Database connection strings with credentials
- File paths revealing system architecture
- API endpoints and authentication tokens
- User data and personal information
- Internal network topology

### Concept

Provide a build-time error message sanitization system that CLI developers can use to automatically sanitize their application's error messages based on build configuration, with zero runtime overhead.

### Design Considerations

The current `StructuredError` enum is closed and specific to zcli's parsing errors. For this feature to be useful, we would need:

1. **Extensible Error System**: Allow CLI developers to define their own error types with sanitization rules
2. **Build-Time Configuration**: Verbosity levels (production/development/debug) set at compile time
3. **Zero Runtime Overhead**: All sanitization decisions made using `comptime`
4. **Selective Sanitization**: Some errors need full context even in production (e.g., "missing required argument 'username'") while others need sanitization (e.g., file paths)

### Potential Implementation Approaches

#### Option 1: Error Template System
```zig
// Developer defines error templates with sanitization rules
pub const AppErrors = zcli.ErrorTemplate(.{
    .database_connection_failed = .{
        .production = "Database connection failed",
        .development = "Database connection failed: {host}",
        .debug = "Database connection failed: {full_connection_string}",
    },
    .config_not_found = .{
        .production = "Configuration file not found",
        .development = "Configuration file not found: {basename}",
        .debug = "Configuration file not found: {full_path}",
    },
});
```

#### Option 2: Sanitization Utilities
```zig
// Provide utilities that developers can use in their own error handling
const sanitized_path = zcli.sanitize.path(full_path);
const sanitized_url = zcli.sanitize.url(connection_string);
```

#### Option 3: Custom Error Type with Trait
```zig
// Allow developers to implement a sanitization trait
pub const MyError = union(enum) {
    database_error: []const u8,
    
    pub fn sanitize(self: @This(), verbosity: zcli.ErrorVerbosity) []const u8 {
        return switch (verbosity) {
            .production => "Database error",
            .development => self.database_error,
        };
    }
};
```

### Benefits

- **Security**: Prevents information disclosure in production deployments
- **Debugging**: Preserves full error context during development
- **Performance**: Zero runtime cost through compile-time decisions
- **Flexibility**: Developers control what gets sanitized and how

### Challenges

- Making the system extensible while maintaining type safety
- Balancing simplicity with flexibility
- Ensuring the API is intuitive for CLI developers
- Integration with existing zcli error handling

### Use Cases

1. **DevOps Tools**: Hide internal infrastructure details
2. **Database CLIs**: Sanitize connection strings and queries
3. **API Clients**: Hide authentication tokens and endpoints
4. **File Management Tools**: Sanitize system paths
5. **Multi-tenant Applications**: Prevent cross-tenant information leakage

### Advanced Help Features

- Man page generation
- HTML documentation generation
- Interactive help browser

### Testing Utilities

- Mock context for unit testing
- Integration test helpers
- Command output assertions
- Test coverage for generated code

### Updates

- Support auto updates with hooks into common hosting systems.

## Multiple Error Collection and Recovery

### Motivation

Currently, zcli stops at the first parsing error encountered, requiring users to fix errors one-by-one and re-run commands repeatedly. This creates a poor developer experience, especially when learning a new CLI tool or when multiple arguments have issues.

### Desired Functionality

**Error Collection Mode**: Parse all arguments and options, collecting multiple errors before reporting them together.

**Best Effort Mode**: Parse what's possible, use sensible defaults for problematic fields, and report issues for reference while still executing the command.

**Smart Error Recovery**: Provide context-aware suggestions and corrections ("Did you mean --verbose instead of --verbos?").

### Example User Experience

```bash
# Current behavior (stops at first error)
$ myapp --unknown-opt --count=abc --name="" command arg1
Error: Unknown option: --unknown-opt

# After fixing first error
$ myapp --count=abc --name="" command arg1  
Error: Invalid value 'abc' for option --count. Expected integer.

# After fixing second error
$ myapp --count=5 --name="" command arg1
Error: Empty value for required option --name

# Desired behavior (collect all errors)
$ myapp --unknown-opt --count=abc --name="" command arg1
Multiple errors found:
1. Unknown option: --unknown-opt. Did you mean --known-opt?
2. Invalid value 'abc' for option --count. Expected integer.
3. Empty value for required option --name
```

### Benefits

1. **Improved Developer Experience**: Fix multiple issues in one iteration instead of discovering them one-by-one
2. **Better Learning Curve**: New users see all the issues with their command at once
3. **Faster Development Cycles**: Especially valuable for complex commands with many options
4. **Smart Suggestions**: Help users discover correct options and values
5. **Graceful Degradation**: Best effort mode allows partial execution when some arguments are problematic

### Design Principles for Future Implementation

**Standard Zig Patterns**: Use normal error unions, avoid complex result types or thread-local storage

**Simple API**: Extend existing functions with optional modes rather than introducing entirely new APIs

**Zero Runtime Overhead**: Error collection should be opt-in with minimal performance impact when disabled

**Backward Compatibility**: Existing code should continue working unchanged

### Potential Implementation Approach

```zig
// Simple extension to existing API
pub const ParseOptions = struct {
    collect_errors: bool = false,
    best_effort: bool = false,
    max_errors: usize = 10,
};

// Enhanced parsing that returns collected errors via out parameter
pub fn parseArgsExtended(
    comptime T: type,
    args: []const []const u8,
    options: ParseOptions,
    errors: ?*std.ArrayList(ZcliDiagnostic), // Optional error collection
) ZcliError!T {
    // Implementation would collect errors in the ArrayList if provided
    // Still return first error via normal error union for compatibility
}

// Usage for error collection
var collected_errors = std.ArrayList(ZcliDiagnostic).init(allocator);
defer collected_errors.deinit();

const result = parseArgsExtended(MyArgs, args, .{ .collect_errors = true }, &collected_errors);
if (result) |parsed| {
    // Success case
} else |err| {
    // Handle primary error, check collected_errors for additional context
    for (collected_errors.items) |diagnostic| {
        // Display each error with full context
    }
}
```

### Key Challenges to Solve Later

1. **Memory Management**: How to handle allocated diagnostic strings cleanly
2. **Error Prioritization**: Which error to return as the "primary" error when collecting multiple
3. **Recovery Strategies**: How to provide sensible defaults for different field types
4. **Error Deduplication**: Avoiding duplicate or redundant error messages
5. **Integration**: Making it work seamlessly with both args and options parsing

### Advanced Features (Even Further Future)

- **Error Grouping**: Group related errors together (e.g., all issues with the same option)
- **Interactive Correction**: Prompt users to fix errors interactively
- **Learning Mode**: Remember common mistakes and provide proactive suggestions
- **Structured Output**: Machine-readable error output for tooling integration
