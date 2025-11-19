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

# Check if Microsoft repository is already configured
if ! grep -q "packages.microsoft.com" /etc/apt/sources.list.d/* 2>/dev/null; then
    echo "→ Configuring Microsoft package repository..."

    # Download Microsoft repository keys
    wget -q "https://packages.microsoft.com/config/ubuntu/$VERSION_ID/packages-microsoft-prod.deb"

    # Register the Microsoft repository
    sudo dpkg -i packages-microsoft-prod.deb

    # Clean up
    rm packages-microsoft-prod.deb

    # Update package lists again
    sudo apt-get update

    echo "✓ Microsoft repository configured"
else
    echo "✓ Microsoft repository already configured"
fi

# Install libmsquic
if ! dpkg -l | grep -q "^ii.*libmsquic"; then
    echo "→ Installing libmsquic..."
    sudo apt-get install -y libmsquic
    echo "✓ libmsquic installed"
else
    echo "✓ libmsquic already installed"
fi

# Verify libmsquic installation
if ldconfig -p | grep -q libmsquic; then
    MSQUIC_PATH=$(ldconfig -p | grep libmsquic | head -1 | awk '{print $NF}')
    echo "✓ libmsquic found at: $MSQUIC_PATH"
else
    echo "⚠ WARNING: libmsquic installed but not found in ldconfig cache"
    echo "  Run: sudo ldconfig"
fi

# Create development symlink (Ubuntu package doesn't include it)
if [ ! -e /usr/lib/x86_64-linux-gnu/libmsquic.so ]; then
    echo "→ Creating libmsquic.so development symlink..."
    sudo ln -sf libmsquic.so.2.4.16 /usr/lib/x86_64-linux-gnu/libmsquic.so
    echo "✓ Development symlink created"
else
    echo "✓ Development symlink already exists"
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

echo ""
echo "=== Dependency Installation Complete ==="
echo ""
echo "Installed components:"
echo "  • libmsquic (Microsoft QUIC library)"
echo "  • Build tools and prerequisites"
echo "  • OpenSSL development files"
echo ""
echo "Next steps:"
echo "  1. Run 'make build' to build Geode"
echo "  2. The build will automatically link against system libmsquic"
echo ""
