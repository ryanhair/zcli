# zcli-help Plugin

A comprehensive help system plugin for zcli applications.

## Features

- **Command Help**: Detailed help for individual commands
- **Application Help**: Overview of the entire application
- **Manual Pages**: Comprehensive documentation system
- **Multiple Formats**: Plain text, Markdown, JSON, and HTML output
- **Interactive Examples**: Context-aware examples and tips
- **Version Information**: Detailed version and plugin information

## Commands

### `help [command]`
Display help information for commands.

```bash
myapp help                    # Show application help
myapp help users              # Show help for 'users' command  
myapp help --verbose          # Show detailed help
myapp help --format=markdown # Output in Markdown format
```

### `version`
Display version information.

```bash
myapp version        # Show full version info
myapp version --short # Show version number only
```

### `manual [section]`
Display comprehensive manual pages.

```bash
myapp manual                     # Show overview manual
myapp manual commands            # Show commands section
myapp manual --format=markdown  # Output in Markdown
myapp manual --output=docs.md   # Save to file
```

## Plugin Features

### Command Transformer
Intercepts `--help` flags and provides contextual help:

```zig
pub fn transformCommand(comptime next: anytype) type {
    // Wraps command execution to handle --help flags
}
```

### Help Transformer  
Enhances help output with examples and tips:

```zig
pub fn transformHelp(comptime next: anytype) type {
    // Adds examples, tips, and enhanced formatting
}
```

### Context Extension
Stores help-related configuration:

```zig
pub const ContextExtension = struct {
    show_examples: bool,
    show_tips: bool,
    color_output: bool,
    max_width: usize,
};
```

## Usage in zcli Applications

### 1. Add as External Plugin

In your `build.zig`:

```zig
const zcli = @import("zcli");

pub fn build(b: *std.Build) void {
    // ... your build setup ...
    
    zcli.build(b, exe, .{
        .commands_dir = "src/commands",
        .plugins = &.{
            zcli.plugin(b, "zcli-help"),
        },
        .app_name = "myapp",
        .app_version = "1.0.0", 
        .app_description = "My CLI application",
    });
}
```

### 2. Add to build.zig.zon

```zig
.dependencies = .{
    .@"zcli-help" = .{
        .url = "https://github.com/example/zcli-help/archive/v1.0.0.tar.gz",
        .hash = "...",
    },
},
```

### 3. Use in Your Application

Once installed, the plugin automatically provides:
- `help` command
- `version` command  
- `manual` command
- `--help` flag support for all commands
- Enhanced help output with examples

## API Reference

### Commands

All commands follow zcli conventions with Args, Options, and meta structures.

### Transformers

- `transformCommand(comptime next: anytype) type` - Command execution wrapper
- `transformHelp(comptime next: anytype) type` - Help output enhancer

### Context Extension

Provides help-specific configuration and state management.

## Testing

```bash
cd plugins/zcli-help
zig build test
```

## License

Same as zcli framework.