#!/bin/bash
set -euo pipefail
# Generate APT Repository Metadata
# Creates Packages, Release, and InRelease files for a Debian repository
#
# Usage:
#   ./generate-apt-repo.sh <dist_directory> <output_directory> [--sign]
#
# This creates a simple APT repository structure:
#   <output>/dists/stable/main/binary-amd64/
#   <output>/dists/stable/main/binary-arm64/
#   <output>/pool/main/g/geode/
#
# Environment variables:
#   GPG_KEY_ID          - GPG key ID for signing (required with --sign)

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

DIST_DIR=""
OUTPUT_DIR=""
SIGN_REPO=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --sign)
            SIGN_REPO=true
            shift
            ;;
        --help)
            echo "Usage: $0 <dist_directory> <output_directory> [--sign]"
            exit 0
            ;;
        *)
            if [[ -z "$DIST_DIR" ]]; then
                DIST_DIR="$1"
            else
                OUTPUT_DIR="$1"
            fi
            shift
            ;;
    esac
done

if [[ -z "$DIST_DIR" || -z "$OUTPUT_DIR" ]]; then
    log_error "Both dist_directory and output_directory are required"
    exit 1
fi

# Repository configuration
REPO_ORIGIN="CodePros"
REPO_LABEL="Geode"
REPO_SUITE="stable"
REPO_CODENAME="stable"
REPO_DESCRIPTION="Geode Graph Database APT Repository"
REPO_ARCHITECTURES="amd64 arm64 armhf riscv64"

# Create directory structure
log_info "Creating APT repository structure..."
mkdir -p "$OUTPUT_DIR/dists/$REPO_SUITE/main/binary-amd64"
mkdir -p "$OUTPUT_DIR/dists/$REPO_SUITE/main/binary-arm64"
mkdir -p "$OUTPUT_DIR/dists/$REPO_SUITE/main/binary-armhf"
mkdir -p "$OUTPUT_DIR/dists/$REPO_SUITE/main/binary-riscv64"
mkdir -p "$OUTPUT_DIR/pool/main/g/geode"

# Copy .deb files to pool
log_info "Copying packages to pool..."
for deb in "$DIST_DIR"/*.deb; do
    [[ -f "$deb" ]] || continue
    cp "$deb" "$OUTPUT_DIR/pool/main/g/geode/"
    log_info "  Copied: $(basename "$deb")"
done

# Map nFPM architecture names to Debian architecture names
map_arch() {
    case "$1" in
        *x86_64*|*amd64*) echo "amd64" ;;
        *arm64*|*aarch64*) echo "arm64" ;;
        *armhf*|*arm-linux*) echo "armhf" ;;
        *riscv64*) echo "riscv64" ;;
        *) echo "" ;;
    esac
}

# Generate Packages files for each architecture
log_info "Generating Packages files..."
for arch in amd64 arm64 armhf riscv64; do
    PACKAGES_FILE="$OUTPUT_DIR/dists/$REPO_SUITE/main/binary-$arch/Packages"
    > "$PACKAGES_FILE"

    for deb in "$OUTPUT_DIR"/pool/main/g/geode/*.deb; do
        [[ -f "$deb" ]] || continue

        # Get architecture from filename
        filename=$(basename "$deb")
        pkg_arch=$(map_arch "$filename")

        if [[ "$pkg_arch" == "$arch" ]]; then
            log_info "  Processing: $filename for $arch"

            # Extract package info
            dpkg-deb -I "$deb" control 2>/dev/null > /tmp/control_$$ || continue

            # Add package info to Packages file
            cat /tmp/control_$$

            # Add additional fields
            SIZE=$(stat -c%s "$deb")
            MD5=$(md5sum "$deb" | awk '{print $1}')
            SHA1=$(sha1sum "$deb" | awk '{print $1}')
            SHA256=$(sha256sum "$deb" | awk '{print $1}')

            echo "Filename: pool/main/g/geode/$filename"
            echo "Size: $SIZE"
            echo "MD5sum: $MD5"
            echo "SHA1: $SHA1"
            echo "SHA256: $SHA256"
            echo ""

            rm -f /tmp/control_$$
        fi
    done >> "$PACKAGES_FILE"

    # Create compressed versions
    gzip -k -f "$PACKAGES_FILE"
    xz -k -f "$PACKAGES_FILE" 2>/dev/null || true

    log_info "  Created: dists/$REPO_SUITE/main/binary-$arch/Packages"
done

# Generate Release file
log_info "Generating Release file..."
RELEASE_FILE="$OUTPUT_DIR/dists/$REPO_SUITE/Release"

cat > "$RELEASE_FILE" <<EOF
Origin: $REPO_ORIGIN
Label: $REPO_LABEL
Suite: $REPO_SUITE
Codename: $REPO_CODENAME
Architectures: $REPO_ARCHITECTURES
Components: main
Description: $REPO_DESCRIPTION
Date: $(date -Ru)
EOF

# Add checksums
echo "MD5Sum:" >> "$RELEASE_FILE"
for file in $(find "$OUTPUT_DIR/dists/$REPO_SUITE" -type f \( -name "Packages*" -o -name "Release" \) | sort); do
    [[ "$file" == "$RELEASE_FILE" ]] && continue
    SIZE=$(stat -c%s "$file")
    MD5=$(md5sum "$file" | awk '{print $1}')
    RELPATH=${file#$OUTPUT_DIR/dists/$REPO_SUITE/}
    printf " %s %16d %s\n" "$MD5" "$SIZE" "$RELPATH" >> "$RELEASE_FILE"
done

echo "SHA1:" >> "$RELEASE_FILE"
for file in $(find "$OUTPUT_DIR/dists/$REPO_SUITE" -type f \( -name "Packages*" -o -name "Release" \) | sort); do
    [[ "$file" == "$RELEASE_FILE" ]] && continue
    SIZE=$(stat -c%s "$file")
    SHA1=$(sha1sum "$file" | awk '{print $1}')
    RELPATH=${file#$OUTPUT_DIR/dists/$REPO_SUITE/}
    printf " %s %16d %s\n" "$SHA1" "$SIZE" "$RELPATH" >> "$RELEASE_FILE"
done

echo "SHA256:" >> "$RELEASE_FILE"
for file in $(find "$OUTPUT_DIR/dists/$REPO_SUITE" -type f \( -name "Packages*" -o -name "Release" \) | sort); do
    [[ "$file" == "$RELEASE_FILE" ]] && continue
    SIZE=$(stat -c%s "$file")
    SHA256=$(sha256sum "$file" | awk '{print $1}')
    RELPATH=${file#$OUTPUT_DIR/dists/$REPO_SUITE/}
    printf " %s %16d %s\n" "$SHA256" "$SIZE" "$RELPATH" >> "$RELEASE_FILE"
done

log_info "Generated Release file"

# Sign Release file if requested
if $SIGN_REPO; then
    if [[ -z "${GPG_KEY_ID:-}" ]]; then
        log_error "GPG_KEY_ID required for signing"
        exit 1
    fi

    log_info "Signing Release file..."

    # Create detached signature (Release.gpg)
    gpg --armor --detach-sign --default-key "$GPG_KEY_ID" \
        -o "$OUTPUT_DIR/dists/$REPO_SUITE/Release.gpg" \
        "$RELEASE_FILE"

    # Create inline signature (InRelease)
    gpg --clearsign --default-key "$GPG_KEY_ID" \
        -o "$OUTPUT_DIR/dists/$REPO_SUITE/InRelease" \
        "$RELEASE_FILE"

    log_info "Created signed Release.gpg and InRelease"
fi

# Copy public key to repository root
if [[ -f "$DIST_DIR/geode-apt-signing-key.gpg" ]]; then
    cp "$DIST_DIR/geode-apt-signing-key.gpg" "$OUTPUT_DIR/"
    log_info "Copied public key to repository"
fi
if [[ -f "$DIST_DIR/geode-archive-keyring.gpg" ]]; then
    cp "$DIST_DIR/geode-archive-keyring.gpg" "$OUTPUT_DIR/"
fi

echo ""
log_info "APT repository generated successfully!"
echo ""
echo "Repository structure:"
find "$OUTPUT_DIR" -type f | sort | head -30
echo ""
echo "To use this repository:"
echo ""
echo "  # Add GPG key"
echo "  curl -fsSL https://YOUR_DOMAIN/geode-apt-signing-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/geode-archive-keyring.gpg"
echo ""
echo "  # Add repository"
echo "  echo \"deb [signed-by=/usr/share/keyrings/geode-archive-keyring.gpg] https://YOUR_DOMAIN/ stable main\" | sudo tee /etc/apt/sources.list.d/geode.list"
echo ""
echo "  # Install"
echo "  sudo apt update && sudo apt install geode"
