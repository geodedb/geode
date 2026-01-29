#!/bin/bash
# Robust Zig fetcher using community mirrors with proper verification
# Following official recommendations from ziglang.org

set -e

ZIG_VERSION="${1:-0.15.1}"
ARCH="${2:-x86_64}"
OS="${3:-linux}"
INSTALL_DIR="${4:-/opt}"

TARBALL_NAME="zig-${ARCH}-${OS}-${ZIG_VERSION}.tar.xz"
SIGNATURE_NAME="${TARBALL_NAME}.minisig"
PUBKEY="RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U"
SOURCE_ID="geode-docker-build"

echo "Fetching Zig ${ZIG_VERSION} for ${OS}-${ARCH}..."

# Function to shuffle array
shuffle_array() {
    local -n arr=$1
    local i j tmp
    for ((i=${#arr[@]}-1; i>0; i--)); do
        j=$((RANDOM % (i+1)))
        tmp=${arr[i]}
        arr[i]=${arr[j]}
        arr[j]=$tmp
    done
}

# Function to verify minisign signature
verify_signature() {
    local tarball="$1"
    local sig_file="$2"

    # Check if minisign is available
    if ! command -v minisign >/dev/null 2>&1; then
        echo "ERROR: minisign is required for signature verification"
        return 1
    fi

    # Verify the signature
    if minisign -Vm "${tarball}" -P "${PUBKEY}" -x "${sig_file}" 2>/dev/null; then
        echo "✓ Signature verification passed"
        return 0
    else
        echo "✗ Signature verification failed"
        return 1
    fi
}

# Function to try download from a mirror
try_mirror() {
    local mirror_url="$1"
    local tarball_path="/tmp/${TARBALL_NAME}"
    local sig_path="/tmp/${SIGNATURE_NAME}"

    echo "Trying mirror: ${mirror_url}"

    # Download tarball with source parameter
    if curl -fsSL --connect-timeout 10 --max-time 300 \
         -o "${tarball_path}" \
         "${mirror_url}/${TARBALL_NAME}?source=${SOURCE_ID}" 2>/dev/null; then

        # Verify it's actually XZ compressed data
        if ! file "${tarball_path}" | grep -q "XZ compressed data"; then
            echo "  ✗ Downloaded file is not valid XZ data"
            rm -f "${tarball_path}"
            return 1
        fi

        # Download signature (REQUIRED)
        if curl -fsSL --connect-timeout 5 --max-time 30 \
             -o "${sig_path}" \
             "${mirror_url}/${SIGNATURE_NAME}?source=${SOURCE_ID}" 2>/dev/null; then

            # Verify signature (REQUIRED)
            if verify_signature "${tarball_path}" "${sig_path}"; then
                echo "  ✓ Successfully downloaded and verified from ${mirror_url}"
                rm -f "${sig_path}"
                return 0
            else
                echo "  ✗ Signature verification failed - SECURITY RISK, skipping this mirror"
                rm -f "${tarball_path}" "${sig_path}"
                return 1
            fi
        else
            echo "  ✗ Could not download signature - skipping for security"
            rm -f "${tarball_path}"
            return 1
        fi
    else
        echo "  ✗ Failed to download tarball"
        return 1
    fi
}

# Main download logic
DOWNLOAD_SUCCESS=false

# First, try to get the community mirrors list
echo "Fetching community mirrors list..."
MIRRORS=()

if MIRROR_LIST=$(curl -fsSL --connect-timeout 5 --max-time 10 \
                      https://ziglang.org/download/community-mirrors.txt 2>/dev/null); then
    # Parse mirrors from the list
    while IFS= read -r line; do
        # Skip empty lines and comments (though spec says there shouldn't be any)
        if [[ -n "$line" && "$line" == https://* ]]; then
            # Append the version to the mirror URL
            MIRRORS+=("${line}/${ZIG_VERSION}")
        fi
    done <<< "$MIRROR_LIST"
    echo "Found ${#MIRRORS[@]} community mirrors"
else
    echo "Could not fetch community mirrors list, using fallback mirrors"
    # Fallback to known mirrors
    MIRRORS=(
        "https://pkg.machengine.org/zig/${ZIG_VERSION}"
        "https://mirror.bazel.build/ziglang.org/download/${ZIG_VERSION}"
        "https://github.com/ziglang/zig/releases/download/${ZIG_VERSION}"
    )
fi

# Add ziglang.org as final fallback
MIRRORS+=("https://ziglang.org/download/${ZIG_VERSION}")

# Shuffle mirrors for load distribution (except keep ziglang.org last)
LAST_MIRROR="${MIRRORS[-1]}"
unset 'MIRRORS[-1]'
shuffle_array MIRRORS
MIRRORS+=("$LAST_MIRROR")

# Try each mirror
for mirror in "${MIRRORS[@]}"; do
    if try_mirror "$mirror"; then
        DOWNLOAD_SUCCESS=true
        break
    fi
done

if [[ "$DOWNLOAD_SUCCESS" != "true" ]]; then
    echo "ERROR: Failed to download and verify Zig from all mirrors"
    exit 1
fi

# Extract and install Zig
echo "Installing Zig to ${INSTALL_DIR}..."
tar -xJf "/tmp/${TARBALL_NAME}" -C "${INSTALL_DIR}"
rm -f "/tmp/${TARBALL_NAME}"

# Find the extracted directory - format is zig-ARCH-OS-VERSION
ZIG_DIR=$(find "${INSTALL_DIR}" -maxdepth 1 -type d -name "zig-${ARCH}-${OS}-*" -o -name "zig-*" | head -n1)

if [[ -z "$ZIG_DIR" ]]; then
    echo "ERROR: Could not find extracted Zig directory"
    exit 1
fi

# Create symlink
ln -sf "${ZIG_DIR}/zig" /usr/local/bin/zig

# Verify installation
if zig version; then
    echo "✓ Zig ${ZIG_VERSION} installed successfully!"
else
    echo "ERROR: Zig installation verification failed"
    exit 1
fi
