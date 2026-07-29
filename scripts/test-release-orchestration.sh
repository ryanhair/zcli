#!/usr/bin/env bash
# Deterministic tests for release.sh's remote-state orchestration.
# shellcheck disable=SC2034,SC2329 # globals/functions are consumed by sourced release.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ZCLI_RELEASE_SOURCE_ONLY=true
# shellcheck source=scripts/release.sh
source "$REPO_ROOT/scripts/release.sh"
unset ZCLI_RELEASE_SOURCE_ONLY

pass_count=0
fail_count=0

pass() {
    printf '  PASS  %s\n' "$1"
    pass_count=$((pass_count + 1))
}

fail() {
    printf '::error::%s\n' "$1" >&2
    fail_count=$((fail_count + 1))
}

assert_contains() {
    _label="$1"
    _haystack="$2"
    _needle="$3"
    if [[ "$_haystack" == *"$_needle"* ]]; then
        pass "$_label"
    else
        fail "$_label — expected to contain '$_needle', got: $_haystack"
    fi
}

assert_not_contains() {
    _label="$1"
    _haystack="$2"
    _needle="$3"
    if [[ "$_haystack" == *"$_needle"* ]]; then
        fail "$_label — unexpectedly contained '$_needle': $_haystack"
    else
        pass "$_label"
    fi
}

assert_equals() {
    _label="$1"
    _actual="$2"
    _expected="$3"
    if [ "$_actual" = "$_expected" ]; then
        pass "$_label"
    else
        fail "$_label — expected '$_expected', got: $_actual"
    fi
}

REPOSITORY=example/zcli
TAG=zcli-v1.2.3
VERSION=1.2.3
SITE=https://zcli.example
WORK_DIR="$WORK/release"
DOCS_PROBE_ATTEMPTS=1
DOCS_PROBE_INTERVAL_SECONDS=0
mkdir -p "$WORK_DIR"

GH_LOG="$WORK/gh.log"
WAIT_LOG="$WORK/wait.log"
GH_MODE=orchestration
GH_DEPLOY_RUN_ID=
GH_DISPATCH_RUN_ID=
DOCS_FIXTURE=complete
WAIT_CONCLUSION=success

gh() {
    printf '%s\n' "$*" >> "$GH_LOG"

    if [ "$GH_MODE" = waiter ]; then
        if [[ "$*" == *"--json url"* ]]; then
            printf 'https://example.invalid/actions/runs/77\n'
            return 0
        fi
        if [[ "$*" == *"--json status"* ]]; then
            case "$WAIT_SCENARIO" in
                api-error) return 1 ;;
                mystery) printf 'mystery\n' ;;
                *) printf '%s\n' "$WAIT_SCENARIO" ;;
            esac
            return 0
        fi
        if [[ "$*" == *"--json conclusion"* ]]; then
            printf '%s\n' "$WAIT_CONCLUSION"
            return 0
        fi
    fi

    case "$1 $2" in
        "api repos/example/zcli/commits/zcli-v1.2.3")
            printf '0123456789abcdef0123456789abcdef01234567\n'
            ;;
        "api --method")
            if [ "${3:-}" != POST ] \
               || [[ " $* " != *" -F return_run_details=true "* ]] \
               || [[ " $* " != *" --jq .workflow_run_id "* ]] \
               || [[ " $* " != *" -f ref="* ]]; then
                printf 'invalid workflow dispatch API call: %s\n' "$*" >&2
                return 1
            fi
            case "${4:-}" in
                repos/example/zcli/actions/workflows/release.yml/dispatches)
                    [[ " $* " == *" -f ref=main "* ]] \
                        && [[ " $* " == *" -f inputs[version]=1.2.3 "* ]] \
                        || { printf 'invalid release dispatch: %s\n' "$*" >&2; return 1; }
                    ;;
                repos/example/zcli/actions/workflows/deploy-docs.yml/dispatches)
                    [[ " $* " == *" -f ref=zcli-v1.2.3 "* ]] \
                        || { printf 'invalid docs dispatch: %s\n' "$*" >&2; return 1; }
                    ;;
                *)
                    printf 'unexpected workflow dispatch endpoint: %s\n' "${4:-}" >&2
                    return 1
                    ;;
            esac
            printf '%s\n' "$GH_DISPATCH_RUN_ID"
            ;;
        "run list")
            printf '%s\n' "$GH_DEPLOY_RUN_ID"
            ;;
        *)
            printf 'unexpected gh call: %s\n' "$*" >&2
            return 1
            ;;
    esac
}

curl() {
    _out=
    _previous=
    _url=
    for _arg in "$@"; do
        if [ "$_previous" = -o ]; then
            _out="$_arg"
        fi
        _previous="$_arg"
        _url="$_arg"
    done

    [ "$DOCS_FIXTURE" != read-failure ] || return 22
    case "$_url" in
        */zcli-v1.2.3/install.sh) printf 'tagged shell installer\n' > "$_out" ;;
        */zcli-v1.2.3/install.ps1) printf 'tagged powershell installer\n' > "$_out" ;;
        "$SITE/") printf 'current release %s\n' "$VERSION" > "$_out" ;;
        "$SITE/install.sh")
            if [ "$DOCS_FIXTURE" = complete ] \
               || { [ "$DOCS_FIXTURE" = settles ] && [[ "$_out" == *"attempt-2"* ]]; }; then
                printf 'tagged shell installer\n' > "$_out"
            else
                printf 'stale shell installer\n' > "$_out"
            fi
            ;;
        "$SITE/install.ps1")
            if [ "$DOCS_FIXTURE" = complete ] \
               || { [ "$DOCS_FIXTURE" = settles ] && [[ "$_out" == *"attempt-2"* ]]; }; then
                printf 'tagged powershell installer\n' > "$_out"
            else
                printf 'stale powershell installer\n' > "$_out"
            fi
            ;;
        *)
            printf 'unexpected curl URL: %s\n' "$_url" >&2
            return 22
            ;;
    esac
}

release_sleep() { :; }

WAIT_FOR_RUN_DEFINITION="$(declare -f wait_for_run)"
wait_for_run() {
    printf '%s %s\n' "$1" "$2" >> "$WAIT_LOG"
}

printf 'release.sh published-rerun docs decision\n'
JUST_PUBLISHED=false
: > "$GH_LOG"
: > "$WAIT_LOG"
DOCS_FIXTURE=complete
ensure_docs_deploy 0123456789abcdef0123456789abcdef01234567 >/dev/null
gh_log="$(cat "$GH_LOG")"
assert_not_contains "complete published rerun dispatches nothing" "$gh_log" "/dispatches"
assert_not_contains "complete published rerun waits on no workflow" "$(cat "$WAIT_LOG")" "Docs deploy"

: > "$GH_LOG"
: > "$WAIT_LOG"
DOCS_FIXTURE=settles
DOCS_PROBE_ATTEMPTS=2
ensure_docs_deploy 0123456789abcdef0123456789abcdef01234567 >/dev/null
assert_not_contains "published state that settles during the bounded probe dispatches nothing" \
    "$(cat "$GH_LOG")" "/dispatches"
assert_not_contains "settled propagation waits on no workflow" "$(cat "$WAIT_LOG")" "Docs deploy"
DOCS_PROBE_ATTEMPTS=1

: > "$GH_LOG"
: > "$WAIT_LOG"
DOCS_FIXTURE=incomplete
GH_DISPATCH_RUN_ID=9001
ensure_docs_deploy 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1
gh_log="$(cat "$GH_LOG")"
assert_contains "incomplete published state dispatches recovery" "$gh_log" "actions/workflows/deploy-docs.yml/dispatches"
assert_contains "recovery requests its exact run ID" "$gh_log" "return_run_details=true"
assert_contains "recovery dispatch uses immutable release tag" "$gh_log" "ref=zcli-v1.2.3"
assert_not_contains "recovery dispatch never uses newer main" "$gh_log" "ref=main"
assert_not_contains "recovery does not rediscover a possibly unrelated run" "$gh_log" "run list"
assert_contains "recovery waits for its returned run" "$(cat "$WAIT_LOG")" "9001 Docs deploy"

: > "$GH_LOG"
DOCS_FIXTURE=read-failure
if unknown_output="$(ensure_docs_deploy 0123456789abcdef0123456789abcdef01234567 2>&1)"; then
    fail "failed docs reads must not be treated as incomplete"
else
    pass "failed docs reads stop without guessing"
fi
assert_contains "failed docs reads report an honest error" "$unknown_output" "could not determine whether published docs are complete"
assert_not_contains "failed docs reads dispatch nothing" "$(cat "$GH_LOG")" "/dispatches"

printf '\nrelease.sh release-triggered deploy discovery\n'
: > "$GH_LOG"
: > "$WAIT_LOG"
JUST_PUBLISHED=true
PUBLISH_STARTED_AT=1234567890
GH_DEPLOY_RUN_ID=8123
ensure_docs_deploy 0123456789abcdef0123456789abcdef01234567 >/dev/null
gh_log="$(cat "$GH_LOG")"
assert_contains "release deploy query requests headSha" "$gh_log" "headSha"
assert_contains "release deploy query matches immutable commit SHA" "$gh_log" "0123456789abcdef0123456789abcdef01234567"
assert_contains "release deploy query excludes the earlier library run" "$gh_log" ">= 1234567890"
assert_not_contains "release deploy discovery does not rely on headBranch" "$gh_log" "headBranch"
assert_not_contains "found release-triggered deploy needs no fallback dispatch" "$gh_log" "/dispatches"
assert_contains "release-triggered deploy is awaited" "$(cat "$WAIT_LOG")" "8123 Docs deploy"

resolved_sha="$(resolve_release_tag_sha)"
if [ "$resolved_sha" = 0123456789abcdef0123456789abcdef01234567 ]; then
    pass "release tag resolves to a validated commit SHA"
else
    fail "release tag SHA resolution — got '$resolved_sha'"
fi

printf '\nrelease.sh deterministic dispatch correlation\n'
: > "$GH_LOG"
GH_DEPLOY_RUN_ID=9999
GH_DISPATCH_RUN_ID=4242
release_run_id="$(dispatch_workflow_run release.yml main -f "inputs[version]=$VERSION")"
assert_equals "dispatch returns the run ID from its own API response" "$release_run_id" "4242"
dispatch_log="$(cat "$GH_LOG")"
assert_contains "release dispatch requests run details" "$dispatch_log" "return_run_details=true"
assert_contains "release dispatch names the protected source ref" "$dispatch_log" "ref=main"
assert_contains "release dispatch carries the validated version input" "$dispatch_log" "inputs[version]=1.2.3"
assert_not_contains "concurrent-list fixture cannot replace the returned run" "$dispatch_log" "run list"

for invalid_run_id in '' 0 not-a-run-id; do
    GH_DISPATCH_RUN_ID="$invalid_run_id"
    if dispatch_workflow_run release.yml main -f "inputs[version]=$VERSION" >/dev/null 2>&1; then
        fail "dispatch accepts invalid run ID '$invalid_run_id'"
    else
        pass "dispatch rejects invalid run ID '${invalid_run_id:-empty}'"
    fi
done
GH_DISPATCH_RUN_ID=4242

printf '\nrelease.sh verify-only mutation boundary\n'
: > "$GH_LOG"
VERIFY_ONLY=true
if mutation_output="$(dispatch_workflow_run deploy-docs.yml "$TAG" 2>&1)"; then
    fail "verify-only mutation guard accepted a workflow dispatch"
else
    pass "verify-only mutation guard rejects workflow dispatch"
fi
assert_contains "verify-only mutation guard explains the read-only contract" \
    "$mutation_output" "--verify-only is remote-read-only"
assert_not_contains "verify-only refusal reaches no gh mutation" "$(cat "$GH_LOG")" "/dispatches"
VERIFY_ONLY=false

eval "$WAIT_FOR_RUN_DEFINITION"

CLOCK_FILE="$WORK/clock"
release_now() {
    IFS= read -r _clock < "$CLOCK_FILE"
    printf '%s\n' "$_clock"
}
release_sleep() {
    IFS= read -r _clock < "$CLOCK_FILE"
    printf '%s\n' $((_clock + $1)) > "$CLOCK_FILE"
}

check_wait_timeout() {
    _scenario="$1"
    _expected_status="$2"
    printf '0\n' > "$CLOCK_FILE"
    WAIT_SCENARIO="$_scenario"
    GH_MODE=waiter
    if _output="$(
        RUN_WAIT_TIMEOUT_SECONDS=2 RUN_POLL_INTERVAL_SECONDS=1 \
            wait_for_run 77 "Fixture run" 2>&1
    )"; then
        fail "waiter $_scenario should time out"
        return
    fi
    assert_contains "waiter $_scenario has an explicit timeout" "$_output" "timed out after 2s"
    assert_contains "waiter $_scenario reports its last state" "$_output" "last status: $_expected_status"
    if [ "$_scenario" = waiting ]; then
        _approval_count="$(printf '%s\n' "$_output" | grep -c "APPROVAL NEEDED" || true)"
        assert_equals "waiter announces a waiting approval once" "$_approval_count" "1"
    fi
}

printf '\nrelease.sh bounded workflow waiter\n'
check_wait_timeout queued queued
check_wait_timeout in_progress in_progress
check_wait_timeout waiting waiting
check_wait_timeout mystery "unknown(mystery)"
check_wait_timeout api-error api-error

WAIT_SCENARIO=completed
WAIT_CONCLUSION=failure
GH_MODE=waiter
if completed_output="$(
    RUN_WAIT_TIMEOUT_SECONDS=2 RUN_POLL_INTERVAL_SECONDS=1 \
        wait_for_run 77 "Fixture run" 2>&1
)"; then
    fail "completed failure must not be reported as success"
else
    pass "completed failure exits nonzero"
fi
assert_contains "completed failure reports its conclusion" "$completed_output" "finished 'failure'"
assert_not_contains "completed failure does not wait for timeout" "$completed_output" "timed out"
WAIT_CONCLUSION=success

if completed_output="$(
    RUN_WAIT_TIMEOUT_SECONDS=2 RUN_POLL_INTERVAL_SECONDS=1 \
        wait_for_run 77 "Fixture run" 2>&1
)"; then
    pass "completed success exits zero"
else
    fail "completed success must be reported as success"
fi
assert_contains "completed success reports success" "$completed_output" "Fixture run succeeded"

if zero_interval_output="$(
    RUN_WAIT_TIMEOUT_SECONDS=2 RUN_POLL_INTERVAL_SECONDS=0 \
        wait_for_run 77 "Fixture run" 2>&1
)"; then
    fail "zero poll interval must be rejected"
else
    pass "zero poll interval exits nonzero"
fi
assert_contains "zero poll interval has an actionable error" \
    "$zero_interval_output" "poll interval must be greater than zero"

printf '\nrelease.sh tagged installer compatibility\n'
FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/curl" <<'EOF'
#!/bin/sh
printf 'ppid=%s %s\n' "$PPID" "$*" >> "$INSTALLER_CURL_LOG"
count=0
if [ -f "$INSTALLER_CURL_COUNT" ]; then
    IFS= read -r count < "$INSTALLER_CURL_COUNT"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$INSTALLER_CURL_COUNT"
[ "$count" -gt 1 ] || exit 22
printf '[{"tag_name":"v%s"},{"tag_name":"zcli-v%s"}]\n' \
    "$INSTALLER_VERSION" "$INSTALLER_VERSION"
EOF
chmod +x "$FAKE_BIN/curl"

OLDER_INSTALLER="$WORK/older-tagged-install.sh"
cat > "$OLDER_INSTALLER" <<'EOF'
#!/bin/sh
set -e
REPO="ryanhair/zcli"
RELEASES_PAGE_SIZE=100
print_error() {
    :
}
get_latest_version() {
    if ! command -v curl >/dev/null 2>&1; then
        exit 1
    fi

    releases=$(curl -fsSL --proto '=https' --tlsv1.2 \
        "https://api.github.com/repos/${REPO}/releases?per_page=${RELEASES_PAGE_SIZE}") || releases=''
    if [ -z "${releases}" ]; then
        exit 1
    fi

    tag_lines=$(printf '%s\n' "${releases}" | sed 's/"tag_name"/\
&/g')
    version=$(printf '%s\n' "${tag_lines}" \
        | sed -n 's/^"tag_name"[[:space:]]*:[[:space:]]*"zcli-v\([^"]*\)".*/\1/p' \
        | head -n 1)
    if [ -z "${version}" ]; then
        exit 1
    fi
    if ! printf '%s' "${version}" | grep -qE '^[A-Za-z0-9._-]+$'; then
        exit 1
    fi
    printf '%s\n' "${version}"
}
main() {
    exit 99
}
main
EOF

export INSTALLER_CURL_LOG="$WORK/installer-curl.log"
export INSTALLER_CURL_COUNT="$WORK/installer-curl-count"
export INSTALLER_VERSION=9.8.7

run_installer_fixture() {
    _fixture_label="$1"
    _fixture_file="$2"
    : > "$INSTALLER_CURL_LOG"
    printf '0\n' > "$INSTALLER_CURL_COUNT"

    _resolved_version="$(
        PATH="$FAKE_BIN:$PATH" \
        LIVE_INSTALLER_ATTEMPTS=2 \
        LIVE_INSTALLER_RETRY_SECONDS=0 \
            resolve_live_installer_version "$_fixture_file"
    )"
    assert_equals "$_fixture_label resolves through the outer retry" \
        "$_resolved_version" "$INSTALLER_VERSION"
    _curl_processes="$(awk '{ sub(/^ppid=/, "", $1); if (!seen[$1]++) count++ } END { print count + 0 }' "$INSTALLER_CURL_LOG")"
    assert_equals "$_fixture_label collapses inner retries into two orchestrator attempts" \
        "$_curl_processes" "2"
    assert_contains "$_fixture_label injects a curl connect timeout" \
        "$(cat "$INSTALLER_CURL_LOG")" "--connect-timeout 10"
    assert_contains "$_fixture_label injects a curl total timeout" \
        "$(cat "$INSTALLER_CURL_LOG")" "--max-time 30"
}

run_installer_fixture "older installer without retry constants" "$OLDER_INSTALLER"
run_installer_fixture "current installer with internal retries" "$REPO_ROOT/install.sh"

printf '\npassed: %d   failed: %d\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ]
