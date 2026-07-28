#!/bin/sh
# Regression tests for the installer's release-signature trust model.
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
#   2. scripts/sign-release.sh's trusted_comment_binds_tag — the release
#      ceremony's copy of the same token-exactness rule, extracted by name.
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
SIGN_RELEASE_SH="${REPO_ROOT}/scripts/sign-release.sh"

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
# Load the release ceremony's copy of the token rule, extracted by name.
# ---------------------------------------------------------------------------
awk '/^trusted_comment_binds_tag\(\) \{/,/^\}/' "${SIGN_RELEASE_SH}" > "${WORK}/sign-lib.sh"
if ! grep -q '^trusted_comment_binds_tag() {' "${WORK}/sign-lib.sh" || ! grep -q '^}' "${WORK}/sign-lib.sh"; then
    bad "could not extract trusted_comment_binds_tag() from ${SIGN_RELEASE_SH} — did its shape change?"
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
# Stub the network. verify_signature fetches "<checksum_url>.minisig" with
# curl into "<checksums>.minisig"; serve ${SERVE_SIG} instead. Everything else
# — the pinned-key check, the real `minisign -V`, the line-3 parse and the
# token match — is the shipped code.
# ---------------------------------------------------------------------------
curl() { cp "${SERVE_SIG}" "$7"; }

MINISIGN_PUBKEY="${PUBKEY}"

check() { # <label> <accept|reject> <sig> <tag> <body>
    label="$1"; expect="$2"; SERVE_SIG="${WORK}/$3"; tag="$4"; body="$5"

    cp "${WORK}/${body}" "${WORK}/run-checksums.txt"
    if verify_signature "${WORK}/run-checksums.txt" \
            "https://example.invalid/checksums.txt" "${WORK}" "${tag}" >/dev/null 2>&1; then
        got=accept
    else
        got=reject
    fi

    if [ "${got}" = "${expect}" ]; then
        note "  PASS  install.sh: ${label}"
        pass_count=$((pass_count + 1))
    else
        bad "install.sh: ${label} — expected ${expect}, got ${got}"
        fail_count=$((fail_count + 1))
    fi
}

check_ceremony() { # <label> <accept|reject> <sig> <tag>
    label="$1"; expect="$2"; sig="${WORK}/$3"; tag="$4"

    if trusted_comment_binds_tag "${sig}" "${tag}"; then
        got=accept
    else
        got=reject
    fi

    if [ "${got}" = "${expect}" ]; then
        note "  PASS  sign-release.sh: ${label}"
        pass_count=$((pass_count + 1))
    else
        bad "sign-release.sh: ${label} — expected ${expect}, got ${got}"
        fail_count=$((fail_count + 1))
    fi
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
note "sign-release.sh trusted_comment_binds_tag — same token rule"
check_ceremony "matching tag accepted"                 accept sig-0.20.0.minisig zcli-v0.20.0
check_ceremony "wrong tag rejected"                    reject sig-0.19.0.minisig zcli-v0.20.0
check_ceremony "prefix tag rejected"                   reject sig-0.20.0.minisig zcli-v0.2
check_ceremony "inverse prefix rejected"               reject sig-0.2.minisig    zcli-v0.20.0
check_ceremony "case-only mismatch rejected"           reject sig-0.20.0.minisig ZCLI-V0.20.0
check_ceremony "missing comment prefix rejected"       reject sig-noprefix.minisig zcli-v0.20.0
check_ceremony "empty tag rejected"                    reject sig-0.20.0.minisig ''

note ""
note "passed: ${pass_count}   failed: ${fail_count}"
[ "${fail_count}" -eq 0 ]
