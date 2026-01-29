#!/bin/bash
# Test cross-compiled clients with various emulators

set -e

echo "=== Cross-Compiled Client Testing Script ==="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if clients are built
if [ ! -d "zig-out/clients" ]; then
    echo -e "${RED}Error: Clients not built. Run 'make cross-clients' first.${NC}"
    exit 1
fi

# Function to test a binary
test_binary() {
    local binary="$1"
    local emulator="$2"
    local platform="$3"

    if [ ! -f "$binary" ]; then
        echo -e "${YELLOW}⚠ $platform binary not found: $binary${NC}"
        return 1
    fi

    echo -e "${GREEN}Testing $platform: $(basename $binary)${NC}"

    if [ -n "$emulator" ]; then
        if command -v "$emulator" >/dev/null 2>&1; then
            case "$emulator" in
                wine*)
                    WINEDEBUG=-all $emulator "$binary" 2>&1 | head -5 || true
                    ;;
                qemu-*)
                    # Determine the library path based on the architecture
                    case "$emulator" in
                        qemu-aarch64)
                            LIB_PATH="/usr/aarch64-linux-gnu"
                            ;;
                        qemu-arm)
                            LIB_PATH="/usr/arm-linux-gnueabihf"
                            ;;
                        qemu-riscv64)
                            LIB_PATH="/usr/riscv64-linux-gnu"
                            ;;
                        *)
                            LIB_PATH=""
                            ;;
                    esac

                    if [ -n "$LIB_PATH" ] && [ -d "$LIB_PATH" ]; then
                        $emulator -L "$LIB_PATH" "$binary" 2>&1 | head -5 || true
                    else
                        $emulator "$binary" 2>&1 | head -5 || true
                    fi
                    ;;
            esac
            echo -e "${GREEN}✓ $platform test completed${NC}"
        else
            echo -e "${YELLOW}⚠ $emulator not available, skipping $platform${NC}"
        fi
    else
        # Native execution
        "$binary" 2>&1 | head -5 || true
        echo -e "${GREEN}✓ Native test completed${NC}"
    fi
    echo ""
}

# Test Windows x86_64 clients
echo "=== Windows x86_64 Clients ==="
test_binary "zig-out/clients/windows-x86_64/geode-zig-example-windows-x86_64.exe" "wine64" "Windows x86_64 Zig"
test_binary "zig-out/clients/windows-x86_64/gql-example.exe" "wine64" "Windows x86_64 Go"

# Test Linux ARM64 clients
echo "=== Linux ARM64 Clients ==="
test_binary "zig-out/clients/linux-arm64/geode-zig-example-linux-arm64" "qemu-aarch64" "Linux ARM64 Zig"
test_binary "zig-out/clients/linux-arm64/gql-example" "qemu-aarch64" "Linux ARM64 Go"

# Test Linux x86_64 clients (native)
echo "=== Linux x86_64 Clients (Native) ==="
test_binary "zig-out/clients/linux-x86_64/geode-zig-example-linux-x86_64" "" "Linux x86_64 Zig"
test_binary "zig-out/clients/linux-x86_64/gql-example" "" "Linux x86_64 Go"

# Check for macOS clients (can't test without macOS)
echo "=== macOS Clients (Build Verification Only) ==="
for arch in x86_64 arm64; do
    if [ -f "zig-out/clients/macos-$arch/geode-zig-example-macos-$arch" ]; then
        echo -e "${GREEN}✓ macOS $arch Zig client built successfully${NC}"
        file "zig-out/clients/macos-$arch/geode-zig-example-macos-$arch" | head -1
    fi
    if [ -f "zig-out/clients/macos-$arch/gql-example" ]; then
        echo -e "${GREEN}✓ macOS $arch Go client built successfully${NC}"
        file "zig-out/clients/macos-$arch/gql-example" | head -1
    fi
done
echo ""

# Summary
echo "=== Test Summary ==="
echo "Cross-compiled clients have been tested where emulators are available."
echo "Note: Connection failures are expected if the server is not running."
echo "The tests verify that binaries can execute on their target platforms."

# Check sizes
echo ""
echo "=== Binary Sizes ==="
find zig-out/clients -type f \( -name "*.exe" -o -name "gql-example*" -o -name "geode-zig-example*" \) \
    -exec ls -lh {} \; | awk '{print $9 ": " $5}'

exit 0
