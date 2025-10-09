# Release Process

This document outlines how to create a new release of zcli.

## Prerequisites

- Push access to the repository
- GitHub CLI (`gh`) installed (optional, but recommended)

## Release Steps

### 1. Update Version Numbers

Update the version in the following files:

- `projects/zcli/build.zig` - Update `.app_version`
- `Formula/zcli.rb` - Update `version` at the top

### 2. Test the Build

Ensure everything builds and tests pass:

```bash
cd projects/zcli
zig build -Doptimize=ReleaseFast
zig build test
```

Test the CLI:

```bash
./zig-out/bin/zcli --version
./zig-out/bin/zcli --help
```

### 3. Create and Push Git Tag

```bash
# From the repository root
git tag -a v0.1.0 -m "Release v0.1.0"
git push origin v0.1.0
```

### 4. Wait for GitHub Actions

The release workflow will automatically:
- Build binaries for all platforms (macOS x86_64/arm64, Linux x86_64/arm64)
- Create a GitHub release
- Upload the binaries
- Generate checksums

Monitor the workflow at: https://github.com/ryanhair/zcli/actions

### 5. Update Homebrew Formula

Once the release is created, download the checksums and update the formula:

1. Download checksums from the release page
2. Update `Formula/zcli.rb` with the correct SHA256 hashes:
   ```bash
   # Get checksums
   curl -L https://github.com/ryanhair/zcli/releases/download/v0.1.0/checksums.txt
   ```

3. Replace the placeholder SHA256 values in `Formula/zcli.rb`:
   - `REPLACE_WITH_AARCH64_MACOS_SHA256`
   - `REPLACE_WITH_X86_64_MACOS_SHA256`
   - `REPLACE_WITH_AARCH64_LINUX_SHA256`
   - `REPLACE_WITH_X86_64_LINUX_SHA256`

4. Commit and push the updated formula:
   ```bash
   git add Formula/zcli.rb
   git commit -m "Update Homebrew formula checksums for v0.1.0"
   git push
   ```

### 6. Test Installation

Test all installation methods:

#### Install Script
```bash
curl -fsSL https://raw.githubusercontent.com/ryanhair/zcli/main/install.sh | sh
zcli --version
```

#### Homebrew (if tap is set up)
```bash
brew install ryanhair/tap/zcli
zcli --version
```

#### Manual Download
```bash
# Download binary from releases page
# Test it works
```

### 7. Update Release Notes

Edit the GitHub release to add:
- Overview of changes
- Breaking changes (if any)
- Migration guide (if needed)
- Link to changelog

## Automation Script (Optional)

You can create a helper script to automate some of these steps:

```bash
#!/bin/bash
# release.sh - Helper script for creating releases

VERSION=$1

if [ -z "$VERSION" ]; then
    echo "Usage: ./release.sh v0.1.0"
    exit 1
fi

# Update version in files
echo "Updating version to $VERSION..."

# Create and push tag
git tag -a "$VERSION" -m "Release $VERSION"
git push origin "$VERSION"

echo "Release $VERSION created!"
echo "Monitor build at: https://github.com/ryanhair/zcli/actions"
echo ""
echo "Next steps:"
echo "1. Wait for GitHub Actions to complete"
echo "2. Update Homebrew formula with checksums"
echo "3. Test installation methods"
echo "4. Update release notes"
```

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
