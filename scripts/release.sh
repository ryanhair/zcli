#!/usr/bin/env bash
set -euo pipefail

# Cut a zcli release, end to end (see docs/RELEASE-SIGNING.md, ADR-0033).
#
#   scripts/release.sh 0.24.0
#
# One command. One approval, surfaced when the gate opens. Returns only when
# zcli.sh actually serves the new version.
#
# WHY THIS IS A LOCAL SCRIPT AND NOT A BUTTON
#
# ADR-0023 keeps the minisign secret key in a password manager, deliberately
# nowhere near CI. That makes one step of every release irreducibly local — so
# the laptop is the only participant present for the whole transaction, and it
# is therefore the only thing that can own it. The previous design had CI
# orchestrate and hand off to a human in the middle; nothing spanned the whole
# sequence, so nothing could tell that the docs deploy had silently not
# happened. It did not, three releases running.
#
# RESUMABILITY IS THE DESIGN, NOT A FEATURE
#
# Every phase decides what to do by looking at observable remote state — does
# the tag exist, is there a draft, is it published, what does the site serve —
# and never at local bookkeeping. So this script is safe to re-run at any point
# and converges on a finished release. If your laptop dies during signing, run
# it again with the same version. That property is what makes a sequence of
# non-atomic steps behave atomically in practice.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

error()   { echo -e "${RED}✗ $1${NC}" >&2; exit 1; }
success() { echo -e "${GREEN}✓ $1${NC}"; }
info()    { echo -e "${YELLOW}→ $1${NC}"; }
phase()   { echo; echo -e "${BLUE}${BOLD}══ $1${NC}"; }
warn()    { echo -e "${YELLOW}! $1${NC}" >&2; }

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

SECRET_KEY="${MINISIGN_SECRET_KEY:-$HOME/.minisign/minisign.key}"
PUBKEY_FILE="$REPO_ROOT/docs/zcli-minisign.pub"
SITE="https://zcli.sh"
SIGN_ONLY=false
VERIFY_ONLY=false
ASSUME_YES=false

usage() {
    cat <<'USAGE'
Usage: scripts/release.sh [options] <version>

Cuts a release end to end: preflight, dispatch the Release workflow, wait for
the one approval, sign the draft, wait for the docs deploy, and verify zcli.sh
actually serves it. Safe to re-run — it resumes from whatever is already done.

Options:
  -s <file>   minisign secret key (default: $MINISIGN_SECRET_KEY or
              ~/.minisign/minisign.key)
  --sign-only Sign and publish an existing draft, then stop. Recovery path for
              when the orchestrated run died after the draft was created.
  --verify-only
              Only check that an already-published release is complete: site,
              installer, assets, signature, library release. Read-only — makes
              no changes and triggers nothing. Use it to answer "did that
              release actually land?" for any past version.
  -y          Skip the "does the CHANGELOG cover this?" confirmation.
  -h          This help.

Examples:
  scripts/release.sh 0.24.0
  scripts/release.sh --sign-only 0.24.0
  scripts/release.sh --verify-only 0.23.0
  scripts/release.sh -s ./key.sec 0.24.0
USAGE
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        -s) SECRET_KEY="${2:-}"; shift 2 ;;
        --sign-only) SIGN_ONLY=true; shift ;;
        --verify-only) VERIFY_ONLY=true; shift ;;
        -y) ASSUME_YES=true; shift ;;
        -h|--help) usage ;;
        -*) error "unknown option: $1" ;;
        *) break ;;
    esac
done

[ $# -eq 1 ] || usage
VERSION="${1#zcli-v}"
VERSION="${VERSION#v}"
TAG="zcli-v$VERSION"
LIB_TAG="v$VERSION"

cd "$REPO_ROOT"

# Scratch space for downloaded checksums, signatures and fetched pages. Created
# up front rather than inside the signing phase: the verify phase uses it too,
# and reaches it on the resume path where signing is skipped.
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ── Phase 0: preflight ──────────────────────────────────────────────────────
# Everything here is cheap and local, and runs before anything exists remotely.
# A release that is going to fail should fail now, not 20 minutes in with a tag
# already cut.

phase "Preflight"

echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || error "version must be semver like 0.24.0 (got '$VERSION')"

for tool in gh git curl minisign; do
    command -v "$tool" >/dev/null 2>&1 || error "$tool is required but not found"
done
gh auth status >/dev/null 2>&1 || error "gh is not authenticated — run 'gh auth login'"
[ -f "$PUBKEY_FILE" ] || error "pinned public key not found: $PUBKEY_FILE — broken checkout?"
# --verify-only only ever verifies against the PUBLIC key, so do not demand the
# secret — that would stop anyone but the maintainer from auditing a release.
if [ "$VERIFY_ONLY" = false ]; then
    [ -f "$SECRET_KEY" ] || error "signing key not found: $SECRET_KEY (set MINISIGN_SECRET_KEY or pass -s)"
fi
success "tools, credentials and signing key present"

# Discover what already exists. Every later phase branches on these, which is
# what makes re-running safe.
RELEASE_STATE=none   # none | draft | published
if gh release view "$TAG" >/dev/null 2>&1; then
    if [ "$(gh release view "$TAG" --json isDraft --jq .isDraft)" = "true" ]; then
        RELEASE_STATE=draft
    else
        RELEASE_STATE=published
    fi
fi
info "release $TAG: $RELEASE_STATE"

# Branch/tree checks only matter when we are about to dispatch a build from
# this tree's main. Once the draft exists, the code is already built and what
# is in the working copy is irrelevant to the rest of the run.
if [ "$RELEASE_STATE" = none ] && [ "$SIGN_ONLY" = false ] && [ "$VERIFY_ONLY" = false ]; then
    branch="$(git rev-parse --abbrev-ref HEAD)"
    [ "$branch" = main ] || error "release from main, not '$branch' (the workflow builds main)"
    [ -z "$(git status --porcelain)" ] || error "working tree is dirty — commit or stash first"

    git fetch --quiet origin main
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
        || error "local main differs from origin/main — pull (or push) before releasing"

    git fetch --quiet --tags origin
    git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
        && error "tag $TAG already exists but no release does — resolve by hand before re-running"
    success "on main, clean, in sync with origin"

    # The CHANGELOG's Unreleased section becomes the release notes: CI renames
    # the heading in the same commit it tags, so the two cannot disagree. What
    # it cannot check is whether that section is COMPLETE. Show the commits it
    # is meant to describe and let a human decide — the right place for a
    # judgment call, and cheaper than a CI rule that nags on every PR.
    grep -q '^## Unreleased$' CHANGELOG.md \
        || error "CHANGELOG.md has no '## Unreleased' section to promote"
    unreleased_body="$(awk '/^## Unreleased$/{f=1;next} /^## /{f=0} f' CHANGELOG.md | grep -c '[^[:space:]]' || true)"
    [ "$unreleased_body" -gt 0 ] || error "CHANGELOG.md's '## Unreleased' section is empty"

    last_tag="$(git describe --tags --abbrev=0 --match 'zcli-v*' 2>/dev/null || echo '')"
    if [ "$ASSUME_YES" = false ] && [ -n "$last_tag" ]; then
        echo
        echo "Commits since $last_tag:"
        git log --oneline "$last_tag..HEAD" | sed 's/^/    /'
        echo
        echo "## Unreleased currently says:"
        awk '/^## Unreleased$/{f=1;next} /^## /{f=0} f' CHANGELOG.md | sed 's/^/    /' | head -40
        echo
        printf "Does the CHANGELOG cover everything above? [y/N] "
        read -r reply
        case "$reply" in [Yy]*) ;; *) error "aborted — update CHANGELOG.md and re-run" ;; esac
    fi
fi

# ── helpers ─────────────────────────────────────────────────────────────────

# Poll a workflow run to completion, announcing the approval gate once when it
# opens. GitHub reports `waiting` while a job sits at an environment gate.
wait_for_run() {
    _run_id="$1"
    _label="$2"
    _url="$(gh run view "$_run_id" --json url --jq .url)"
    _announced=false
    _last=""
    info "$_label: $_url"
    while :; do
        _status="$(gh run view "$_run_id" --json status --jq .status 2>/dev/null || echo unknown)"
        if [ "$_status" != "$_last" ]; then
            echo "    status: $_status"
            _last="$_status"
        fi
        case "$_status" in
            completed)
                _conclusion="$(gh run view "$_run_id" --json conclusion --jq .conclusion)"
                [ "$_conclusion" = success ] || error "$_label finished '$_conclusion' — see $_url"
                success "$_label succeeded"
                return 0
                ;;
            waiting)
                if [ "$_announced" = false ]; then
                    _announced=true
                    printf '\a'  # the one moment this needs a human
                    echo
                    echo -e "${BOLD}    ▶ APPROVAL NEEDED — approve the 'release' environment:${NC}"
                    echo -e "${BOLD}      $_url${NC}"
                    echo
                fi
                ;;
        esac
        sleep 10
    done
}

# ── Phase 1: build, gate, tag ───────────────────────────────────────────────

if [ "$VERIFY_ONLY" = true ]; then
    [ "$RELEASE_STATE" = published ] || error "--verify-only needs a published release; $TAG is '$RELEASE_STATE'"
elif [ "$SIGN_ONLY" = true ]; then
    [ "$RELEASE_STATE" = draft ] || error "--sign-only needs an existing draft; $TAG is '$RELEASE_STATE'"
elif [ "$RELEASE_STATE" = none ]; then
    phase "Dispatching the Release workflow"
    # Timestamp before dispatching so we can identify OUR run. 60s of slack
    # absorbs clock skew between here and GitHub.
    since=$(( $(date -u +%s) - 60 ))
    gh workflow run release.yml -f version="$VERSION"
    info "dispatched release.yml with version=$VERSION"

    run_id=""
    for _ in $(seq 1 40); do
        sleep 3
        run_id="$(gh run list --workflow release.yml --event workflow_dispatch --limit 10 \
            --json databaseId,createdAt \
            --jq "[.[] | select((.createdAt | fromdateiso8601) >= $since)] | sort_by(.createdAt) | last | .databaseId // empty" \
            2>/dev/null || echo '')"
        [ -n "$run_id" ] && break
    done
    [ -n "$run_id" ] || error "dispatched, but could not find the run — check 'gh run list --workflow release.yml'"

    wait_for_run "$run_id" "Release workflow"
else
    info "release already exists ($RELEASE_STATE) — skipping the build"
fi

# ── Phase 2: sign and publish ───────────────────────────────────────────────
# This is ADR-0023's ceremony, inlined. It used to be a separate script the
# operator had to remember to run; forgetting it leaves a draft nobody can
# install, which is a silent failure of exactly the kind this rewrite exists to
# remove.

if [ "$RELEASE_STATE" != published ] && [ "$VERIFY_ONLY" = false ]; then
    phase "Signing $TAG"

    # Re-read: phase 1 may have just created it.
    gh release view "$TAG" >/dev/null 2>&1 || error "release $TAG not found after the workflow ran"
    [ "$(gh release view "$TAG" --json isDraft --jq .isDraft)" = "true" ] \
        || error "release $TAG is already published — refusing to re-sign a live release"

    asset_count="$(gh release view "$TAG" --json assets --jq '[.assets[] | select(.name | startswith("zcli-"))] | length')"
    [ "$asset_count" -eq 6 ] || error "expected 6 binaries on $TAG, found $asset_count — do not sign a partial release"
    success "draft carries all 6 binaries"

    info "downloading checksums.txt..."
    gh release download "$TAG" -p checksums.txt -D "$WORK_DIR" --clobber \
        || error "failed to download checksums.txt from $TAG"

    info "signing (you will be prompted for the key passphrase)..."
    minisign -S -s "$SECRET_KEY" \
        -m "$WORK_DIR/checksums.txt" \
        -t "zcli $TAG — signed release checksums" \
        || error "signing failed"
    success "signature created"

    # Self-verify against the committed public key before publishing anything —
    # catches signing with the wrong key. Skipping it would be fail-open in the
    # one ceremony still able to fix a bad signature: after publish, every
    # consumer fails closed instead.
    info "verifying against $PUBKEY_FILE..."
    minisign -Vm "$WORK_DIR/checksums.txt" -p "$PUBKEY_FILE" >/dev/null \
        || error "self-verification failed — signed with the wrong key?"
    success "signature verifies against the pinned public key"

    # `minisign -V` authenticates the trusted comment but asserts nothing about
    # its contents. Both installers and the in-binary upgrade path REQUIRE the
    # comment to name this tag, so a typo'd -t would not surface until every
    # consumer's install failed closed. Catch it while re-signing is free.
    if ! trusted_comment_binds_tag "$WORK_DIR/checksums.txt.minisig" "$TAG"; then
        echo "  trusted comment: $(sed -n '3p' "$WORK_DIR/checksums.txt.minisig")" >&2
        error "trusted comment does not name $TAG as a whole token — refusing to publish a release every consumer would reject"
    fi
    success "trusted comment binds $TAG"

    gh release upload "$TAG" "$WORK_DIR/checksums.txt.minisig" --clobber \
        || error "failed to upload signature"
    gh release edit "$TAG" --draft=false \
        || error "failed to publish release"
    success "$TAG signed and published"
    JUST_PUBLISHED=true
else
    info "$TAG already published — skipping the signing ceremony"
    JUST_PUBLISHED=false
fi

if [ "$SIGN_ONLY" = true ]; then
    echo
    success "Signed and published $TAG (--sign-only; docs deploy not awaited)."
    exit 0
fi

# ── Phase 3: the docs deploy ────────────────────────────────────────────────
# Publishing fires deploy-docs.yml via `release: published`. That workflow
# verifies the live site itself; this waits for its verdict rather than
# assuming it. Three releases shipped without anyone noticing this step had
# not run.

if [ "$VERIFY_ONLY" = false ]; then
phase "Waiting for the docs deploy"

deploy_run=""
if [ "$JUST_PUBLISHED" = true ]; then
    for _ in $(seq 1 40); do
        sleep 5
        deploy_run="$(gh run list --workflow deploy-docs.yml --limit 10 \
            --json databaseId,headBranch,event \
            --jq "[.[] | select(.event == \"release\" and .headBranch == \"$TAG\")] | first | .databaseId // empty" \
            2>/dev/null || echo '')"
        [ -n "$deploy_run" ] && break
    done
fi

if [ -n "$deploy_run" ]; then
    wait_for_run "$deploy_run" "Docs deploy"
else
    # Either already published before this run, or the release event did not
    # produce a deploy. Dispatch one from main — the documented manual override.
    # After a successful release main IS the released commit, so this builds the
    # right tree.
    warn "no release-triggered deploy found; dispatching one from main"
    since=$(( $(date -u +%s) - 60 ))
    gh workflow run deploy-docs.yml --ref main
    for _ in $(seq 1 40); do
        sleep 3
        deploy_run="$(gh run list --workflow deploy-docs.yml --event workflow_dispatch --limit 10 \
            --json databaseId,createdAt \
            --jq "[.[] | select((.createdAt | fromdateiso8601) >= $since)] | sort_by(.createdAt) | last | .databaseId // empty" \
            2>/dev/null || echo '')"
        [ -n "$deploy_run" ] && break
    done
    [ -n "$deploy_run" ] || error "could not find the dispatched docs deploy run"
    wait_for_run "$deploy_run" "Docs deploy"
fi
fi

# ── Phase 4: verify the end state ───────────────────────────────────────────
# Independent of every "success" reported above. A release is done when a user
# can install it and the site describes it — so check exactly that, from
# outside, the way a user would.

phase "Verifying the released state"

fail=0
check() { if [ "$1" = true ]; then success "$2"; else echo -e "${RED}✗ $2${NC}" >&2; fail=1; fi; }

# The site serves this version.
curl -fsS --max-time 30 -o "$WORK_DIR/home.html" "$SITE/" 2>/dev/null || true
if grep -qF "$VERSION" "$WORK_DIR/home.html" 2>/dev/null; then
    check true "$SITE serves $VERSION"
else
    check false "$SITE does NOT serve $VERSION"
fi

# install.sh at the site root matches the RELEASED tag's copy — the curl|sh
# trust root, so what the site hands out must be the reviewed file from the
# commit that was released. Compared against the tag rather than the working
# tree on purpose: the local checkout is a commit behind after a release (CI
# creates the bump commit), and may carry unrelated edits, either of which would
# make a working-tree comparison lie in both directions.
curl -fsS --max-time 30 -o "$WORK_DIR/live-install.sh" "$SITE/install.sh" 2>/dev/null || true
curl -fsSL --max-time 30 -o "$WORK_DIR/tagged-install.sh" \
    "https://raw.githubusercontent.com/ryanhair/zcli/$TAG/install.sh" 2>/dev/null || true
if [ -s "$WORK_DIR/tagged-install.sh" ] && cmp -s "$WORK_DIR/live-install.sh" "$WORK_DIR/tagged-install.sh"; then
    check true "$SITE/install.sh is byte-identical to $TAG's"
else
    check false "$SITE/install.sh DIFFERS from $TAG's"
fi

# The CLI release is published, complete, and its signature verifies the way a
# consumer's would.
if [ "$(gh release view "$TAG" --json isDraft --jq .isDraft 2>/dev/null || echo true)" = "false" ]; then
    check true "$TAG is published"
else
    check false "$TAG is NOT published"
fi

n="$(gh release view "$TAG" --json assets --jq '.assets | length' 2>/dev/null || echo 0)"
if [ "$n" -eq 8 ]; then
    check true "$TAG carries all 8 assets (6 binaries + checksums.txt + .minisig)"
else
    check false "$TAG carries $n assets, expected 8"
fi

rm -f "$WORK_DIR/checksums.txt" "$WORK_DIR/checksums.txt.minisig"
if gh release download "$TAG" -p 'checksums.txt*' -D "$WORK_DIR" --clobber >/dev/null 2>&1 \
   && minisign -Vm "$WORK_DIR/checksums.txt" -p "$PUBKEY_FILE" >/dev/null 2>&1 \
   && trusted_comment_binds_tag "$WORK_DIR/checksums.txt.minisig" "$TAG"; then
    check true "published signature verifies against the pinned key and binds $TAG"
else
    check false "published signature does NOT verify (or does not bind $TAG)"
fi

# The library release, which consumers reference from build.zig.zon.
if gh release view "$LIB_TAG" >/dev/null 2>&1; then
    check true "library release $LIB_TAG exists"
else
    check false "library release $LIB_TAG is missing"
fi

echo
if [ "$fail" -ne 0 ]; then
    error "release $VERSION is INCOMPLETE — see the failures above. Re-running this script is safe and resumes from here."
fi

echo -e "${GREEN}${BOLD}✓ Release $VERSION is live.${NC}"
echo
echo "  CLI:     https://github.com/ryanhair/zcli/releases/tag/$TAG"
echo "  Library: https://github.com/ryanhair/zcli/releases/tag/$LIB_TAG"
echo "  Site:    $SITE"
echo
