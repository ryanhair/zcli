#!/bin/sh
# zcli installer script
# Usage: curl -fsSL https://zcli.sh/install.sh | sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
REPO="ryanhair/zcli"
INSTALL_DIR="$HOME/.local/bin"
BINARY_NAME="zcli"

# How many releases get_latest_version asks the API for in one page. Named
# because it appears three times: in the request, in the "did we see every
# release?" test, and in the message that test produces.
RELEASES_PAGE_SIZE=100

# zcli's pinned minisign public key. The installer verifies checksums.txt against
# its detached signature (checksums.txt.minisig) under this key — closing the gap
# that checksums alone cannot: a compromised release can swap the binary AND its
# checksum, but not forge a signature under a key that never lived in the release
# pipeline (see ADR-0023).
#
# Verification is REQUIRED, never best-effort: while this key is set, a missing
# `minisign` tool aborts the install rather than degrading to checksum-only, and
# the signature must also name the exact release tag being installed (see
# verify_signature below). Only an empty key — signing not enabled for a project
# — skips verification, leaving the fail-closed SHA-256 checksum check.
#
# Key id 1638B69B8EF680FD. The full key lives at docs/zcli-minisign.pub.
# Rotation/compromise: docs/RELEASE-SIGNING.md.
MINISIGN_PUBKEY="RWT9gPaOm7Y4Fm5WFqqlWRpI4FgPTIjD5UhUsaZsdKHrWYuWa9jt8ESC"

# Print functions
print_info() {
    printf "${BLUE}==>${NC} %s\n" "$1" >&2
}

print_success() {
    printf "${GREEN}  ✓${NC} %s\n" "$1" >&2
}

print_warning() {
    printf "${YELLOW}  !${NC} %s\n" "$1" >&2
}

print_error() {
    printf "${RED}  ✗${NC} %s\n" "$1" >&2
}

# Detect OS
detect_os() {
    case "$(uname -s)" in
        Linux*)  echo "linux" ;;
        Darwin*) echo "macos" ;;
        *)       echo "unknown" ;;
    esac
}

# Detect architecture
detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "x86_64" ;;
        aarch64) echo "aarch64" ;;
        arm64)   echo "aarch64" ;;
        *)       echo "unknown" ;;
    esac
}

# Compute a SHA-256 digest with whichever tool this system has.
# Fails (empty output, nonzero status) when neither is available.
sha256_digest() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        return 1
    fi
}

# Verify checksums.txt against its detached minisign signature, and bind that
# signature to the exact release tag being installed.
#
# Fail closed: returns 0 only when the signature actually verified (or signing is
# not enabled for this project). Signature verification is REQUIRED when a key is
# pinned — a missing `minisign` tool aborts the install rather than degrading to
# checksum-only, so a compromised publisher (who can rewrite the same-origin
# checksums) is defended against on every install path, not just `zcli upgrade`.
verify_signature() {
    checksums="$1"
    checksum_url="$2"
    tmp_dir="$3"
    expected_tag="$4"

    # Signing not yet enabled for this project — nothing to verify.
    if [ -z "${MINISIGN_PUBKEY}" ]; then
        return 0
    fi

    if ! command -v minisign >/dev/null 2>&1; then
        print_error "minisign is required to verify this release but was not found."
        print_error "Install it and re-run:"
        print_error "  macOS:         brew install minisign"
        print_error "  Debian/Ubuntu: sudo apt install minisign"
        print_error "  Other:         https://jedisct1.github.io/minisign/#installation"
        print_error "Or upgrade an existing install via 'zcli upgrade', which verifies natively."
        return 1
    fi

    sig="${checksums}.minisig"
    if ! curl -fsSL --proto '=https' --tlsv1.2 "${checksum_url}.minisig" -o "${sig}"; then
        print_error "Signature file could not be downloaded (${checksum_url}.minisig)"
        print_error "This release is unsigned or incomplete; refusing to install."
        return 1
    fi

    if ! minisign -Vm "${checksums}" -x "${sig}" -P "${MINISIGN_PUBKEY}" >/dev/null 2>&1; then
        print_error "Signature verification FAILED for checksums.txt"
        print_error "The release may have been tampered with. Aborting."
        return 1
    fi

    # Bind the signature to THIS release. The check above only authenticates
    # checksums.txt, which names artifacts but carries no version — so a
    # compromised publisher could serve an OLDER release's binary, checksums.txt
    # and its genuine .minisig under a newer tag and pass every check so far,
    # silently rolling the user back to a previously-signed (possibly vulnerable)
    # build (a downgrade/replay — CWE-294).
    #
    # The signing ceremony defends against this by embedding the release tag in
    # minisign's *trusted* comment (scripts/sign-release.sh: `-t "zcli $TAG —
    # signed release checksums"`). That comment is line 3 of the .minisig and is
    # covered by minisign's second, "global" signature on line 4 — the `-V` above
    # verifies it and exits nonzero ("Comment signature verification failed")
    # when it does not match, so by this point line 3 is authenticated and its
    # tag can be trusted. Reading it unverified would defeat the point.
    #
    # This mirrors verifyTrustedComment in
    # packages/core/src/plugins/zcli_github_upgrade/minisign.zig, which gives
    # `zcli upgrade` the same guarantee.
    comment_line=$(sed -n '3p' "${sig}" | tr -d '\r')
    case "${comment_line}" in
        "trusted comment: "*) ;;
        *)
            print_error "Signature carries no trusted comment to bind ${expected_tag}."
            print_error "Refusing to install a release whose version cannot be verified."
            return 1
            ;;
    esac
    trusted_comment="${comment_line#"trusted comment: "}"

    # Whole-token match, not substring, so a shorter tag can never be satisfied
    # by a longer one (`zcli-v0.2` must not match `zcli-v0.20.0`). Unquoted
    # expansion does the whitespace tokenization; `set -f` disables globbing so
    # a `*` planted in the comment cannot expand against the working directory.
    set -f
    tag_bound=0
    for token in ${trusted_comment}; do
        if [ "${token}" = "${expected_tag}" ]; then
            tag_bound=1
            break
        fi
    done
    set +f

    if [ "${tag_bound}" -ne 1 ]; then
        print_error "Signature does not name ${expected_tag}."
        print_error "Trusted comment: ${trusted_comment}"
        print_error "This looks like an older, genuinely-signed release replayed"
        print_error "under a newer tag. Refusing a possible downgrade. Aborting."
        return 1
    fi

    print_success "Signature verified (binds ${expected_tag})"
    return 0
}

# Resolve the newest installable CLI release.
#
# This asks for the release LIST, not /releases/latest, because this repo
# publishes two tag families from one workflow (.github/workflows/release.yml):
# library releases tagged `v0.22.0`, published immediately, and CLI releases
# tagged `zcli-v0.22.0`, created as drafts and published only once their
# checksums have been signed offline. Between those two moments — a normal,
# recurring part of every release, not an error — `/releases/latest` returns the
# LIBRARY tag, and an installer that trusts it fails on a tag whose shape it
# cannot parse, with a message about nothing the user did.
#
# The list endpoint is ordered newest-first and omits drafts for anonymous
# callers, so the first `zcli-v*` entry is precisely "the newest CLI release a
# user can actually install". That is the same rule selectVersion applies in
# packages/core/src/plugins/zcli_github_upgrade/plugin.zig, so `curl | sh` and
# `zcli upgrade` resolve identically.
get_latest_version() {
    if ! command -v curl >/dev/null 2>&1; then
        print_error "curl is required but not found"
        exit 1
    fi

    releases=$(curl -fsSL --proto '=https' --tlsv1.2 \
        "https://api.github.com/repos/${REPO}/releases?per_page=${RELEASES_PAGE_SIZE}") || releases=''

    if [ -z "${releases}" ]; then
        print_error "Could not fetch the release list for ${REPO} from the GitHub API."
        print_error "Check your network connection (or GitHub's status) and try again."
        exit 1
    fi

    # Put every "tag_name" key at the start of its own line, so the extraction
    # below can anchor at ^. Without the anchor, sed's greedy `.*` would skip
    # past an earlier match to a later one on the same line, and the API's
    # compact spelling puts many releases on one line.
    #
    # `sed`, not `grep -o`: -o is a GNU extension, and this file is piped into
    # whatever /bin/sh the user has — busybox and the BSDs included. The literal
    # backslash-newline in the replacement is the POSIX way to insert a newline.
    tag_lines=$(printf '%s\n' "${releases}" | sed 's/"tag_name"/\
&/g')

    # First matching tag wins; document order is release order (newest first).
    # Tolerates both the API's pretty-printed `"tag_name": "…"` and a compact
    # `"tag_name":"…"`. Case-sensitive, like every other tag comparison here.
    version=$(printf '%s\n' "${tag_lines}" \
        | sed -n 's/^"tag_name"[[:space:]]*:[[:space:]]*"zcli-v\([^"]*\)".*/\1/p' \
        | head -n 1)

    if [ -z "${version}" ]; then
        # One page holds RELEASES_PAGE_SIZE releases. A short page means we saw
        # every release there is, so no CLI tag really does mean "none published
        # yet" — the mid-publish window. A FULL page means we may simply not
        # have looked far enough back, which is a different problem and deserves
        # a different answer; saying "mid-publish" there would send the user off
        # to wait for something that is never going to happen.
        tag_count=$(printf '%s\n' "${tag_lines}" \
            | grep -cE '^"tag_name"[[:space:]]*:') || tag_count=0

        if [ "${tag_count}" -ge "${RELEASES_PAGE_SIZE}" ]; then
            print_error "No zcli-v* tag in the newest ${RELEASES_PAGE_SIZE} releases of ${REPO}."
            print_error "The CLI release is older than one page of the API, so this installer"
            print_error "cannot find it. Download the binary for your platform directly from"
            print_error "  https://github.com/${REPO}/releases"
            exit 1
        fi

        print_error "No published zcli-v* release found for ${REPO}."
        print_error "A release may be mid-publish: CLI releases stay drafts until their"
        print_error "checksums are signed offline, so there is a short window with nothing"
        print_error "installable. Wait a few minutes and re-run, or pick a release from"
        print_error "  https://github.com/${REPO}/releases"
        exit 1
    fi

    # Defense-in-depth: validate the version against a strict charset before it
    # is interpolated into download URLs, mirroring the in-binary isValidVersionArg
    # check. Rejects '/', '..' and other path-traversal characters.
    if ! printf '%s' "${version}" | grep -qE '^[A-Za-z0-9._-]+$'; then
        print_error "Invalid version string from GitHub API: '${version}'"
        exit 1
    fi

    printf '%s\n' "${version}"
}

# Download binary
download_binary() {
    version="$1"
    os="$2"
    arch="$3"
    target="${arch}-${os}"
    url="https://github.com/${REPO}/releases/download/zcli-v${version}/zcli-${target}"
    checksum_url="https://github.com/${REPO}/releases/download/zcli-v${version}/checksums.txt"
    tmp_dir=$(mktemp -d)
    binary_path="${tmp_dir}/zcli"

    print_info "Downloading zcli ${version} for ${target}..."

    if ! curl -fsSL --proto '=https' --tlsv1.2 "${url}" -o "${binary_path}"; then
        print_error "Failed to download binary from ${url}"
        rm -rf "${tmp_dir}"
        exit 1
    fi

    # Verify the download. Verification is mandatory — if the checksums can't
    # be fetched or no SHA-256 tool exists, abort rather than install an
    # unverified binary.
    print_info "Verifying checksum..."
    checksums="${tmp_dir}/checksums.txt"
    if ! curl -fsSL --proto '=https' --tlsv1.2 "${checksum_url}" -o "${checksums}"; then
        print_error "Failed to download checksums from ${checksum_url}"
        rm -rf "${tmp_dir}"
        exit 1
    fi

    # Authenticate checksums.txt against its signature before trusting it, and
    # require that signature to name the tag we are installing. Fail closed: a
    # signature failure, a version mismatch, or a missing minisign tool when a
    # key is pinned all abort the install.
    if ! verify_signature "${checksums}" "${checksum_url}" "${tmp_dir}" "zcli-v${version}"; then
        rm -rf "${tmp_dir}"
        exit 1
    fi

    # Exact filename-field match so e.g. a "zcli-${target}-debug" entry can
    # never shadow the real one.
    expected_checksum=$(awk -v file="zcli-${target}" '$2 == file {print $1}' "${checksums}")
    if [ -z "${expected_checksum}" ]; then
        print_error "No checksum entry for zcli-${target} in checksums.txt"
        rm -rf "${tmp_dir}"
        exit 1
    fi

    actual_checksum=$(sha256_digest "${binary_path}")
    if [ -z "${actual_checksum}" ]; then
        print_error "Cannot verify download: neither sha256sum nor shasum is available"
        rm -rf "${tmp_dir}"
        exit 1
    fi

    if [ "${expected_checksum}" != "${actual_checksum}" ]; then
        print_error "Checksum verification failed!"
        rm -rf "${tmp_dir}"
        exit 1
    fi
    print_success "Checksum verified"

    echo "${binary_path}"
}

# Install binary to ~/.local/bin
install_binary() {
    binary_path="$1"

    print_info "Installing to ${INSTALL_DIR}..."

    # Create install directory if it doesn't exist
    if [ ! -d "${INSTALL_DIR}" ]; then
        mkdir -p "${INSTALL_DIR}"
        print_success "Created ${INSTALL_DIR}"
    fi

    # Copy binary and make executable
    cp "${binary_path}" "${INSTALL_DIR}/${BINARY_NAME}"
    chmod +x "${INSTALL_DIR}/${BINARY_NAME}"

    print_success "Installed ${BINARY_NAME} to ${INSTALL_DIR}"
}

# Check if directory is in PATH
is_in_path() {
    dir="$1"
    case ":${PATH}:" in
        *:"${dir}":*) return 0 ;;
        *) return 1 ;;
    esac
}

# Detect current shell
detect_shell() {
    # First check environment variables
    if [ -n "${ZSH_VERSION}" ]; then
        echo "zsh"
    elif [ -n "${BASH_VERSION}" ]; then
        echo "bash"
    elif [ -n "${KSH_VERSION}" ]; then
        echo "ksh"
    elif [ -n "${FISH_VERSION}" ]; then
        echo "fish"
    else
        # Fall back to checking SHELL variable
        case "${SHELL}" in
            */zsh)  echo "zsh" ;;
            */bash) echo "bash" ;;
            */ksh)  echo "ksh" ;;
            */fish) echo "fish" ;;
            *)      echo "unknown" ;;
        esac
    fi
}

# Get shell config file(s)
get_shell_config() {
    shell_type="$1"

    case "${shell_type}" in
        zsh)
            echo "${HOME}/.zshrc"
            ;;
        bash)
            # On macOS, Terminal uses login shells, so .bash_profile
            # On Linux, .bashrc is more common
            if [ "$(uname -s)" = "Darwin" ]; then
                if [ -f "${HOME}/.bash_profile" ]; then
                    echo "${HOME}/.bash_profile"
                elif [ -f "${HOME}/.profile" ]; then
                    echo "${HOME}/.profile"
                else
                    echo "${HOME}/.bash_profile"
                fi
            else
                if [ -f "${HOME}/.bashrc" ]; then
                    echo "${HOME}/.bashrc"
                else
                    echo "${HOME}/.bashrc"
                fi
            fi
            ;;
        fish)
            echo "${HOME}/.config/fish/config.fish"
            ;;
        ksh)
            if [ -f "${HOME}/.kshrc" ]; then
                echo "${HOME}/.kshrc"
            else
                echo "${HOME}/.profile"
            fi
            ;;
        *)
            echo "${HOME}/.profile"
            ;;
    esac
}

# Does this config file already put ${INSTALL_DIR} on PATH?
#
# This has to match the mechanism, not a mention of the string. The old check
# was a bare `grep '.local/bin'`: unanchored, with `.` as a regex wildcard, so a
# comment ("# TODO: add ~/.local/bin to PATH"), an unrelated entry
# (`$HOME/mylocal/binaries`) or any incidental `X` + `local/bin` convinced the
# installer PATH was already configured. It then skipped the append and printed
# success while leaving zcli off PATH.
#
# The two error directions are not symmetric. A false positive is the bug above:
# a silently broken install. A false negative just appends a second export line
# on a repeat install. So this errs strict — three conditions, all required:
#
#   1. the line is not a shell comment;
#   2. the line actually sets PATH (an assignment, or fish's fish_add_path);
#   3. the install dir appears as a WHOLE path component — `~/.local/bin`
#      followed by a separator or end of line, never `~/.local/binaries`.
#
# Spellings accepted for (3): `$HOME/.local/bin`, `${HOME}/.local/bin`,
# `~/.local/bin`, and ${INSTALL_DIR} written out absolutely. All four are in
# the wild — Debian's stock ~/.profile uses the first — and every one of them
# genuinely works, so recognizing them keeps repeat installs idempotent.
path_already_configured() {
    config_file="$1"

    if [ ! -f "${config_file}" ]; then
        return 1
    fi

    # (1) drop comments, using sh's own rule: `#` at the start of the line or
    #     preceded by whitespace. `abc#def` is not a comment and is left alone.
    # (2) keep only lines that put something on PATH:
    #       PATH=…            sh/bash/zsh/ksh assignment, with or without export
    #       path=(…)          zsh's lowercase array, which is tied to $PATH —
    #       path+=(…)         and zsh is the macOS default shell, so this form
    #                         is common enough that missing it would double-append
    #       fish_add_path …   fish
    #       set -gx PATH …    fish, and `setenv PATH …` in csh — PATH is a
    #                         separate word rather than the target of an `=`
    #     The leading `(^|[^[:alnum:]_])` guard keeps `MYPATH=` and `mypath=(`
    #     out. Prose that merely ends in "…on your PATH" has none of these.
    path_lines=$(sed -e 's/^#.*$//' -e 's/[[:space:]]#.*$//' "${config_file}" \
        | grep -E '(^|[^[:alnum:]_])(PATH=|path\+?=\(|fish_add_path)|set.*[[:space:]]PATH[[:space:]]') \
        || path_lines=''

    if [ -z "${path_lines}" ]; then
        return 1
    fi

    # (3) symbolic spellings of $HOME.
    if printf '%s\n' "${path_lines}" \
        | grep -qE '(\$HOME|\$\{HOME\}|~)/\.local/bin([^[:alnum:]_./-]|$)'; then
        return 0
    fi

    # (3, cont.) the same directory written out absolutely. ${INSTALL_DIR} is
    # data, not a pattern, so escape every ERE metacharacter it could contain
    # before splicing it in — a `+` or `(` in $HOME must match itself.
    if [ -n "${INSTALL_DIR}" ]; then
        install_dir_re=$(printf '%s' "${INSTALL_DIR}" | sed 's/[][\\^$.|?*+(){}]/\\&/g')
        if printf '%s\n' "${path_lines}" \
            | grep -qE "${install_dir_re}([^[:alnum:]_./-]|\$)"; then
            return 0
        fi
    fi

    return 1
}

# Add PATH to shell config
add_to_path() {
    shell_type="$1"
    config_file=$(get_shell_config "${shell_type}")

    # Check if already configured
    if path_already_configured "${config_file}"; then
        print_success "PATH already configured in ${config_file}"
        return 0
    fi

    print_info "Adding ${INSTALL_DIR} to PATH in ${config_file}..."

    # Create config file directory if it doesn't exist (for fish)
    config_dir=$(dirname "${config_file}")
    if [ ! -d "${config_dir}" ]; then
        mkdir -p "${config_dir}"
    fi

    # Add PATH export based on shell type
    case "${shell_type}" in
        fish)
            # Use fish_add_path if available, otherwise set PATH directly
            echo "" >> "${config_file}"
            echo "# Added by zcli installer" >> "${config_file}"
            echo "if type -q fish_add_path" >> "${config_file}"
            echo "    fish_add_path \$HOME/.local/bin" >> "${config_file}"
            echo "else" >> "${config_file}"
            echo "    set -gx PATH \$HOME/.local/bin \$PATH" >> "${config_file}"
            echo "end" >> "${config_file}"
            ;;
        *)
            # POSIX-compatible shells (bash, zsh, ksh, etc.)
            echo "" >> "${config_file}"
            echo "# Added by zcli installer" >> "${config_file}"
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "${config_file}"
            ;;
    esac

    print_success "Added to PATH in ${config_file}"
    echo "${config_file}"
}

# Main installation flow
main() {
    print_info "Installing zcli..."
    echo "" >&2

    # Detect platform
    os=$(detect_os)
    arch=$(detect_arch)

    if [ "${os}" = "unknown" ] || [ "${arch}" = "unknown" ]; then
        print_error "Unsupported platform: $(uname -s) $(uname -m)"
        exit 1
    fi

    print_info "Detected platform: ${arch}-${os}"

    # Get latest version
    version=$(get_latest_version)
    if [ -z "${version}" ]; then
        print_error "Failed to get latest version"
        exit 1
    fi

    # Download binary
    binary_path=$(download_binary "${version}" "${os}" "${arch}")

    # Install binary
    install_binary "${binary_path}"

    # Clean up temp files
    rm -rf "$(dirname "${binary_path}")"

    echo "" >&2
    print_success "zcli ${version} installed successfully!"
    echo "" >&2

    # Check PATH and configure if needed
    if is_in_path "${INSTALL_DIR}"; then
        print_success "${INSTALL_DIR} is already in your PATH"
        printf "${BLUE}==>${NC} You can now use: ${GREEN}zcli --help${NC}\n" >&2
    else
        print_warning "${INSTALL_DIR} is not in your PATH"

        shell_type=$(detect_shell)
        print_info "Detected shell: ${shell_type}"

        config_file=$(add_to_path "${shell_type}")

        echo "" >&2
        print_info "To use zcli immediately, run:"
        echo "" >&2
        case "${shell_type}" in
            fish)
                printf "    ${GREEN}source %s${NC}\n" "${config_file}" >&2
                ;;
            *)
                printf "    ${GREEN}source %s${NC}\n" "${config_file}" >&2
                ;;
        esac
        echo "" >&2
        print_info "Or restart your terminal, then run:"
        echo "" >&2
        printf "    ${GREEN}zcli --help${NC}\n" >&2
        echo "" >&2
    fi
}

main
