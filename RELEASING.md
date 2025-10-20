# Releasing zcli

This guide covers how to release the zcli framework itself (not zcli-based CLI applications).

## Release System

zcli uses a **dual-tag system**:

1. **Library releases**: `v{version}` - For projects using zcli as a dependency
2. **CLI releases**: `zcli-v{version}` - Triggers GitHub Actions to build CLI binaries

Both tags should always point to the same commit and use the same version number.

## Prerequisites

- Push access to the repository
- Working directory must be clean (all changes committed)
- On the `main` branch
- All tests passing

## Quick Release (Recommended)

Use the release script from the repo root:

```bash
./scripts/release.sh 0.14.0
```

This script will:

1. ✓ Verify you're on main branch with a clean working tree
2. ✓ Run all tests
3. ✓ Update `build.zig.zon` version
4. ✓ Commit the version bump
5. ✓ Open your editor for release notes
6. ✓ Create both tags (`v{version}` and `zcli-v{version}`)
7. ✓ Show a summary with push command

After reviewing the summary, push with:

```bash
git push && git push origin v0.14.0 zcli-v0.14.0
```

## Manual Release Process

If you prefer to release manually:

### 1. Prepare

```bash
# Ensure you're on main with a clean tree
git status

# Run tests
zig build test
```

### 2. Update Version

Edit `build.zig.zon`:

```diff
 .{
     .name = .zcli,
-    .version = "0.13.0",
+    .version = "0.14.0",
     ...
 }
```

Commit:

```bash
git add build.zig.zon
git commit -m "Bump version to 0.14.0"
```

### 3. Create Tags

Library tag:

```bash
git tag -a v0.14.0 -m "Release v0.14.0

## New Features

- Feature 1
- Feature 2

## Bug Fixes

- Fix 1
- Fix 2"
```

CLI tag:

```bash
git tag -a zcli-v0.14.0 -m "Release CLI v0.14.0

See v0.14.0 for full release notes"
```

### 4. Push

```bash
git push
git push origin v0.14.0 zcli-v0.14.0
```

## What Happens Next

### 1. Library Release (`v{version}`)

- Projects depending on zcli can update to the new version
- Update your `build.zig.zon` dependency URL to reference the new tag

### 2. CLI Release (`zcli-v{version}`)

GitHub Actions automatically:
- Builds binaries for all platforms:
  - macOS (Intel and Apple Silicon)
  - Linux (x86_64 and ARM64)
  - Windows (x86_64)
- Creates a GitHub release
- Uploads the binaries
- Generates checksums

Monitor the workflow at: https://github.com/ryanhair/zcli/actions

### 3. Test Installation

After the workflow completes, test the installation script:

```bash
curl -fsSL https://raw.githubusercontent.com/ryanhair/zcli/main/install.sh | sh
zcli --version
```

### 4. Verify Release

- Check that all binaries were uploaded
- Test downloading and running a binary
- Verify checksums match

## Troubleshooting

### Tags already exist

If tags exist locally:

```bash
git tag -d v0.14.0 zcli-v0.14.0
```

If tags exist remotely:

```bash
git push origin :refs/tags/v0.14.0 :refs/tags/zcli-v0.14.0
```

### Forgot to update build.zig.zon

If you already created and pushed tags without updating `build.zig.zon`:

1. Delete the remote tags (see above)
2. Update `build.zig.zon` and commit
3. Recreate tags on the new commit
4. Push again

### Tests failing

Do not release with failing tests. Fix the tests first:

```bash
zig build test
```

### Build fails in CI

- Check the GitHub Actions logs
- Verify Zig version is correct in the workflow
- Test locally: `zig build -Doptimize=ReleaseFast`

## Version Numbering

We follow [Semantic Versioning](https://semver.org/):

- **Major** (X.0.0): Breaking changes to the public API
- **Minor** (0.X.0): New features, backward compatible
- **Patch** (0.0.X): Bug fixes, backward compatible

Examples:
- New feature (shared modules): `0.13.0` → `0.14.0`
- Bug fix: `0.14.0` → `0.14.1`
- Breaking API change: `0.14.1` → `1.0.0`

For pre-1.0 releases:
- Breaking changes can be minor version bumps
- We're still stabilizing the API

## Release Checklist

Before releasing, ensure:

- [ ] All tests pass (`zig build test`)
- [ ] Working tree is clean
- [ ] On main branch
- [ ] Version bumped in `build.zig.zon`
- [ ] Release notes prepared
- [ ] Both tags created (`v{version}` and `zcli-v{version}`)
- [ ] Tags point to the same commit
- [ ] Pushed to origin

## Important Notes

- The `zcli release` command **cannot** be used to release the zcli framework itself
  - It explicitly checks that it's running in a zcli-based project, not the zcli repo
  - Use `./scripts/release.sh` or the manual process instead

- Always update `build.zig.zon` **before** creating tags
  - Projects depending on zcli expect the version in the tag to match `build.zig.zon`
  - The Zig package manager uses this version for dependency resolution

- Both tags (`v{version}` and `zcli-v{version}`) must point to the same commit
  - Library users depend on `v{version}`
  - The GitHub Actions workflow is triggered by `zcli-v{version}`
