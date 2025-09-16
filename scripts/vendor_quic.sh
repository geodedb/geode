#!/usr/bin/env bash
# Vendor QUIC library from nix store for development

set -euo pipefail

VENDOR_DIR="vendor/quic"
QUIC_STORE_PATH=""

# Find the QUIC package in nix store
echo "Finding QUIC package in nix store..."
QUIC_STORE_PATH=$(nix build github:spyderorg/quic --print-out-paths 2>/dev/null || echo "")

if [ -z "$QUIC_STORE_PATH" ]; then
    echo "Error: Could not find QUIC package in nix store"
    echo "Try running: nix build github:spyderorg/quic"
    exit 1
fi

echo "Found QUIC package at: $QUIC_STORE_PATH"

# Create vendor directory
mkdir -p "$VENDOR_DIR"

# Copy QUIC library files
echo "Vendoring QUIC library to $VENDOR_DIR..."
cp -r "$QUIC_STORE_PATH/src" "$VENDOR_DIR/"
cp "$QUIC_STORE_PATH/quic.zig" "$VENDOR_DIR/"
cp "$QUIC_STORE_PATH/build.zig" "$VENDOR_DIR/build.zig.example" 2>/dev/null || true
cp "$QUIC_STORE_PATH/build.zig.zon" "$VENDOR_DIR/build.zig.zon.example" 2>/dev/null || true

# Make files writable for development
chmod -R +w "$VENDOR_DIR"

# Fix known compatibility issues with Zig 0.15.1
echo "Applying Zig 0.15.1 compatibility fixes..."
# Fix the encode method call issue
sed -i 's/const enc = try VarInt{ .value = u.type_value }.encode(&buf);/const v = VarInt{ .value = u.type_value }; const enc = try v.encode(\&buf);/' "$VENDOR_DIR/quic.zig" 2>/dev/null || true

# Create a wrapper module that exports the QUIC library
cat > "$VENDOR_DIR/lib.zig" << 'EOF'
// Wrapper module for vendored QUIC library
pub usingnamespace @import("quic.zig");

// Re-export commonly used types
pub const Connection = @import("src/quic/connection.zig").Connection;
pub const Stream = @import("src/quic/stream.zig").Stream;
pub const Listener = @import("src/quic/listener.zig").Listener;
pub const Config = @import("src/quic/config.zig").Config;
pub const TlsConfig = @import("src/quic/tls.zig").TlsConfig;
EOF

echo "QUIC library vendored successfully!"
echo ""
echo "To use in your Zig project:"
echo "  1. Add to build.zig:"
echo "     const quic_mod = b.createModule(.{ .root_source_file = b.path(\"vendor/quic/lib.zig\") });"
echo "     exe.root_module.addImport(\"quic\", quic_mod);"
echo "  2. Import in your code:"
echo "     const quic = @import(\"quic\");"
echo ""
echo "Vendor directory contents:"
ls -la "$VENDOR_DIR/"