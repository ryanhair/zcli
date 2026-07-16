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

# zcli's pinned minisign public key. The installer verifies checksums.txt against
# its detached signature (checksums.txt.minisig) under this key when the
# `minisign` tool is available — closing the gap that checksums alone cannot: a
# compromised release can swap the binary AND its checksum, but not forge a
# signature under a key that never lived in the release pipeline (see ADR-0023).
#
# Key id 1638B69B8EF680FD. The full key lives at docs/zcli-minisign.pub; if
# empty, signature verification is skipped and the fail-closed SHA-256 checksum
# check below still applies. Rotation/compromise: docs/RELEASE-SIGNING.md.
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

# Verify checksums.txt against its detached minisign signature.
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

    print_success "Signature verified"
    return 0
}

# Get latest release version from GitHub
get_latest_version() {
    if ! command -v curl >/dev/null 2>&1; then
        print_error "curl is required but not found"
        exit 1
    fi

    version=$(curl -fsSL --proto '=https' --tlsv1.2 "https://api.github.com/repos/${REPO}/releases/latest" | \
        grep '"tag_name":' | \
        sed -E 's/.*"tag_name": "zcli-v([^"]+)".*/\1/')

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

    # Authenticate checksums.txt against its signature before trusting it. Fail
    # closed: a signature failure, or a missing minisign tool when a key is
    # pinned, aborts the install.
    if ! verify_signature "${checksums}" "${checksum_url}" "${tmp_dir}"; then
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

# Check if PATH export already exists in config file
path_already_configured() {
    config_file="$1"

    if [ ! -f "${config_file}" ]; then
        return 1
    fi

    # Check for various patterns that would add ~/.local/bin to PATH
    if grep -q '\$HOME/.local/bin' "${config_file}" 2>/dev/null || \
       grep -q '~/.local/bin' "${config_file}" 2>/dev/null || \
       grep -q '.local/bin' "${config_file}" 2>/dev/null; then
        return 0
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
