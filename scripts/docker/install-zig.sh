#!/bin/bash
# Script to reliably install Zig using community mirrors with signature verification

set -e

ZIG_VERSION="${1:-0.15.1}"
ARCH="${2:-x86_64}"
OS="${3:-linux}"
INSTALL_DIR="${4:-/opt}"
VERIFY_SIGNATURE="${5:-true}"

TARBALL_NAME="zig-${ARCH}-${OS}-${ZIG_VERSION}.tar.xz"
SIGNATURE_NAME="${TARBALL_NAME}.minisig"
PUBKEY="RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U"

echo "Installing Zig ${ZIG_VERSION} for ${OS}-${ARCH}..."

# Try direct download first
DIRECT_URL="https://ziglang.org/download/${ZIG_VERSION}/${TARBALL_NAME}"

# Community mirrors (will be fetched dynamically)
MIRRORS=(
    "https://ziglang.org/download/${ZIG_VERSION}"
    "https://github.com/ziglang/zig/releases/download/${ZIG_VERSION}"
    "https://mirror.bazel.build/ziglang.org/download/${ZIG_VERSION}"
    "https://cdn.jsdelivr.net/gh/ziglang/zig@${ZIG_VERSION}"
)

# Function to verify signature if minisign is available
verify_signature() {
    local tarball="$1"
    local sig_file="$2"

    if [[ "$VERIFY_SIGNATURE" != "true" ]]; then
        echo "Skipping signature verification (disabled)"
        return 0
    fi

    # Check if minisign is available
    if ! command -v minisign >/dev/null 2>&1; then
        echo "WARNING: minisign not found, attempting to install it..."
        # Try to install minisign
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y minisign || {
                echo "WARNING: Could not install minisign, proceeding without signature verification"
                return 0
            }
        else
            echo "WARNING: Cannot install minisign, proceeding without signature verification"
            return 0
        fi
    fi

    # Create a temporary file with the public key
    echo "${PUBKEY}" > /tmp/zig.pub

    # Verify the signature
    if minisign -Vm "${tarball}" -P "${PUBKEY}" -x "${sig_file}" 2>/dev/null; then
        echo "Signature verification passed!"
        rm -f /tmp/zig.pub
        return 0
    else
        echo "ERROR: Signature verification failed!"
        rm -f /tmp/zig.pub
        return 1
    fi
}

# Function to try downloading from a URL
try_download() {
    local url="$1"
    local output="/tmp/${TARBALL_NAME}"
    local sig_output="/tmp/${SIGNATURE_NAME}"

    echo "Trying: ${url}..."
    if curl -fsSL --insecure --connect-timeout 10 --max-time 120 -o "${output}" "${url}" 2>/dev/null; then
        # Verify it's actually a tar.xz file
        if file "${output}" | grep -q "XZ compressed data"; then
            echo "Successfully downloaded tarball from ${url}"

            # Try to download signature
            local sig_url="${url}.minisig"
            if curl -fsSL --insecure --connect-timeout 5 --max-time 30 -o "${sig_output}" "${sig_url}" 2>/dev/null; then
                echo "Downloaded signature file"
                if verify_signature "${output}" "${sig_output}"; then
                    rm -f "${sig_output}"
                    return 0
                else
                    echo "Signature verification failed, trying another mirror"
                    rm -f "${output}" "${sig_output}"
                    return 1
                fi
            else
                echo "WARNING: Could not download signature file, proceeding without verification"
                rm -f "${sig_output}"
                return 0
            fi
        else
            echo "Downloaded file is not XZ compressed data"
            rm -f "${output}"
            return 1
        fi
    else
        echo "Failed to download from ${url}"
        return 1
    fi
}

# Try to fetch community mirrors
echo "Fetching community mirrors..."
if COMMUNITY_MIRRORS=$(curl -fsSL --insecure --connect-timeout 5 --max-time 10 https://ziglang.org/download/community-mirrors.txt 2>/dev/null); then
    while IFS= read -r mirror; do
        if [[ -n "$mirror" && "$mirror" != "#"* ]]; then
            MIRRORS+=("${mirror}/${ZIG_VERSION}")
        fi
    done <<< "$COMMUNITY_MIRRORS"
    echo "Added $(echo "$COMMUNITY_MIRRORS" | wc -l) community mirrors"
fi

# Try each mirror
DOWNLOAD_SUCCESS=false
for mirror in "${MIRRORS[@]}"; do
    if [[ "$mirror" == *github.com* ]]; then
        # GitHub releases have a different URL structure
        url="${mirror}/${TARBALL_NAME}"
    else
        url="${mirror}/${TARBALL_NAME}"
    fi

    if try_download "$url"; then
        DOWNLOAD_SUCCESS=true
        break
    fi
done

if [[ "$DOWNLOAD_SUCCESS" != "true" ]]; then
    echo "ERROR: Failed to download Zig from all mirrors"
    exit 1
fi

# Extract Zig
echo "Extracting Zig to ${INSTALL_DIR}..."
tar -xJf "/tmp/${TARBALL_NAME}" -C "${INSTALL_DIR}"
rm -f "/tmp/${TARBALL_NAME}"

# Find the extracted directory - format is zig-ARCH-OS-VERSION
ZIG_DIR=$(find "${INSTALL_DIR}" -maxdepth 1 -type d -name "zig-${ARCH}-${OS}-*" -o -name "zig-${OS}-${ARCH}-*" | head -n1)

if [[ -z "$ZIG_DIR" ]]; then
    echo "ERROR: Could not find extracted Zig directory"
    exit 1
fi

# Create symlink
ln -sf "${ZIG_DIR}/zig" /usr/local/bin/zig

# Verify installation
if zig version; then
    echo "Zig ${ZIG_VERSION} installed successfully!"
else
    echo "ERROR: Zig installation verification failed"
    exit 1
fi
