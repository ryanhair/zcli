# zcli-github-upgrade

Self-upgrade plugin for zcli applications that release binaries via GitHub Releases.

## Features

- ✨ Automatic version checking against GitHub Releases
- 🔒 Checksum verification for security
- 🔄 Atomic binary replacement
- 📢 Optional startup notifications for new versions
- 🎯 Platform detection (macOS/Linux, x86_64/aarch64)
- ✅ Binary validation before installation

## Usage

### 1. Add to your build.zig

```zig
const zcli = @import("zcli");

const cmd_registry = zcli.generate(b, exe, zcli_module, .{
    .commands_dir = "src/commands",
    .plugins = &.{
        .{
            .name = "zcli-github-upgrade",
            .path = "path/to/plugin",  // Or use dependency path
            .config = .{
                .repo = "username/repo",  // Required: Your GitHub repo
                .command_name = "upgrade",  // Optional: Command name (default: "upgrade")
                .inform_out_of_date = false,  // Optional: Show update notification on startup (default: false)
            },
        },
    },
    .app_name = "myapp",
    .app_version = "1.0.0",
    .app_description = "My awesome CLI",
});
```

**Note**: The `.config` field accepts a struct that's passed to the plugin's `init()` function at build time.

### 2. Use the upgrade command

```bash
# Check for updates
myapp upgrade --check

# Upgrade to latest version
myapp upgrade

# Force upgrade even if already on latest
myapp upgrade --force
```

## Configuration Options

### `repo` (required)
GitHub repository in `owner/repo` format.

Example: `"ryanhair/zcli"`

### `command_name` (optional)
Name of the upgrade command. Defaults to `"upgrade"`.

Example: `"self-upgrade"`, `"update"`

### `inform_out_of_date` (optional)
Whether to check for updates on startup and show a notification if a newer version is available. Defaults to `false`.

Set to `true` to enable automatic update checks.

### `out_of_date_message` (optional)
Custom message to show when a newer version is available. Supports the following placeholders:
- `{app}` - Application name
- `{current}` - Current version
- `{latest}` - Latest available version

Default message:
```
A new version of {app} is available: {latest} (current: {current})
Run '{app} upgrade' to update.
```

## Requirements

Your GitHub releases must:
1. Use semantic version tags (e.g., `v1.0.0`)
2. Include binaries named with pattern: `{app-name}-{arch}-{os}`
   - Example: `myapp-aarch64-macos`, `myapp-x86_64-linux`
3. Include a `checksums.txt` file with SHA256 checksums

The release workflow in the zcli repository (`.github/workflows/release.yml`) is a good example of the required setup.

## How It Works

1. **Version Check**: Queries GitHub API for the latest release
2. **Download**: Fetches the appropriate binary for your platform
3. **Verify**: Validates the binary against published checksums
4. **Test**: Runs `--version` on the new binary to ensure it works
5. **Replace**: Atomically replaces the current binary with the new one

## Security

- All downloads are verified against SHA256 checksums
- Binaries are tested before installation
- Download failures don't affect the currently running binary
- Uses HTTPS for all network requests

## Platform Support

- **macOS**: x86_64 (Intel), aarch64 (Apple Silicon)
- **Linux**: x86_64, aarch64

## Example with Notification

```zig
const cmd_registry = zcli.generate(b, exe, zcli_module, .{
    .commands_dir = "src/commands",
    .plugins = &.{
        .{
            .name = "zcli-github-upgrade",
            .path = "path/to/plugin",
            .config = .{
                .repo = "myorg/myapp",
                .inform_out_of_date = true,
                .out_of_date_message = "🎉 New version available: {latest} (you have {current})\nUpgrade now: {app} upgrade",
            },
        },
    },
    .app_name = "myapp",
    .app_version = "1.0.0",
    .app_description = "My awesome CLI",
});
```

When users run your CLI with an outdated version, they'll see:

```
🎉 New version available: 1.2.0 (you have 1.1.0)
Upgrade now: myapp upgrade
```

## Troubleshooting

### "Failed to fetch version"
- Check your internet connection
- Verify the GitHub repo name is correct
- Ensure the repository has at least one release

### "Checksum not found"
- Make sure your release includes a `checksums.txt` file
- Verify the binary name matches the expected pattern

### "Permission denied" when upgrading
- The binary may be installed in a system location requiring sudo
- Install to a user-writable location like `~/.local/bin`

### "New binary failed"
- The downloaded binary may be corrupted
- Check that the release was built correctly
- Try downloading and testing manually
