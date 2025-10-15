# zcli-version

Version information display plugin for zcli applications.

## Features

- Provides `--version` / `-V` global option
- Displays app name and version
- Stops command execution after showing version
- Zero configuration required

## Usage

Add to your `build.zig`:

```zig
const cmd_registry = zcli.generate(b, exe, zcli_module, .{
    .commands_dir = "src/commands",
    .plugins = &.{
        .{
            .name = "zcli-version",
            .path = "path/to/zcli-version",
        },
        // ... other plugins
    },
    .app_name = "myapp",
    .app_description = "My CLI application",
});
```

The version is automatically read from your `build.zig.zon` file.

## Command Line

```bash
# Show version
myapp --version
myapp -V

# Version works with any command (shows version and stops)
myapp command --version
```

## Implementation

The plugin:
1. Registers `--version` / `-V` as a global option
2. Sets a flag in the context when the option is detected
3. In the `preExecute` hook, checks the flag
4. If set, displays version and returns `null` to stop execution

## Testing

```bash
zig build test
```

## License

Same as zcli core.
