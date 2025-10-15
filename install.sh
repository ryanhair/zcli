#!/bin/sh
# zcli installer script
# Usage: curl -fsSL https://raw.githubusercontent.com/ryanhair/zcli/main/install.sh | sh

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

# Get latest release version from GitHub
get_latest_version() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | \
            grep '"tag_name":' | \
            sed -E 's/.*"tag_name": "zcli-v([^"]+)".*/\1/'
    else
        print_error "curl is required but not found"
        exit 1
    fi
}

# Download binary
download_binary() {
    local version="$1"
    local os="$2"
    local arch="$3"
    local target="${arch}-${os}"
    local url="https://github.com/${REPO}/releases/download/zcli-v${version}/zcli-${target}"
    local checksum_url="https://github.com/${REPO}/releases/download/zcli-v${version}/checksums.txt"
    local tmp_dir=$(mktemp -d)
    local binary_path="${tmp_dir}/zcli"

    print_info "Downloading zcli ${version} for ${target}..."

    if ! curl -fsSL "${url}" -o "${binary_path}"; then
        print_error "Failed to download binary from ${url}"
        rm -rf "${tmp_dir}"
        exit 1
    fi

    # Verify checksum if shasum is available
    if command -v shasum >/dev/null 2>&1; then
        print_info "Verifying checksum..."
        local checksums="${tmp_dir}/checksums.txt"
        if curl -fsSL "${checksum_url}" -o "${checksums}"; then
            local expected_checksum=$(grep "zcli-${target}" "${checksums}" | awk '{print $1}')
            local actual_checksum=$(shasum -a 256 "${binary_path}" | awk '{print $1}')

            if [ "${expected_checksum}" != "${actual_checksum}" ]; then
                print_error "Checksum verification failed!"
                rm -rf "${tmp_dir}"
                exit 1
            fi
            print_success "Checksum verified"
        else
            print_warning "Could not download checksums, skipping verification"
        fi
    fi

    echo "${binary_path}"
}

# Install binary to ~/.local/bin
install_binary() {
    local binary_path="$1"

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
    local dir="$1"
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
    local shell_type="$1"

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
    local config_file="$1"

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
    local shell_type="$1"
    local config_file=$(get_shell_config "${shell_type}")

    # Check if already configured
    if path_already_configured "${config_file}"; then
        print_success "PATH already configured in ${config_file}"
        return 0
    fi

    print_info "Adding ${INSTALL_DIR} to PATH in ${config_file}..."

    # Create config file directory if it doesn't exist (for fish)
    local config_dir=$(dirname "${config_file}")
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
    local os=$(detect_os)
    local arch=$(detect_arch)

    if [ "${os}" = "unknown" ] || [ "${arch}" = "unknown" ]; then
        print_error "Unsupported platform: $(uname -s) $(uname -m)"
        exit 1
    fi

    print_info "Detected platform: ${arch}-${os}"

    # Get latest version
    local version=$(get_latest_version)
    if [ -z "${version}" ]; then
        print_error "Failed to get latest version"
        exit 1
    fi

    # Download binary
    local binary_path=$(download_binary "${version}" "${os}" "${arch}")

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

        local shell_type=$(detect_shell)
        print_info "Detected shell: ${shell_type}"

        local config_file=$(add_to_path "${shell_type}")

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
