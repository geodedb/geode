#!/usr/bin/env bash
# Test msquic integration standalone

set -e

MSQUIC_INCLUDE="/nix/store/wdyb7p8h2fpbrgli3i1czdxsib9bhfm5-libmsquic-2.5.4/include"
MSQUIC_LIB="/nix/store/wdyb7p8h2fpbrgli3i1czdxsib9bhfm5-libmsquic-2.5.4/lib"

echo "🔨 Building and running msquic wrapper test..."
zig test src/test_msquic.zig \
    -I"$MSQUIC_INCLUDE" \
    -L"$MSQUIC_LIB" \
    -lc \
    "$MSQUIC_LIB/libmsquic.so.2.5.4" \
    --library-directory src/transport \
    2>&1

echo "✅ Test completed successfully!"
