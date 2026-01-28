#!/usr/bin/env bash
set -euo pipefail

# Geode Dependency Installation Script
# Installs all required system dependencies including msquic

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Geode Dependency Installation ==="
echo "Project root: $PROJECT_ROOT"
echo ""

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: This script should not be run as root"
    echo "Please run as a regular user with sudo access"
    exit 1
fi

# Update package lists
echo "→ Updating package lists..."
sudo apt-get update

# Install prerequisite packages
echo "→ Installing prerequisite packages..."
sudo apt-get install -y \
    wget \
    apt-transport-https \
    software-properties-common \
    build-essential \
    git \
    curl

# Get Ubuntu version
source /etc/os-release
echo "→ Detected Ubuntu version: $VERSION_ID"

# CANARY: REQ=REQ-BUILD-DEPS-001; FEATURE="DepsFallback"; ASPECT=UbuntuVersionFallback; STATUS=IMPL; OWNER=build; UPDATED=2026-01-28
# Issue #381: Handle newer Ubuntu versions that may not have Microsoft packages yet
# Microsoft typically supports LTS releases; fallback to latest supported version
MS_UBUNTU_VERSION="$VERSION_ID"
MS_SUPPORTED_VERSIONS=("24.04" "22.04" "20.04")

# Check if Microsoft has packages for this Ubuntu version
check_ms_packages() {
    local ver=$1
    wget -q --spider "https://packages.microsoft.com/config/ubuntu/$ver/packages-microsoft-prod.deb" 2>/dev/null
    return $?
}

if ! check_ms_packages "$MS_UBUNTU_VERSION"; then
    echo "⚠ Microsoft packages not available for Ubuntu $MS_UBUNTU_VERSION"
    echo "  Checking for fallback versions..."

    for fallback_ver in "${MS_SUPPORTED_VERSIONS[@]}"; do
        if check_ms_packages "$fallback_ver"; then
            echo "  → Using Microsoft repository for Ubuntu $fallback_ver (fallback)"
            MS_UBUNTU_VERSION="$fallback_ver"
            break
        fi
    done

    if [ "$MS_UBUNTU_VERSION" = "$VERSION_ID" ]; then
        echo "⚠ WARNING: No supported Microsoft repository found"
        echo "  libmsquic may not be installable via apt"
        echo "  Geode will use vendored QUIC implementation instead"
        MS_UBUNTU_VERSION=""
    fi
fi

# Check if Microsoft repository is already configured
if [ -n "$MS_UBUNTU_VERSION" ] && ! grep -q "packages.microsoft.com" /etc/apt/sources.list.d/* 2>/dev/null; then
    echo "→ Configuring Microsoft package repository (Ubuntu $MS_UBUNTU_VERSION)..."

    # Download Microsoft repository keys
    wget -q "https://packages.microsoft.com/config/ubuntu/$MS_UBUNTU_VERSION/packages-microsoft-prod.deb"

    # Register the Microsoft repository
    sudo dpkg -i packages-microsoft-prod.deb

    # Clean up
    rm packages-microsoft-prod.deb

    # Update package lists again
    sudo apt-get update

    echo "✓ Microsoft repository configured"
elif [ -n "$MS_UBUNTU_VERSION" ]; then
    echo "✓ Microsoft repository already configured"
fi

# Install libmsquic (if Microsoft repository is configured)
if [ -n "$MS_UBUNTU_VERSION" ]; then
    if ! dpkg -l | grep -q "^ii.*libmsquic"; then
        echo "→ Installing libmsquic..."
        if sudo apt-get install -y libmsquic 2>/dev/null; then
            echo "✓ libmsquic installed"
        else
            echo "⚠ libmsquic installation failed"
            echo "  Geode will use vendored QUIC implementation instead"
        fi
    else
        echo "✓ libmsquic already installed"
    fi
else
    echo "→ Skipping libmsquic (Microsoft repository not available)"
    echo "  Geode will use vendored QUIC implementation instead"
fi

# Verify libmsquic installation (only if MS packages were configured)
if [ -n "$MS_UBUNTU_VERSION" ]; then
    if ldconfig -p | grep -q libmsquic; then
        MSQUIC_PATH=$(ldconfig -p | grep libmsquic | head -1 | awk '{print $NF}')
        echo "✓ libmsquic found at: $MSQUIC_PATH"

        # Create development symlink (Ubuntu package doesn't include it)
        if [ ! -e /usr/lib/x86_64-linux-gnu/libmsquic.so ]; then
            # Find the actual versioned library
            MSQUIC_LIB=$(find /usr/lib/x86_64-linux-gnu -name 'libmsquic.so.*' 2>/dev/null | head -1)
            if [ -n "$MSQUIC_LIB" ]; then
                MSQUIC_BASENAME=$(basename "$MSQUIC_LIB")
                echo "→ Creating libmsquic.so development symlink..."
                sudo ln -sf "$MSQUIC_BASENAME" /usr/lib/x86_64-linux-gnu/libmsquic.so
                echo "✓ Development symlink created"
            fi
        else
            echo "✓ Development symlink already exists"
        fi
    else
        echo "⚠ WARNING: libmsquic installed but not found in ldconfig cache"
        echo "  Run: sudo ldconfig"
    fi
fi

# Install Zig if not present
if ! command -v zig &> /dev/null; then
    echo "→ Installing Zig..."
    # Note: User should install Zig from https://ziglang.org/download/
    echo "⚠ Zig not found. Please install Zig 0.15.1+ from https://ziglang.org/download/"
else
    ZIG_VERSION=$(zig version)
    echo "✓ Zig version: $ZIG_VERSION"
fi

# Install Rust if not present (for Rust client)
if ! command -v rustc &> /dev/null; then
    echo "→ Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
    echo "✓ Rust installed"
else
    RUST_VERSION=$(rustc --version)
    echo "✓ Rust version: $RUST_VERSION"
fi

# Install Python dependencies
if ! command -v python3 &> /dev/null; then
    echo "→ Installing Python 3..."
    sudo apt-get install -y python3 python3-pip python3-venv
else
    PYTHON_VERSION=$(python3 --version)
    echo "✓ Python version: $PYTHON_VERSION"
fi

# Install Go if not present (for Go client)
if ! command -v go &> /dev/null; then
    echo "→ Installing Go..."
    echo "⚠ Go not found. Please install Go 1.21+ from https://go.dev/dl/"
else
    GO_VERSION=$(go version)
    echo "✓ Go version: $GO_VERSION"
fi

# Install OpenSSL development files (required for building)
echo "→ Installing OpenSSL development files..."
sudo apt-get install -y libssl-dev

# Configure QUIC performance optimizations
echo ""
echo "=== Configuring QUIC Performance Optimizations ==="
echo ""

# Increase UDP buffer sizes for high-throughput QUIC transfers
RMEM_MAX=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "0")
WMEM_MAX=$(sysctl -n net.core.wmem_max 2>/dev/null || echo "0")

if [ "$RMEM_MAX" -lt 7340032 ] 2>/dev/null; then
    echo "→ Increasing net.core.rmem_max to 7340032 (7MB)..."
    sudo sysctl -w net.core.rmem_max=7340032
    echo "✓ UDP receive buffer max increased"
else
    echo "✓ net.core.rmem_max already >= 7MB ($RMEM_MAX)"
fi

if [ "$WMEM_MAX" -lt 7340032 ] 2>/dev/null; then
    echo "→ Increasing net.core.wmem_max to 7340032 (7MB)..."
    sudo sysctl -w net.core.wmem_max=7340032
    echo "✓ UDP send buffer max increased"
else
    echo "✓ net.core.wmem_max already >= 7MB ($WMEM_MAX)"
fi

# Persist sysctl settings
SYSCTL_CONF="/etc/sysctl.d/99-geode-quic.conf"
if [ ! -f "$SYSCTL_CONF" ]; then
    echo "→ Creating persistent sysctl configuration..."
    sudo tee "$SYSCTL_CONF" > /dev/null << 'EOF'
# Geode QUIC Performance Optimizations
# Increase UDP buffer sizes for high-throughput QUIC transfers
# These settings allow quic-go to use larger buffers, improving performance
# on high-bandwidth connections.

# Maximum receive socket buffer size (7MB)
net.core.rmem_max=7340032

# Maximum send socket buffer size (7MB)
net.core.wmem_max=7340032
EOF
    echo "✓ Persistent sysctl configuration created at $SYSCTL_CONF"
else
    echo "✓ Persistent sysctl configuration already exists"
fi

echo ""
echo "=== Dependency Installation Complete ==="
echo ""
echo "Installed components:"
echo "  • libmsquic (Microsoft QUIC library)"
echo "  • Build tools and prerequisites"
echo "  • OpenSSL development files"
echo ""
echo "QUIC Performance Optimizations:"
echo "  • UDP buffer sizes increased to 7MB (net.core.rmem_max, net.core.wmem_max)"
echo "  • Generic Segmentation Offload (GSO) enabled automatically on Linux 4.18+"
echo "  • Path MTU Discovery (DPLPMTUD) enabled by default"
echo ""
echo "Note: To disable GSO (not recommended), set QUIC_GO_DISABLE_GSO=true"
echo ""
echo "Next steps:"
echo "  1. Run 'make build' to build Geode"
echo "  2. The build will automatically link against system libmsquic"
echo ""
