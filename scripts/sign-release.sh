#!/usr/bin/env bash
set -euo pipefail

# Offline release signing for zcli (see docs/RELEASE-SIGNING.md, ADR-0023).
#
# The release workflow publishes the CLI release as a DRAFT. This script — run
# on the maintainer's machine, with a signing key that never touches CI —
# downloads checksums.txt, signs it with minisign, uploads the detached
# signature (checksums.txt.minisig), and flips the release to published.
#
# The signing key lives in your password manager. Export it to a file for the
# duration of a release (or point MINISIGN_SECRET_KEY at it), then remove it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error()   { echo -e "${RED}✗ $1${NC}" >&2; exit 1; }
success() { echo -e "${GREEN}✓ $1${NC}"; }
info()    { echo -e "${YELLOW}→ $1${NC}"; }

# Default signing key location; override with MINISIGN_SECRET_KEY or -s.
SECRET_KEY="${MINISIGN_SECRET_KEY:-$HOME/.minisign/minisign.key}"
# Committed public key, used to self-verify the signature we just produced.
PUBKEY_FILE="$REPO_ROOT/docs/zcli-minisign.pub"

usage() {
    echo "Usage: $0 [-s <secret-key-file>] <version-or-tag>"
    echo ""
    echo "Examples:"
    echo "  $0 0.20.0                 # signs & publishes the zcli-v0.20.0 draft"
    echo "  $0 zcli-v0.20.0           # same, full tag form"
    echo "  $0 -s ./key.sec 0.20.0    # use a specific secret key file"
    exit 1
}

while getopts "s:h" opt; do
    case "$opt" in
        s) SECRET_KEY="$OPTARG" ;;
        h|*) usage ;;
    esac
done
shift $((OPTIND - 1))

[ $# -eq 1 ] || usage
ARG="$1"

# Accept either a bare version (0.20.0) or the full CLI tag (zcli-v0.20.0).
case "$ARG" in
    zcli-v*) TAG="$ARG" ;;
    *)       TAG="zcli-v$ARG" ;;
esac

command -v gh >/dev/null 2>&1       || error "gh (GitHub CLI) is required but not found"
command -v minisign >/dev/null 2>&1 || error "minisign is required but not found (brew install minisign)"
[ -f "$SECRET_KEY" ] || error "Signing key not found: $SECRET_KEY (set MINISIGN_SECRET_KEY or pass -s)"

# The release must exist and still be a draft — signing a live release would
# leave a verification-window race.
info "Checking release $TAG..."
if ! gh release view "$TAG" >/dev/null 2>&1; then
    error "Release $TAG not found. Push the tag / run the release workflow first."
fi
IS_DRAFT="$(gh release view "$TAG" --json isDraft --jq .isDraft 2>/dev/null || echo "unknown")"
if [ "$IS_DRAFT" = "false" ]; then
    error "Release $TAG is already published. Refusing to re-sign a live release."
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

info "Downloading checksums.txt from $TAG..."
gh release download "$TAG" -p checksums.txt -D "$WORK_DIR" --clobber \
    || error "Failed to download checksums.txt from $TAG"

info "Signing checksums.txt (you will be prompted for the key passphrase)..."
minisign -S -s "$SECRET_KEY" \
    -m "$WORK_DIR/checksums.txt" \
    -t "zcli $TAG — signed release checksums" \
    || error "Signing failed"
success "Signature created"

# Self-verify against the committed public key before publishing anything —
# catches signing with the wrong key.
if [ -f "$PUBKEY_FILE" ]; then
    info "Verifying signature against $PUBKEY_FILE..."
    minisign -Vm "$WORK_DIR/checksums.txt" -p "$PUBKEY_FILE" >/dev/null \
        || error "Self-verification failed — signed with the wrong key?"
    success "Signature verifies against the pinned public key"
else
    info "No $PUBKEY_FILE found — skipping self-verify (add it during the keygen ceremony)"
fi

info "Uploading checksums.txt.minisig to $TAG..."
gh release upload "$TAG" "$WORK_DIR/checksums.txt.minisig" --clobber \
    || error "Failed to upload signature"
success "Signature uploaded"

info "Publishing release $TAG..."
gh release edit "$TAG" --draft=false \
    || error "Failed to publish release"

echo ""
success "Release $TAG signed and published."
echo ""
echo "Anyone can now verify it:"
echo "  gh release download $TAG -p 'checksums.txt*'"
echo "  minisign -Vm checksums.txt -p docs/zcli-minisign.pub"
echo ""
