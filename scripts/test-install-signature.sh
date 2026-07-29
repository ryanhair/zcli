#!/bin/sh
# Regression tests for the installer's release-signature trust model, and for
# the two other ways install.sh can silently hand a user a broken install.
#
# install.sh is a `curl | sh` trust root: it is the only validation most users
# ever run, and it is not covered by `zig build test` (no Zig involved). These
# assertions exist so a regression in the signature or version-binding logic
# fails CI rather than shipping.
#
# What is under test, against REAL minisign signatures made with a throwaway
# keypair generated per run:
#   1. install.sh's verify_signature — the whole function, sourced from the
#      shipped file, with only the network fetch stubbed.
#   2. scripts/release.sh's trusted_comment_binds_tag — the release
#      ceremony's copy of the same token-exactness rule, extracted by name.
#   3. scripts/release.sh's downloaded-binary execution gate — both the
#      signature and checksums must authenticate before the binary can run.
#   4. install.sh's get_latest_version — that it selects the newest `zcli-v*`
#      release from the release LIST, so a library tag published ahead of the
#      still-draft CLI tag cannot derail an install (#774), and that its two
#      no-release outcomes (mid-publish window vs. a CLI release older than one
#      API page) are told apart, because the advice differs. API failures retry
#      a fixed number of bounded requests rather than failing once or hanging.
#   5. install.sh's path_already_configured — that it recognizes a real PATH
#      export and only a real one, so an incidental mention of the string
#      cannot make the installer skip the append and report success while
#      leaving zcli off PATH (#771). Includes a round-trip: what add_to_path
#      writes must satisfy the check, or repeat installs double-append.
#   6. install.sh's POSIX-ness as a static property — a deny-list for GNU-only
#      options like `grep -o`, which parse everywhere and only fail at run time
#      on the busybox/BSD systems this script most needs to work on.
#
# The matching PowerShell surface lives in scripts/test-install-signature.ps1.
# Semantics all four copies must share (the fourth is verifyTrustedComment in
# packages/core/src/plugins/zcli_github_upgrade/minisign.zig, covered by the Zig
# unit tests): a signature is accepted only when its authenticated trusted
# comment names the exact release tag as a whole whitespace-delimited token.
#
# Deliberately `#!/bin/sh`, and CI runs it with `sh` on Linux (where that is
# dash): install.sh must stay POSIX, so a bashism introduced into
# verify_signature fails here too.
#
# Usage: sh scripts/test-install-signature.sh
#   ZCLI_REQUIRE_MINISIGN=1  a missing minisign binary is a hard failure rather
#                            than a skip (CI sets this; dev boxes need not).

set -e

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
INSTALL_SH="${REPO_ROOT}/install.sh"
RELEASE_SH="${REPO_ROOT}/scripts/release.sh"

pass_count=0
fail_count=0

note() { printf '%s\n' "$1"; }
bad()  { printf '::error::%s\n' "$1"; }

if ! command -v minisign >/dev/null 2>&1; then
    if [ -n "${ZCLI_REQUIRE_MINISIGN:-}" ]; then
        bad "ZCLI_REQUIRE_MINISIGN=1 but no minisign binary was found — the installer signature tests cannot run"
        exit 1
    fi
    note "SKIP: minisign not installed (set ZCLI_REQUIRE_MINISIGN=1 to make this a failure)"
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# ---------------------------------------------------------------------------
# Load the real verify_signature.
#
# install.sh calls main() on load, so strip that one trailing line and source
# the rest. install.sh itself stays untouched — this must exercise exactly what
# ships, not a testability-modified copy. If the invocation ever stops being a
# bare `main` line, fail loudly rather than sourcing a script that would run the
# installer for real.
# ---------------------------------------------------------------------------
main_lines=$(grep -c '^main$' "${INSTALL_SH}" || true)
if [ "${main_lines}" != "1" ]; then
    bad "expected exactly one bare 'main' line in install.sh, found ${main_lines} — update this harness's strip-and-source before it runs the installer for real"
    exit 1
fi
grep -v '^main$' "${INSTALL_SH}" > "${WORK}/installer.sh"
# shellcheck source=/dev/null
. "${WORK}/installer.sh"

# ---------------------------------------------------------------------------
# Load the release ceremony's small security predicates, extracted by name.
# ---------------------------------------------------------------------------
awk '/^trusted_comment_binds_tag\(\) \{/,/^\}/' "${RELEASE_SH}" > "${WORK}/sign-lib.sh"
awk '/^published_binary_is_authenticated\(\) \{/,/^\}/' "${RELEASE_SH}" >> "${WORK}/sign-lib.sh"
if ! grep -q '^trusted_comment_binds_tag() {' "${WORK}/sign-lib.sh" \
   || ! grep -q '^published_binary_is_authenticated() {' "${WORK}/sign-lib.sh"; then
    bad "could not extract release.sh security predicates — did their shape change?"
    exit 1
fi
# shellcheck source=/dev/null
. "${WORK}/sign-lib.sh"

# ---------------------------------------------------------------------------
# Fixtures: a throwaway keypair and genuinely-signed checksums for two tags.
# ---------------------------------------------------------------------------
minisign -G -W -p "${WORK}/test.pub" -s "${WORK}/test.key" >/dev/null 2>&1
PUBKEY=$(sed -n '2p' "${WORK}/test.pub")

printf 'abc123  zcli-x86_64-linux\ndef456  zcli-aarch64-macos\n' > "${WORK}/checksums.txt"
printf 'abc123  zcli-x86_64-linux\nBADBAD  zcli-aarch64-macos\n' > "${WORK}/tampered.txt"

sign_as() { # <out-sig> <tag>
    minisign -S -W -s "${WORK}/test.key" -m "${WORK}/checksums.txt" -x "$1" \
        -t "zcli $2 — signed release checksums" >/dev/null 2>&1
}
sign_as "${WORK}/sig-0.20.0.minisig" "zcli-v0.20.0"
sign_as "${WORK}/sig-0.19.0.minisig" "zcli-v0.19.0"
sign_as "${WORK}/sig-0.2.minisig"    "zcli-v0.2"

# An attacker rewrites the trusted comment to claim the new tag but cannot
# re-sign it: minisign's global signature (line 4) still covers the old text.
{ sed -n '1,2p' "${WORK}/sig-0.19.0.minisig"
  echo 'trusted comment: zcli zcli-v0.20.0 — signed release checksums'
  sed -n '4p' "${WORK}/sig-0.19.0.minisig"; } > "${WORK}/sig-rewritten.minisig"

# Line 3 present but missing the `trusted comment: ` prefix.
{ sed -n '1,2p' "${WORK}/sig-0.20.0.minisig"
  echo 'zcli zcli-v0.20.0 — signed release checksums'
  sed -n '4p' "${WORK}/sig-0.20.0.minisig"; } > "${WORK}/sig-noprefix.minisig"

# ---------------------------------------------------------------------------
# Stub the network for both of install.sh's curl call sites, using curl's own
# rule to tell them apart: `-o <file>` downloads to that file, otherwise the
# body goes to stdout.
#
#   verify_signature   fetches "<checksum_url>.minisig" with -o; serve ${SERVE_SIG}.
#   get_latest_version reads the releases API from stdout; serve ${SERVE_RELEASES},
#                      or fail like curl's --fail when ${SERVE_RELEASES_FAILS}=1.
#
# Everything else — the pinned-key check, the real `minisign -V`, the line-3
# parse, the token match, the tag selection — is the shipped code.
# ---------------------------------------------------------------------------
curl() {
    curl_out=''
    curl_prev=''
    for curl_arg in "$@"; do
        if [ "${curl_prev}" = "-o" ]; then curl_out="${curl_arg}"; fi
        curl_prev="${curl_arg}"
    done

    if [ -n "${curl_out}" ]; then
        cp "${SERVE_SIG}" "${curl_out}"
        return 0
    fi

    if [ -n "${RELEASE_CURL_CALLS_FILE:-}" ]; then
        release_curl_calls=$(cat "${RELEASE_CURL_CALLS_FILE}")
        printf '%s\n' $((release_curl_calls + 1)) > "${RELEASE_CURL_CALLS_FILE}"
    fi

    if [ -n "${RELEASE_CURL_FAILURES_FILE:-}" ]; then
        release_curl_failures=$(cat "${RELEASE_CURL_FAILURES_FILE}")
        if [ "${release_curl_failures}" -gt 0 ]; then
            printf '%s\n' $((release_curl_failures - 1)) > "${RELEASE_CURL_FAILURES_FILE}"
            return 22
        fi
    fi

    if [ "${SERVE_RELEASES_FAILS:-0}" = "1" ]; then
        return 22
    fi
    printf '%s\n' "${SERVE_RELEASES}"
}

# Retry tests must be deterministic and fast; get_latest_version still executes
# its real retry loop, with only the delay replaced.
sleep() { :; }

MINISIGN_PUBKEY="${PUBKEY}"

report() { # <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        note "  PASS  $1"
        pass_count=$((pass_count + 1))
    else
        bad "$1 — expected $2, got $3"
        fail_count=$((fail_count + 1))
    fi
}

check() { # <label> <accept|reject> <sig> <tag> <body>
    label="$1"; expect="$2"; SERVE_SIG="${WORK}/$3"; tag="$4"; body="$5"

    cp "${WORK}/${body}" "${WORK}/run-checksums.txt"
    if verify_signature "${WORK}/run-checksums.txt" \
            "https://example.invalid/checksums.txt" "${WORK}" "${tag}" >/dev/null 2>&1; then
        got=accept
    else
        got=reject
    fi

    report "install.sh: ${label}" "${expect}" "${got}"
}

check_ceremony() { # <label> <accept|reject> <sig> <tag>
    label="$1"; expect="$2"; sig="${WORK}/$3"; tag="$4"

    if trusted_comment_binds_tag "${sig}" "${tag}"; then
        got=accept
    else
        got=reject
    fi

    report "release.sh: ${label}" "${expect}" "${got}"
}

check_binary_gate() { # <label> <run|refuse> <signature-ok> <checksums-ok>
    label="$1"; expect="$2"
    if published_binary_is_authenticated "$3" "$4"; then
        got=run
    else
        got=refuse
    fi
    report "release.sh binary gate: ${label}" "${expect}" "${got}"
}

note "install.sh verify_signature — version binding"
check "matching tag accepted"                  accept sig-0.20.0.minisig   zcli-v0.20.0 checksums.txt
check "downgrade replay rejected"              reject sig-0.19.0.minisig   zcli-v0.20.0 checksums.txt
check "prefix tag rejected (v0.2 vs v0.20.0)"  reject sig-0.20.0.minisig   zcli-v0.2    checksums.txt
check "inverse prefix rejected"                reject sig-0.2.minisig      zcli-v0.20.0 checksums.txt
check "case-only mismatch rejected"            reject sig-0.20.0.minisig   ZCLI-V0.20.0 checksums.txt
check "rewritten trusted comment rejected"     reject sig-rewritten.minisig zcli-v0.20.0 checksums.txt
check "missing comment prefix rejected"        reject sig-noprefix.minisig zcli-v0.20.0 checksums.txt
check "tampered checksums rejected"            reject sig-0.20.0.minisig   zcli-v0.20.0 tampered.txt

note ""
note "install.sh verify_signature — pinned-key behavior"
MINISIGN_PUBKEY=''
check "empty pinned key skips verification"    accept sig-0.19.0.minisig   zcli-v0.20.0 checksums.txt
# shellcheck disable=SC2034  # consumed by verify_signature, sourced from install.sh
MINISIGN_PUBKEY="${PUBKEY}"

note ""
note "release.sh trusted_comment_binds_tag — same token rule"
check_ceremony "matching tag accepted"                 accept sig-0.20.0.minisig zcli-v0.20.0
check_ceremony "wrong tag rejected"                    reject sig-0.19.0.minisig zcli-v0.20.0
check_ceremony "prefix tag rejected"                   reject sig-0.20.0.minisig zcli-v0.2
check_ceremony "inverse prefix rejected"               reject sig-0.2.minisig    zcli-v0.20.0
check_ceremony "case-only mismatch rejected"           reject sig-0.20.0.minisig ZCLI-V0.20.0
check_ceremony "missing comment prefix rejected"       reject sig-noprefix.minisig zcli-v0.20.0
check_ceremony "empty tag rejected"                    reject sig-0.20.0.minisig ''

note ""
note "release.sh published binary — authenticate before execution"
check_binary_gate "signature and checksums valid" run    true  true
check_binary_gate "bad signature"                 refuse false true
check_binary_gate "bad checksum"                  refuse true  false
check_binary_gate "both invalid"                  refuse false false

# ---------------------------------------------------------------------------
# install.sh get_latest_version — release selection (#774).
#
# release.yml publishes two tag families: library tags (`v0.22.0`) go out
# immediately, CLI tags (`zcli-v0.22.0`) stay drafts until their checksums are
# signed offline. `/releases/latest` therefore returns the LIBRARY tag for the
# whole of that window, which happens on every single release. The installer
# must read the release list and take the newest `zcli-v*` instead — and when
# there genuinely isn't one yet, say so in those words rather than complaining
# about a malformed version.
#
# Bodies below are shaped like the real API response (pretty-printed, newest
# first); one case uses the compact spelling to pin that both parse.
# ---------------------------------------------------------------------------
LIST_BOTH='[
  { "tag_name": "v0.22.0" },
  { "tag_name": "zcli-v0.22.0" },
  { "tag_name": "v0.21.0" },
  { "tag_name": "zcli-v0.21.0" }
]'
LIST_MID_PUBLISH='[
  { "tag_name": "v0.22.0" },
  { "tag_name": "zcli-v0.21.0" },
  { "tag_name": "v0.21.0" }
]'
LIST_NO_CLI='[
  { "tag_name": "v0.22.0" },
  { "tag_name": "v0.21.0" }
]'
LIST_COMPACT='[{"tag_name":"v0.22.0"},{"tag_name":"zcli-v0.22.0"}]'
LIST_TRAVERSAL='[{"tag_name":"zcli-v../../evil/releases/download/other-v9.9.9"}]'
LIST_CASE_VARIANT='[{"tag_name":"ZCLI-V0.22.0"}]'

# A FULL page with no zcli-v tag means something different from a short one:
# not "nothing is published yet" but "we may not have looked far enough back".
# Sized from install.sh's own constant so the fixture cannot drift from it.
LIST_FULL_PAGE=$(
    printf '['
    i=0
    while [ "${i}" -lt "${RELEASES_PAGE_SIZE}" ]; do
        if [ "${i}" -gt 0 ]; then printf ','; fi
        printf '{"tag_name":"v0.%d.0"}' "${i}"
        i=$((i + 1))
    done
    printf ']'
)

check_version() { # <label> <expected-version|reject> <releases-json>
    label="$1"; expect="$2"; SERVE_RELEASES="$3"

    got=$(get_latest_version 2>/dev/null) || got=reject
    report "install.sh: ${label}" "${expect}" "${got}"
}

# Runs get_latest_version for its DIAGNOSTIC, not its result: <must-contain> has
# to appear on stderr and <must-not-contain> must not. The two no-release cases
# are different problems with different advice, so telling them apart is the
# point — a "wait a few minutes" message for a condition that will never clear
# is worse than no message.
check_version_message() { # <label> <releases-json> <must-contain> <must-not-contain>
    label="$1"; SERVE_RELEASES="$2"; want="$3"; unwanted="$4"

    msg=$(get_latest_version 2>&1 >/dev/null) || true
    case "${msg}" in
        *"${want}"*)
            case "${msg}" in
                *"${unwanted}"*) got="also says '${unwanted}': ${msg}" ;;
                *)               got=explained ;;
            esac
            ;;
        *) got="does not say '${want}': ${msg}" ;;
    esac

    report "install.sh: ${label}" explained "${got}"
}

note ""
note "install.sh get_latest_version — newest installable zcli-v* release"
SERVE_RELEASES_FAILS=0
check_version "newest CLI tag wins over the library tag above it" 0.22.0 "${LIST_BOTH}"
check_version "library tag published ahead of a draft CLI tag skipped" 0.21.0 "${LIST_MID_PUBLISH}"
check_version "compact JSON parses too"                          0.22.0 "${LIST_COMPACT}"
check_version "no zcli-v* release yet rejected"                  reject "${LIST_NO_CLI}"
check_version "path-traversal tag rejected, not skipped over"    reject "${LIST_TRAVERSAL}"
check_version "case-variant tag family not accepted"             reject "${LIST_CASE_VARIANT}"
check_version "full page with no CLI tag rejected"               reject "${LIST_FULL_PAGE}"

# The mid-publish window is a normal, recurring condition, so the diagnostic has
# to name it — a user who hits it should be told to wait, not sent hunting for a
# fault on their machine. A full page of non-CLI tags must NOT claim that:
# waiting will not help, the release is simply off the end of the page.
check_version_message "mid-publish window explained to the user" \
    "${LIST_NO_CLI}" 'mid-publish' 'older than one page'
check_version_message "exhausted page distinguished from mid-publish" \
    "${LIST_FULL_PAGE}" 'older than one page' 'mid-publish'

SERVE_RELEASES="${LIST_BOTH}"
printf '2\n' > "${WORK}/release-curl-failures"
printf '0\n' > "${WORK}/release-curl-calls"
RELEASE_CURL_FAILURES_FILE="${WORK}/release-curl-failures"
RELEASE_CURL_CALLS_FILE="${WORK}/release-curl-calls"
retry_version=$(get_latest_version 2>/dev/null) || retry_version=reject
report "install.sh: transient API failures recover" 0.22.0 "${retry_version}"
report "install.sh: release-list retries are bounded and exact" \
    "${RELEASE_LIST_ATTEMPTS}" "$(cat "${RELEASE_CURL_CALLS_FILE}")"
unset RELEASE_CURL_FAILURES_FILE RELEASE_CURL_CALLS_FILE

SERVE_RELEASES_FAILS=1
SERVE_RELEASES=''
check_version "unreachable API rejected" reject '(unused)'
SERVE_RELEASES_FAILS=0

# ---------------------------------------------------------------------------
# install.sh must stay POSIX. It is piped into whatever /bin/sh the user has —
# busybox ash on Alpine, a real Bourne-ish sh on the BSDs. `dash -n` and the
# dash leg of this harness catch syntax-level bashisms, but NOT a GNU-only
# option to a POSIX utility: `grep -o` parses fine everywhere and simply does
# not exist on some systems, so it would fail at run time on the machines least
# able to debug it. Deny-list the ones this file has actually reached for.
#
# Comments are stripped first, so the prose explaining why `grep -o` is absent
# does not itself trip the check.
# ---------------------------------------------------------------------------
note ""
note "install.sh — POSIX-only utilities and syntax"
INSTALL_SH_CODE=$(sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#.*$//' "${INSTALL_SH}")

deny() { # <label> <ere>
    hit=$(printf '%s\n' "${INSTALL_SH_CODE}" | grep -nE "$2" | head -n 1) || hit=''
    if [ -n "${hit}" ]; then
        got="present: ${hit}"
    else
        got=absent
    fi
    report "install.sh: $1" absent "${got}"
}

deny "no 'grep -o' (GNU extension)"        'grep[[:space:]]+-[[:alnum:]]*o'
deny "no 'grep -P' (GNU extension)"        'grep[[:space:]]+-[[:alnum:]]*P'
deny "no 'sed -E' / 'sed -r' (not POSIX)"  'sed[[:space:]]+-[[:alnum:]]*[Er]'
deny "no 'echo -n' / 'echo -e'"            'echo[[:space:]]+-[[:alnum:]]'
deny "no '[[ ]]' (bashism)"                '\[\[[[:space:]]'
deny "no 'local' (not POSIX)"              '(^|[[:space:];])local[[:space:]]'
deny "no 'readarray' / 'mapfile'"          '(readarray|mapfile)'

# ---------------------------------------------------------------------------
# install.sh path_already_configured — PATH detection (#771).
#
# The old check was `grep '.local/bin'`: unanchored, `.` a wildcard, so any
# incidental mention convinced the installer PATH was already set up. It then
# skipped the append and printed success over a binary that was not on PATH.
#
# Both directions matter. A false positive is that silent breakage; a false
# negative double-appends on a repeat install. So the accept cases below are
# the spellings that genuinely work (Debian's stock ~/.profile uses the first)
# and the reject cases are near-misses that do not.
# ---------------------------------------------------------------------------
FAKE_HOME="${WORK}/home"
mkdir -p "${FAKE_HOME}/.local/bin"

check_path() { # <label> <configured|not-configured> <config-body>
    label="$1"; expect="$2"; body="$3"
    cfg="${WORK}/rc"
    printf '%s\n' "${body}" > "${cfg}"

    if ( HOME="${FAKE_HOME}"; INSTALL_DIR="${FAKE_HOME}/.local/bin"
         path_already_configured "${cfg}" ); then
        got=configured
    else
        got=not-configured
    fi

    report "install.sh: ${label}" "${expect}" "${got}"
}

note ""
note "install.sh path_already_configured — real PATH exports"
check_path "the line the installer itself writes" configured \
    'export PATH="$HOME/.local/bin:$PATH"'
check_path "Debian stock ~/.profile form"        configured \
    'PATH="$HOME/.local/bin:$PATH"'
check_path "tilde form"                          configured \
    'export PATH=~/.local/bin:$PATH'
check_path "braced \${HOME} form"                configured \
    'export PATH="${HOME}/.local/bin:$PATH"'
check_path "absolute path form"                  configured \
    "export PATH=\"${FAKE_HOME}/.local/bin:\$PATH\""
check_path "fish_add_path form"                  configured \
    'fish_add_path $HOME/.local/bin'
check_path "fish set -gx form"                   configured \
    'set -gx PATH $HOME/.local/bin $PATH'
# zsh's lowercase `path` array is tied to $PATH, and zsh is the macOS default
# shell — missing this form would double-append for a large share of users.
check_path "zsh path=() array form"              configured \
    'path=(~/.local/bin $path)'
check_path "zsh path+=() array form"             configured \
    'path+=($HOME/.local/bin)'

note ""
note "install.sh path_already_configured — mentions that configure nothing"
check_path "whole-line comment"                  not-configured \
    '# TODO: add ~/.local/bin to PATH one day'
check_path "trailing comment on another export"  not-configured \
    'export PATH="$HOME/bin:$PATH"  # not ~/.local/bin'
check_path "prose mentioning PATH"               not-configured \
    'echo "remember to put ~/.local/bin on your PATH"'
check_path "longer sibling directory"            not-configured \
    'export PATH="$HOME/.local/binaries:$PATH"'
check_path "wildcard-only match (old .local/bin regex)" not-configured \
    'export PATH="$HOME/mylocal/binaries:$PATH"'
check_path "suffixed directory"                  not-configured \
    'export PATH="$HOME/.local/bin.old:$PATH"'
check_path "subdirectory, not the dir itself"    not-configured \
    'export PATH="$HOME/.local/bin/extra:$PATH"'
check_path "alias that is not a PATH change"     not-configured \
    'alias lb="ls ~/.local/bin"'
check_path "unrelated lowercase array"           not-configured \
    'mypath=(~/.local/bin)'

# A missing config file is the common case on a fresh machine, and the check
# runs mid-install with the user's terminal attached. Asserting the return value
# alone would be vacuous — every plausible implementation returns 1 here, guard
# or no guard. What is NOT free is doing it quietly: drop the `[ -f ]` guard and
# sed prints "no such file or directory" straight into the install output. So
# assert the silence, which is the part that can actually regress.
missing_err=$( ( HOME="${FAKE_HOME}"; INSTALL_DIR="${FAKE_HOME}/.local/bin"
                 path_already_configured "${WORK}/does-not-exist" ) 2>&1 >/dev/null ) \
    && missing_rc=configured || missing_rc=not-configured

report "install.sh: missing config file" not-configured "${missing_rc}"
if [ -n "${missing_err}" ]; then
    got="noisy: ${missing_err}"
else
    got=silent
fi
report "install.sh: missing config file probed silently" silent "${got}"

# The absolute-path branch splices ${INSTALL_DIR} into an ERE, so a $HOME
# carrying regex metacharacters has to match itself and nothing else. `a+b.c`
# unescaped means "one or more a, then b, then any char, then c" — which fails
# to match its own literal text and does match `aab_c`. Both directions here.
ODD_HOME="${WORK}/a+b.c"
check_path_odd() { # <label> <configured|not-configured> <config-body>
    printf '%s\n' "$3" > "${WORK}/rc"
    if ( HOME="${ODD_HOME}"; INSTALL_DIR="${ODD_HOME}/.local/bin"
         path_already_configured "${WORK}/rc" ); then
        got=configured
    else
        got=not-configured
    fi
    report "install.sh: $1" "$2" "${got}"
}
check_path_odd "regex metacharacters in \$HOME match literally" configured \
    "export PATH=\"${ODD_HOME}/.local/bin:\$PATH\""
check_path_odd "regex metacharacters in \$HOME are not wildcards" not-configured \
    "export PATH=\"${WORK}/aab_c/.local/bin:\$PATH\""

# ---------------------------------------------------------------------------
# Round-trip: whatever add_to_path writes must satisfy path_already_configured.
# Without this, tightening the matcher could silently make every repeat install
# append another export block.
# ---------------------------------------------------------------------------
note ""
note "install.sh add_to_path — its own output is recognized on re-run"
for shell_type in bash zsh ksh fish; do
    rt_home="${WORK}/roundtrip-${shell_type}"
    mkdir -p "${rt_home}"

    rt_cfg=$( HOME="${rt_home}"; INSTALL_DIR="${rt_home}/.local/bin"
              add_to_path "${shell_type}" 2>/dev/null )

    # shellcheck disable=SC2034  # consumed by path_already_configured, sourced from install.sh
    if ( HOME="${rt_home}"; INSTALL_DIR="${rt_home}/.local/bin"
         path_already_configured "${rt_cfg}" ); then
        got=configured
    else
        got=not-configured
    fi

    report "install.sh: add_to_path ${shell_type} output re-detected" configured "${got}"
done

note ""
note "passed: ${pass_count}   failed: ${fail_count}"
[ "${fail_count}" -eq 0 ]
