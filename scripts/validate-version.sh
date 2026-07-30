#!/bin/sh
# One source of truth for release-version consistency. CI, the release build,
# and the post-release verifier all call this file; keep policy out of YAML.
set -eu

usage() {
    cat >&2 <<'EOF'
Usage: scripts/validate-version.sh [--root DIR] [--expected X.Y.Z]
                                   [--tag vX.Y.Z|zcli-vX.Y.Z] [--cli PATH]

Checks the umbrella manifests, README, ROADMAP, newest changelog release
metadata, an optional requested/tag version, and an optional built zcli binary.
EOF
    exit 2
}

die() {
    printf 'validate-version: ERROR: %s\n' "$*" >&2
    exit 1
}

ROOT=.
EXPECTED=
TAG=
CLI=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --root) [ "$#" -ge 2 ] || usage; ROOT=$2; shift 2 ;;
        --expected) [ "$#" -ge 2 ] || usage; EXPECTED=$2; shift 2 ;;
        --tag) [ "$#" -ge 2 ] || usage; TAG=$2; shift 2 ;;
        --cli) [ "$#" -ge 2 ] || usage; CLI=$2; shift 2 ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done

is_semver() {
    printf '%s\n' "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'
}

read_single() {
    label=$1
    values=$2
    count=$(printf '%s\n' "$values" | grep -c . || true)
    [ "$count" -eq 1 ] || die "$label: expected exactly one version, found $count"
    printf '%s\n' "$values"
}

zon_version() {
    file=$1
    [ -f "$file" ] || die "missing $file"
    values=$(sed -nE 's/^[[:space:]]*\.version = "([0-9]+\.[0-9]+\.[0-9]+)",?.*/\1/p' "$file")
    read_single "$file .version" "$values"
}

archive_version() {
    file=$1
    [ -f "$file" ] || die "missing $file"
    values=$(sed -nE 's|.*archive/refs/tags/v([0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz.*|\1|p' "$file")
    read_single "$file archive tag" "$values"
}

root_version=$(zon_version "$ROOT/build.zig.zon")
cli_manifest_version=$(zon_version "$ROOT/projects/zcli/build.zig.zon")
core_version=$(zon_version "$ROOT/packages/core/build.zig.zon")
readme_version=$(archive_version "$ROOT/README.md")
roadmap_archive_version=$(archive_version "$ROOT/ROADMAP.md")

roadmap_current_values=$(sed -nE 's/^Current release: \*\*v([0-9]+\.[0-9]+\.[0-9]+)\*\*.*/\1/p' "$ROOT/ROADMAP.md")
roadmap_current_version=$(read_single "$ROOT/ROADMAP.md current release" "$roadmap_current_values")

# Require release metadata, not merely a version mention. Inspect the first
# level-two heading after an optional Unreleased section; never scan forward to
# an older well-formed release and accidentally forgive malformed newest data.
changelog_headings=$(sed -n '/^## /p' "$ROOT/CHANGELOG.md")
newest_release_heading=$(printf '%s\n' "$changelog_headings" | sed -n '1p')
if [ "$newest_release_heading" = "## Unreleased" ]; then
    newest_release_heading=$(printf '%s\n' "$changelog_headings" | sed -n '2p')
fi
changelog_version=$(printf '%s\n' "$newest_release_heading" \
    | sed -nE 's/^## v([0-9]+\.[0-9]+\.[0-9]+) — [0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]*$/\1/p')
[ -n "$changelog_version" ] \
    || die "$ROOT/CHANGELOG.md: newest release heading must be '## vX.Y.Z — YYYY-MM-DD' (got '$newest_release_heading')"

compare() {
    label=$1
    actual=$2
    [ "$actual" = "$root_version" ] \
        || die "version drift: $label=$actual, root build.zig.zon=$root_version"
}

compare "projects/zcli/build.zig.zon" "$cli_manifest_version"
compare "packages/core/build.zig.zon" "$core_version"
compare "README.md archive tag" "$readme_version"
compare "ROADMAP.md current release" "$roadmap_current_version"
compare "ROADMAP.md archive tag" "$roadmap_archive_version"
compare "CHANGELOG.md newest release" "$changelog_version"

if [ -n "$EXPECTED" ]; then
    is_semver "$EXPECTED" || die "requested version must be X.Y.Z (got '$EXPECTED')"
    compare "requested version" "$EXPECTED"
fi

if [ -n "$TAG" ]; then
    case "$TAG" in
        zcli-v*) tag_version=${TAG#zcli-v} ;;
        v*) tag_version=${TAG#v} ;;
        *) die "release tag must be vX.Y.Z or zcli-vX.Y.Z (got '$TAG')" ;;
    esac
    is_semver "$tag_version" || die "release tag must be vX.Y.Z or zcli-vX.Y.Z (got '$TAG')"
    compare "release tag $TAG" "$tag_version"
fi

if [ -n "$CLI" ]; then
    [ -x "$CLI" ] || die "built CLI is not executable: $CLI"
    cli_output=$("$CLI" --version 2>&1) \
        || die "built CLI failed to run: $CLI --version"
    cli_output=$(printf '%s' "$cli_output" | tr -d '\r')
    cli_version=$(printf '%s\n' "$cli_output" | sed -nE 's/^zcli v([0-9]+\.[0-9]+\.[0-9]+)$/\1/p')
    [ -n "$cli_version" ] \
        || die "built CLI --version output has unexpected shape: '$cli_output'"
    compare "built CLI --version" "$cli_version"
fi

printf 'validate-version: %s is consistent' "$root_version"
[ -n "$TAG" ] && printf ' with %s' "$TAG"
[ -n "$CLI" ] && printf ' and %s --version' "$CLI"
printf '\n'
