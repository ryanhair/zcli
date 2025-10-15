# zcli-completions

Shell completion management plugin for zcli. Automatically generates and installs shell completions for bash, zsh, and fish shells.

## Features

- **Automatic introspection**: Discovers commands and options at compile time
- **Multi-shell support**: Bash, Zsh, and Fish completions
- **Zero configuration**: No manual completion definitions needed
- **Smart completion**: Includes command descriptions, options, and subcommands

## Installation

Add the plugin to your `build.zig`:

```zig
const cmd_registry = zcli.generate(b, exe, zcli_module, .{
    .commands_dir = "src/commands",
    .plugins = &.{
        .{
            .name = "zcli-completions",
            .path = "path/to/zcli-completions",
        },
    },
    .app_name = "myapp",
    .app_version = "1.0.0",
    .app_description = "My CLI application",
});
```

And add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zcli_completions = .{ .path = "path/to/zcli_completions" },
},
```

## Usage

The plugin adds a `completions` command to your CLI with three actions:

### Generate Completions

Generate completion scripts to stdout:

```bash
myapp completions generate bash > completions.bash
myapp completions generate zsh > _myapp
myapp completions generate fish > myapp.fish
```

### Install Completions

Install completions to standard locations:

```bash
myapp completions install bash
myapp completions install zsh
myapp completions install fish
```

Installation paths:

- **Bash**: `~/.local/share/bash-completion/completions/<app>`
- **Zsh**: `~/.zsh/completions/_<app>`
- **Fish**: `~/.config/fish/completions/<app>.fish`

The install command will:

1. Generate the completion script
2. Create the necessary directories
3. Write the completion file
4. Display instructions for enabling completions

### Uninstall Completions

Remove installed completions:

```bash
myapp completions uninstall bash
myapp completions uninstall zsh
myapp completions uninstall fish
```

## How It Works

The plugin uses compile-time introspection to discover:

1. **Commands**: All commands from both file-based structure and plugins
2. **Options**: Command-specific options from `Options` structs
3. **Descriptions**: From `meta.description` and `meta.options`
4. **Global options**: Available to all commands (like `--help`)

### Compile-Time Introspection

The plugin automatically extracts option information by:

1. Scanning the `Options` struct for each command
2. Checking `meta.options` for descriptions and short flags
3. Determining value types (bool vs value-taking options)
4. Building `OptionInfo` structures at compile time

Example command structure:

```zig
pub const meta = .{
    .description = "List all items",
    .options = .{
        .verbose = .{ .desc = "Enable verbose output", .short = 'v' },
        .format = .{ .desc = "Output format", .short = 'f' },
    },
};

pub const Options = struct {
    verbose: bool = false,
    format: []const u8 = "table",
};
```

The plugin automatically generates completions for:

- `--verbose` / `-v` (flag, no value)
- `--format` / `-f` (takes value)

## Shell-Specific Details

### Bash

- Uses `bash-completion` framework
- Requires `bash-completion` package installed
- Supports nested subcommands
- Shows command descriptions in help

**Enable completions**:

Add to `~/.bashrc`:

```bash
if [ -f ~/.local/share/bash-completion/completions/myapp ]; then
    . ~/.local/share/bash-completion/completions/myapp
fi
```

Then: `source ~/.bashrc`

### Zsh

- Uses Zsh's `compsys` completion system
- Supports option grouping (e.g., `-vh` for `-v -h`)
- Rich descriptions with `_describe`
- Subcommand state machine

**Enable completions**:

Add to `~/.zshrc`:

```zsh
fpath=(~/.zsh/completions $fpath)
autoload -Uz compinit && compinit
```

Then: `source ~/.zshrc`

### Fish

- Uses Fish's declarative completion system
- Automatic loading from `~/.config/fish/completions/`
- Condition-based completion
- No configuration needed

**Enable completions**:

Fish automatically loads completions from `~/.config/fish/completions/`. Just start a new shell!

## Implementation Details

### File Structure

```
zcli-completions/
├── src/
│   ├── plugin.zig      # Main plugin with commands
│   ├── bash.zig        # Bash completion generator
│   ├── zsh.zig         # Zsh completion generator
│   └── fish.zig        # Fish completion generator
├── build.zig
├── build.zig.zon
└── README.md
```

### Generator Architecture

Each shell generator implements a `generate()` function:

```zig
pub fn generate(
    allocator: std.mem.Allocator,
    app_name: []const u8,
    commands: []const zcli.CommandInfo,
    global_options: []const zcli.OptionInfo,
) ![]const u8
```

This receives:

- **commands**: All available commands with metadata
- **global_options**: Options available to all commands
- Returns a shell-specific completion script as a string

### Command Info Structure

```zig
pub const CommandInfo = struct {
    path: []const []const u8,      // ["users", "list"]
    description: ?[]const u8,       // "List all users"
    examples: ?[]const []const u8,  // ["users list --active"]
    options: []const OptionInfo,    // Command-specific options
};
```

### Option Info Structure

```zig
pub const OptionInfo = struct {
    name: []const u8,           // "verbose"
    short: ?u8 = null,          // 'v'
    description: ?[]const u8,   // "Enable verbose output"
    takes_value: bool = false,  // false for bool, true for others
};
```

## Extending

To add support for another shell:

1. Create a new generator file (e.g., `powershell.zig`)
2. Implement the `generate()` function with the same signature
3. Add to `plugin.zig` imports and switch statements
4. Add installation path in `getInstallPath()`
5. Add enable instructions in `printEnableInstructions()`

## Testing

Test the plugin by:

1. **Building**: `zig build` from the plugin directory
2. **Generating**: Test each shell's output
3. **Installing**: Install to a test directory
4. **Using**: Source the completions and test tab completion

Example:

```bash
# Generate and test bash completions
myapp completions generate bash > /tmp/test-completion.bash
source /tmp/test-completion.bash
myapp <TAB>  # Should show commands
myapp users <TAB>  # Should show subcommands
```

## Limitations

- Plugin commands must be flat (no nested subcommands within plugins)
- Only supports boolean and value-taking options
- Does not complete argument values dynamically
- Shell-specific features may vary (e.g., zsh has richer option handling)

## License

MIT - Same as zcli core
