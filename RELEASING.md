# Release Process

This document outlines how to create a new release of zcli.

## Prerequisites

- Push access to the repository
- Working directory must be clean (all changes committed)
- On the `main` branch

## Quick Release (Recommended)

The `zcli release` command automates the entire release process:

```bash
cd projects/zcli

# Bump patch version (1.0.0 → 1.0.1)
zig-out/bin/zcli release patch

# Bump minor version (1.0.0 → 1.1.0)
zig-out/bin/zcli release minor

# Bump major version (1.0.0 → 2.0.0)
zig-out/bin/zcli release major

# Set explicit version
zig-out/bin/zcli release 1.5.0
```

### What the Release Command Does

1. **Detects current version** from git tags
2. **Calculates new version** based on your input
3. **Runs safety checks**:
   - Ensures working tree is clean
   - Verifies you're on the correct branch (default: `main`)
4. **Runs tests** (`zig build test`)
5. **Opens editor** for release notes (pre-filled with commit log)
6. **Prompts for confirmation**
7. **Creates annotated git tag** with release notes
8. **Pushes tag to origin**

### Release Options

```bash
# Preview without executing
zcli release patch --dry-run

# Skip tests (not recommended)
zcli release patch --skip-tests

# Create tag but don't push
zcli release patch --no-push

# Skip safety checks
zcli release patch --skip-checks

# Sign the tag with GPG
zcli release patch --sign

# Provide release message directly (skip editor)
zcli release patch --message "Bug fixes and improvements"

# Release from different branch
zcli release patch --branch develop
```

## After Release

### 1. Wait for GitHub Actions

The release workflow automatically:
- Builds binaries for all platforms (macOS x86_64/arm64, Linux x86_64/arm64)
- Creates a GitHub release
- Uploads the binaries
- Generates checksums

Monitor the workflow at: https://github.com/ryanhair/zcli/actions

### 2. Test Installation

Test the installation script:

```bash
curl -fsSL https://raw.githubusercontent.com/ryanhair/zcli/main/install.sh | sh
zcli --version
```

### 3. Verify Release

- Check that all binaries were uploaded
- Test downloading and running a binary
- Verify checksums match

## Troubleshooting

### Build Fails in CI

- Check the GitHub Actions logs
- Verify Zig version is correct in the workflow
- Test locally: `zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl`

### Checksums Don't Match

- Re-download the binary and checksum file
- Verify you're using the correct platform identifier
- Check that the binary wasn't corrupted during download

### Install Script Fails

- Test locally with: `sh -x install.sh` for verbose output
- Verify the URLs in the script match the release structure
- Check that all binaries were uploaded correctly

## Version Numbering

Follow [Semantic Versioning](https://semver.org/):

- **MAJOR** version when you make incompatible API changes
- **MINOR** version when you add functionality in a backward compatible manner
- **PATCH** version when you make backward compatible bug fixes

For pre-1.0 releases:
- Breaking changes can be MINOR version bumps
- We're still stabilizing the API
