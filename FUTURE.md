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
