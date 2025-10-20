#!/usr/bin/env bash
set -euo pipefail

# Release script for the zcli framework repository
# This script handles the dual-tag release system:
# - v{version} for library releases (people using zcli as a dependency)
# - zcli-v{version} for CLI releases (triggers binary builds)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

error() {
    echo -e "${RED}✗ $1${NC}" >&2
    exit 1
}

success() {
    echo -e "${GREEN}✓ $1${NC}"
}

info() {
    echo -e "${YELLOW}→ $1${NC}"
}

# Parse arguments
if [ $# -ne 1 ]; then
    echo "Usage: $0 <version>"
    echo ""
    echo "Examples:"
    echo "  $0 0.14.0    # Create v0.14.0 and zcli-v0.14.0"
    echo "  $0 0.13.2    # Create v0.13.2 and zcli-v0.13.2"
    exit 1
fi

VERSION="$1"

# Validate version format
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error "Invalid version format: $VERSION (expected X.Y.Z)"
fi

# Ensure we're in the repo root
cd "$REPO_ROOT"

# Check we're on main
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "main" ]; then
    error "Not on main branch (currently on: $CURRENT_BRANCH)"
fi

# Check working tree is clean
if ! git diff-index --quiet HEAD --; then
    error "Working tree is not clean. Commit or stash changes first."
fi

# Check if tags already exist
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    error "Tag v$VERSION already exists"
fi

if git rev-parse "zcli-v$VERSION" >/dev/null 2>&1; then
    error "Tag zcli-v$VERSION already exists"
fi

# Run tests
info "Running tests..."
if ! zig build test; then
    error "Tests failed"
fi
success "Tests passed"

# Update build.zig.zon version
info "Updating build.zig.zon to version $VERSION..."
sed -i.bak "s/\.version = \".*\"/\.version = \"$VERSION\"/" build.zig.zon
rm build.zig.zon.bak
success "build.zig.zon updated"

# Commit the version bump
info "Committing version bump..."
git add build.zig.zon
git commit -m "Bump version to $VERSION"
success "Version bump committed"

# Get release notes
RELEASE_NOTES_FILE=$(mktemp)
cat > "$RELEASE_NOTES_FILE" << EOF
Release v$VERSION

## Changes

<!-- Add your release notes here -->
<!-- Describe new features, bug fixes, breaking changes, etc. -->

EOF

# Open editor for release notes
if [ -n "${EDITOR:-}" ]; then
    $EDITOR "$RELEASE_NOTES_FILE"
else
    vi "$RELEASE_NOTES_FILE"
fi

RELEASE_NOTES=$(cat "$RELEASE_NOTES_FILE")
rm "$RELEASE_NOTES_FILE"

# Create library tag
info "Creating library tag v$VERSION..."
git tag -a "v$VERSION" -m "$RELEASE_NOTES"
success "Library tag created"

# Create CLI tag (shorter message)
info "Creating CLI tag zcli-v$VERSION..."
CLI_NOTES="Release CLI v$VERSION

See v$VERSION for full release notes"
git tag -a "zcli-v$VERSION" -m "$CLI_NOTES"
success "CLI tag created"

# Show summary
echo ""
echo "════════════════════════════════════════════════════════════"
echo "Release $VERSION ready!"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "Tags created:"
echo "  • v$VERSION (library)"
echo "  • zcli-v$VERSION (CLI - triggers binary builds)"
echo ""
echo "Commit: $(git rev-parse HEAD | cut -c1-8)"
echo ""
echo "Release notes:"
echo "────────────────────────────────────────────────────────────"
echo "$RELEASE_NOTES"
echo "────────────────────────────────────────────────────────────"
echo ""
echo "To push and trigger the release:"
echo "  git push && git push origin v$VERSION zcli-v$VERSION"
echo ""
echo "To cancel (before pushing):"
echo "  git tag -d v$VERSION zcli-v$VERSION"
echo "  git reset --hard HEAD~1"
echo ""
