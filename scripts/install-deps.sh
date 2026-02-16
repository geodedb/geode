#!/usr/bin/env bash
set -euo pipefail

# Geode Dependency Installation Script
# Installs all required system dependencies for building Geode
# Note: Geode uses a vendored QUIC library (build.zig.zon) - libmsquic is NOT required

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

# Get OS version for informational purposes
source /etc/os-release
echo "→ Detected OS: $PRETTY_NAME"

# CANARY: REQ=REQ-BUILD-DEPS-001; FEATURE="DepsFallback"; ASPECT=UbuntuVersionFallback; STATUS=IMPL; OWNER=build; UPDATED=2026-02-10
# Issue #381: libmsquic removed as a dependency - Geode uses vendored QUIC (build.zig.zon)
# The Microsoft QUIC library (libmsquic) is no longer needed because:
#   1. build.zig does not link against it
#   2. build.zig.zon declares a vendored QUIC dependency from gitlab.com/devnw/zig/quic
#   3. The libmsquic package is unavailable on newer Ubuntu versions (e.g., 25.10)
echo "→ QUIC: using vendored implementation (libmsquic not required)"

# Install Zig if not present
if ! command -v zig &> /dev/null; then
    echo "→ Installing Zig via zvm (https://zig.sh)..."
    GEODE_ZIG_VERSION="${GEODE_ZIG_VERSION:-0.15.2}"
    sudo apt-get install -y jq xz-utils tar
    curl -fsSL https://zig.sh/install.sh | bash
    export PATH="$HOME/bin:$PATH"
    eval "$(zvm env)"
    zvm install "$GEODE_ZIG_VERSION"
    zvm use "$GEODE_ZIG_VERSION"
    echo "✓ Zig version: $(zig version)"
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
echo "  • Build tools and prerequisites"
echo "  • OpenSSL development files"
echo "  • QUIC: vendored implementation (no system libmsquic needed)"
echo ""
echo "QUIC Performance Optimizations:"
echo "  • UDP buffer sizes increased to 7MB (net.core.rmem_max, net.core.wmem_max)"
echo "  • Generic Segmentation Offload (GSO) enabled automatically on Linux 4.18+"
echo "  • Path MTU Discovery (DPLPMTUD) enabled by default"
echo ""
echo "Next steps:"
echo "  1. Run 'make build' to build Geode"
echo ""
