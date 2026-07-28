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

# True when the trusted comment in $1 (a .minisig file) names $2 as a whole
# whitespace-delimited token.
#
# Token-exact, not substring, so `zcli-v0.2` cannot satisfy `zcli-v0.20.0` nor
# the reverse. Behaviorally identical to install.sh's verify_signature,
# install.ps1's Test-Signature, and verifyTrustedComment in
# packages/core/src/plugins/zcli_github_upgrade/minisign.zig. The four copies
# exist only because sh, PowerShell and Zig share no runtime — keep them in step.
#
# Only meaningful AFTER `minisign -V` has succeeded on the same file: that is
# what authenticates line 3 via minisign's global signature. Reading the comment
# unverified would prove nothing.
#
# Written in POSIX sh (not bash) so scripts/test-install-signature.sh can extract
# this function by name and hold it to the same case matrix as the installers.
# Keep the `name() {` ... `}` shape at column 0 or that extraction breaks loudly.
trusted_comment_binds_tag() {
    _sig_file="$1"
    _expected_tag="$2"

    [ -n "$_expected_tag" ] || return 1

    _comment_line=$(sed -n '3p' "$_sig_file" | tr -d '\r')
    case "$_comment_line" in
        "trusted comment: "*) ;;
        *) return 1 ;;
    esac
    _trusted_comment="${_comment_line#"trusted comment: "}"

    # `set -f` disables globbing so a `*` in the comment cannot expand against
    # the working directory during word splitting.
    set -f
    _bound=1
    for _token in ${_trusted_comment}; do
        if [ "$_token" = "$_expected_tag" ]; then
            _bound=0
            break
        fi
    done
    set +f
    return $_bound
}

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
# catches signing with the wrong key. Unconditional: keygen is long past, so a
# missing pubkey file means a broken checkout, not a first run. Skipping the
# self-verify would be fail-open in the one ceremony still able to fix a bad
# signature — after publish, every consumer fails closed instead.
[ -f "$PUBKEY_FILE" ] || error "Pinned public key not found: $PUBKEY_FILE (it is committed at docs/zcli-minisign.pub — broken checkout?)"

info "Verifying signature against $PUBKEY_FILE..."
minisign -Vm "$WORK_DIR/checksums.txt" -p "$PUBKEY_FILE" >/dev/null \
    || error "Self-verification failed — signed with the wrong key?"
success "Signature verifies against the pinned public key"

# `minisign -V` authenticates the trusted comment but asserts nothing about its
# contents, so check that the comment we just wrote actually names this tag.
# Both installers and the in-binary upgrade path now REQUIRE that binding, so a
# typo'd `-t` argument above would not surface until every consumer's install
# fails closed — after publish, with the artifacts already signed. Catch it here,
# while the release is still a draft and re-signing costs nothing.
if ! trusted_comment_binds_tag "$WORK_DIR/checksums.txt.minisig" "$TAG"; then
    echo "  trusted comment: $(sed -n '3p' "$WORK_DIR/checksums.txt.minisig")" >&2
    error "Trusted comment does not name $TAG as a whole token — refusing to publish a release every consumer would reject"
fi
success "Trusted comment binds $TAG"

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
