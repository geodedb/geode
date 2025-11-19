#!/bin/bash
set -e  # Exit on error

echo "=================================="
echo "MsQuic Upgrade Script"
echo "=================================="
echo ""

# Step 1: Backup current configuration
echo "[1/6] Backing up current MsQuic configuration..."
sudo ldconfig -p | grep msquic > /tmp/msquic_old_libs.txt || true
echo "✓ Backup saved to /tmp/msquic_old_libs.txt"

# Step 2: Remove old package
echo ""
echo "[2/6] Removing old MsQuic package (v2.4.16)..."
sudo apt-get remove -y libmsquic libmsquic-dev 2>/dev/null || true
echo "✓ Old package removed"

# Step 3: Install dependencies (if missing)
echo ""
echo "[3/6] Installing build dependencies..."
sudo apt-get install -y cmake build-essential git libssl-dev libnuma-dev pkg-config >/dev/null 2>&1
echo "✓ Dependencies installed"

# Step 4: Clone and build MsQuic
echo ""
echo "[4/6] Building MsQuic from source (this will take 10-20 minutes)..."
cd /tmp
rm -rf msquic 2>/dev/null || true
git clone --quiet --recursive https://github.com/microsoft/msquic.git
cd msquic

# Get latest stable release
LATEST_TAG=$(git describe --tags `git rev-list --tags --max-count=1`)
echo "    Checking out latest stable: $LATEST_TAG"
git checkout $LATEST_TAG >/dev/null 2>&1

mkdir -p build && cd build
echo "    Configuring build..."
cmake -G 'Unix Makefiles' -DCMAKE_BUILD_TYPE=Release -DQUIC_TLS=openssl .. >/dev/null 2>&1

echo "    Building (this takes time, please wait)..."
cmake --build . --config Release -j$(nproc) >/dev/null 2>&1

# Step 5: Install
echo ""
echo "[5/6] Installing MsQuic system-wide..."
sudo cmake --install . >/dev/null 2>&1
sudo ldconfig
echo "✓ MsQuic installed"

# Step 6: Verify installation
echo ""
echo "[6/6] Verifying installation..."
if ldconfig -p | grep -q "libmsquic.so"; then
    echo "✓ MsQuic successfully installed:"
    ldconfig -p | grep msquic
else
    echo "✗ Installation verification failed"
    exit 1
fi

echo ""
echo "=================================="
echo "MsQuic Upgrade Complete!"
echo "=================================="
echo ""
echo "Next steps:"
echo "1. Rebuild geode: make clean && make build"
echo "2. Run tests: cd clients/test-harness && make test-with-coverage"
echo ""

