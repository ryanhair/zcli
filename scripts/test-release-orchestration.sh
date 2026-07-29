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
DOCS_FIXTURE=complete

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
            printf 'success\n'
            return 0
        fi
    fi

    case "$1 $2" in
        "api repos/example/zcli/commits/zcli-v1.2.3")
            printf '0123456789abcdef0123456789abcdef01234567\n'
            ;;
        "workflow run")
            return 0
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
            if [ "$DOCS_FIXTURE" = complete ]; then
                printf 'tagged shell installer\n' > "$_out"
            else
                printf 'stale shell installer\n' > "$_out"
            fi
            ;;
        "$SITE/install.ps1")
            if [ "$DOCS_FIXTURE" = complete ]; then
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
assert_not_contains "complete published rerun dispatches nothing" "$gh_log" "workflow run"
assert_not_contains "complete published rerun waits on no workflow" "$(cat "$WAIT_LOG")" "Docs deploy"

: > "$GH_LOG"
: > "$WAIT_LOG"
DOCS_FIXTURE=incomplete
GH_DEPLOY_RUN_ID=9001
ensure_docs_deploy 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1
gh_log="$(cat "$GH_LOG")"
assert_contains "incomplete published state dispatches recovery" "$gh_log" "workflow run deploy-docs.yml"
assert_contains "recovery dispatch uses immutable release tag" "$gh_log" "--ref zcli-v1.2.3"
assert_not_contains "recovery dispatch never uses newer main" "$gh_log" "--ref main"
assert_contains "recovery waits for its discovered run" "$(cat "$WAIT_LOG")" "9001 Docs deploy"

: > "$GH_LOG"
DOCS_FIXTURE=read-failure
if unknown_output="$(ensure_docs_deploy 0123456789abcdef0123456789abcdef01234567 2>&1)"; then
    fail "failed docs reads must not be treated as incomplete"
else
    pass "failed docs reads stop without guessing"
fi
assert_contains "failed docs reads report an honest error" "$unknown_output" "could not determine whether published docs are complete"
assert_not_contains "failed docs reads dispatch nothing" "$(cat "$GH_LOG")" "workflow run"

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
assert_not_contains "found release-triggered deploy needs no fallback dispatch" "$gh_log" "workflow run"
assert_contains "release-triggered deploy is awaited" "$(cat "$WAIT_LOG")" "8123 Docs deploy"

resolved_sha="$(resolve_release_tag_sha)"
if [ "$resolved_sha" = 0123456789abcdef0123456789abcdef01234567 ]; then
    pass "release tag resolves to a validated commit SHA"
else
    fail "release tag SHA resolution — got '$resolved_sha'"
fi

printf '\nrelease.sh verify-only mutation boundary\n'
: > "$GH_LOG"
VERIFY_ONLY=true
if mutation_output="$(gh_mutate workflow run deploy-docs.yml --ref "$TAG" 2>&1)"; then
    fail "verify-only mutation guard accepted a workflow dispatch"
else
    pass "verify-only mutation guard rejects workflow dispatch"
fi
assert_contains "verify-only mutation guard explains the read-only contract" \
    "$mutation_output" "--verify-only is remote-read-only"
assert_not_contains "verify-only refusal reaches no gh mutation" "$(cat "$GH_LOG")" "workflow run"
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
}

printf '\nrelease.sh bounded workflow waiter\n'
check_wait_timeout queued queued
check_wait_timeout in_progress in_progress
check_wait_timeout mystery "unknown(mystery)"
check_wait_timeout api-error api-error

printf '\npassed: %d   failed: %d\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ]
