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

### Plugin System

- Allow external packages to provide commands
- Runtime plugin loading (if needed)
- Plugin discovery and registration

### Interactive Mode

- REPL for command exploration
- Interactive prompts for missing arguments
- Command history

### Middleware System

- Pre/post command hooks
- Authentication/authorization middleware
- Logging and telemetry hooks

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
