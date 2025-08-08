# zcli Public API Reference

This document defines the clear public/private API boundaries for the zcli framework.

## Public API (Stable - Safe for End Users)

### Core Types
- `zcli.App(Registry)` - Main application struct
- `zcli.Context` - Command execution context
- `zcli.CommandMeta` - Command metadata structure

### Parsing Functions
- `zcli.parseArgs(ArgsType, args)` - Parse positional arguments
- `zcli.parseOptions(OptionsType, allocator, args)` - Parse command-line options
- `zcli.parseOptionsWithMeta(OptionsType, meta, allocator, args)` - Parse with custom option names
- `zcli.cleanupOptions(OptionsType, options, allocator)` - Clean up array option memory

### Error Types
- `zcli.ParseError` - Argument parsing errors
- `zcli.OptionParseError` - Option parsing errors  
- `zcli.CLIError` - General CLI errors

### Help Generation
- `zcli.generateAppHelp(registry, writer, name, version, description)` - Generate main app help
- `zcli.generateCommandHelp(...)` - Generate command-specific help

### Utility Functions
- `zcli.isNegativeNumber(arg)` - Check if string is negative number vs option

## Advanced API (Stable but Lower-Level)

### Advanced Help Generation
- `zcli.generateSubcommandsList(group, writer)` - Generate subcommand list for custom help

### Advanced Error Handling
- `zcli.CLIErrors.handleCommandNotFound(...)` - Handle unknown command errors
- `zcli.CLIErrors.handleSubcommandNotFound(...)` - Handle unknown subcommand errors
- `zcli.CLIErrors.handle*` - Other specific error handlers
- `zcli.CLIErrors.getExitCode(error)` - Get exit code for CLI error

## Build-Time API (For build.zig only)

### Build Utilities
- `build_utils.generateCommandRegistry(...)` - Generate command registry at build time
- `build_utils.isValidCommandName(name)` - Validate command names for security

## Internal API (Unstable - Not for End Users)

These are implementation details and may change without notice:

### Internal Parsing Utilities
- All functions in `src/options/utils.zig`
- All functions in `src/options/array_utils.zig` 
- All internal types like `ArrayListUnion`

### Internal Help Utilities
- `getAvailableCommands()`, `getAvailableSubcommands()` (used internally by App)

## Module Import Guidelines

- **End Users**: Use `@import("zcli")` for all public functionality
- **Build Scripts**: Use `@import("build_utils")` for build-time command discovery
- **Framework Development**: Import specific submodules like `@import("options/utils.zig")` only if needed

## Memory Management

⚠️ **CRITICAL**: Array options (`[][]const u8`, `[]i32`, etc.) allocate memory that must be cleaned up.

### Framework Mode (Automatic)
When using commands through the zcli framework, cleanup is **automatic**:
```zig
pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    // Use options.files freely - cleanup is automatic
    for (options.files) |file| { /* ... */ }
}
```

### Direct API Mode (Manual)  
When calling parsing functions directly, **you must cleanup**:
```zig
const result = try zcli.parseOptions(Options, allocator, args);
defer zcli.cleanupOptions(Options, result.options, allocator);  // REQUIRED!
```

📖 **See [MEMORY.md](MEMORY.md) for comprehensive memory management guide.**

## API Stability Promise

- **Public API**: Follows semantic versioning, breaking changes only on major versions
- **Advanced API**: Stable but may add new functions on minor versions
- **Build-Time API**: Stable for build.zig usage
- **Internal API**: No stability guarantees, may change on any version