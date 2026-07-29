#!/bin/sh
# Deterministic public-seam tests for scripts/validate-version.sh.
set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
VALIDATOR="$REPO_ROOT/scripts/validate-version.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

make_fixture() {
    root="$1"
    mkdir -p "$root/projects/zcli" "$root/packages/core"
    for zon in \
        "$root/build.zig.zon" \
        "$root/projects/zcli/build.zig.zon" \
        "$root/packages/core/build.zig.zon"
    do
        printf '.{\n    .version = "1.2.3",\n}\n' > "$zon"
    done
    printf '%s\n' \
        'zig fetch --save https://github.com/ryanhair/zcli/archive/refs/tags/v1.2.3.tar.gz' \
        > "$root/README.md"
    printf '%s\n' \
        'Current release: **v1.2.3**.' \
        'zig fetch --save https://github.com/ryanhair/zcli/archive/refs/tags/v1.2.3.tar.gz' \
        > "$root/ROADMAP.md"
    printf '%s\n' \
        '# Changelog' \
        '' \
        '## Unreleased' \
        '' \
        '## v1.2.3 — 2026-07-29' \
        > "$root/CHANGELOG.md"
    cat > "$root/zcli" <<'EOF'
#!/bin/sh
printf 'zcli v1.2.3\n'
EOF
    chmod +x "$root/zcli"
}

fixture="$WORK/valid"
make_fixture "$fixture"

"$VALIDATOR" \
    --root "$fixture" \
    --expected 1.2.3 \
    --tag zcli-v1.2.3 \
    --cli "$fixture/zcli"

printf 'PASS: valid release metadata and built CLI agree\n'

expect_reject() {
    label=$1
    needle=$2
    shift 2
    if output=$("$VALIDATOR" "$@" 2>&1); then
        printf 'FAIL: %s — validator accepted invalid fixture\n' "$label" >&2
        exit 1
    fi
    if ! printf '%s\n' "$output" | grep -qF "$needle"; then
        printf 'FAIL: %s — expected error containing %s, got:\n%s\n' \
            "$label" "$needle" "$output" >&2
        exit 1
    fi
    printf 'PASS: %s\n' "$label"
}

case_root="$WORK/cli-manifest"
make_fixture "$case_root"
printf '.{\n    .version = "1.2.4",\n}\n' > "$case_root/projects/zcli/build.zig.zon"
expect_reject "CLI manifest drift is rejected" \
    "projects/zcli/build.zig.zon=1.2.4" --root "$case_root"

case_root="$WORK/core-manifest"
make_fixture "$case_root"
printf '.{\n    .version = "1.2.4",\n}\n' > "$case_root/packages/core/build.zig.zon"
expect_reject "core manifest drift is rejected" \
    "packages/core/build.zig.zon=1.2.4" --root "$case_root"

case_root="$WORK/readme"
make_fixture "$case_root"
printf '%s\n' \
    'zig fetch --save https://github.com/ryanhair/zcli/archive/refs/tags/v1.2.4.tar.gz' \
    > "$case_root/README.md"
expect_reject "README archive drift is rejected" \
    "README.md archive tag=1.2.4" --root "$case_root"

case_root="$WORK/roadmap-current"
make_fixture "$case_root"
printf '%s\n' \
    'Current release: **v1.2.4**.' \
    'zig fetch --save https://github.com/ryanhair/zcli/archive/refs/tags/v1.2.3.tar.gz' \
    > "$case_root/ROADMAP.md"
expect_reject "ROADMAP current-release drift is rejected" \
    "ROADMAP.md current release=1.2.4" --root "$case_root"

case_root="$WORK/roadmap-archive"
make_fixture "$case_root"
printf '%s\n' \
    'Current release: **v1.2.3**.' \
    'zig fetch --save https://github.com/ryanhair/zcli/archive/refs/tags/v1.2.4.tar.gz' \
    > "$case_root/ROADMAP.md"
expect_reject "ROADMAP archive drift is rejected" \
    "ROADMAP.md archive tag=1.2.4" --root "$case_root"

case_root="$WORK/changelog"
make_fixture "$case_root"
printf '%s\n' '# Changelog' '' '## v1.2.4 — 2026-07-29' > "$case_root/CHANGELOG.md"
expect_reject "changelog release drift is rejected" \
    "CHANGELOG.md newest release=1.2.4" --root "$case_root"

case_root="$WORK/changelog-date"
make_fixture "$case_root"
printf '%s\n' '# Changelog' '' '## v1.2.3 (not dated)' > "$case_root/CHANGELOG.md"
expect_reject "changelog release metadata requires an ISO date" \
    "newest release heading must be" --root "$case_root"

case_root="$WORK/changelog-newest"
make_fixture "$case_root"
printf '%s\n' \
    '# Changelog' \
    '' \
    '## Unreleased' \
    '' \
    '## v1.2.4 (malformed newest release)' \
    '' \
    '## v1.2.3 — 2026-07-29' \
    > "$case_root/CHANGELOG.md"
expect_reject "a malformed newest release cannot fall through to an older heading" \
    "newest release heading must be" --root "$case_root"

case_root="$WORK/requested"
make_fixture "$case_root"
expect_reject "requested release version drift is rejected" \
    "requested version=1.2.4" --root "$case_root" --expected 1.2.4

case_root="$WORK/tag"
make_fixture "$case_root"
expect_reject "release tag drift is rejected" \
    "release tag zcli-v1.2.4=1.2.4" --root "$case_root" --tag zcli-v1.2.4

case_root="$WORK/cli"
make_fixture "$case_root"
cat > "$case_root/zcli" <<'EOF'
#!/bin/sh
printf 'zcli v1.2.4\n'
EOF
chmod +x "$case_root/zcli"
expect_reject "built CLI version drift is rejected" \
    "built CLI --version=1.2.4" --root "$case_root" --cli "$case_root/zcli"
