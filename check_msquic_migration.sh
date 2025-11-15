#!/bin/bash
# MsQuic Migration Status Check
# Verifies that the msquic migration is properly integrated

set -e

echo "==================================="
echo "MsQuic Migration Status Check"
echo "==================================="
echo ""

ERRORS=0

# Check 1: quic.zig uses msquic
echo "1. Checking src/transport/quic.zig..."
if grep -q "quic_msquic.zig" src/transport/quic.zig; then
    echo "   ✅ Using quic_msquic.zig"
else
    echo "   ❌ Not using quic_msquic.zig"
    ERRORS=$((ERRORS+1))
fi

# Check 2: msquic files exist
echo "2. Checking msquic implementation files..."
for file in src/transport/quic_msquic.zig src/transport/msquic_wrapper.zig src/transport/msquic_types.zig; do
    if [ -f "$file" ]; then
        echo "   ✅ $file exists"
    else
        echo "   ❌ $file missing"
        ERRORS=$((ERRORS+1))
    fi
done

# Check 3: Build succeeds
echo "3. Checking build..."
if zig build 2>&1 | tail -1 | grep -q "error"; then
    echo "   ❌ Build failed"
    ERRORS=$((ERRORS+1))
else
    echo "   ✅ Build successful"
fi

# Check 4: Binary exists
echo "4. Checking binary..."
if [ -f "zig-out/bin/geode" ]; then
    echo "   ✅ Binary exists"
else
    echo "   ❌ Binary missing"
    ERRORS=$((ERRORS+1))
fi

# Check 5: msquic linked
echo "5. Checking msquic linkage..."
if ldd zig-out/bin/geode 2>/dev/null | grep -q "libmsquic"; then
    echo "   ✅ msquic linked"
else
    echo "   ❌ msquic not linked"
    ERRORS=$((ERRORS+1))
fi

# Check 6: OpenSSL or crypto linked
echo "6. Checking crypto library linkage..."
if ldd zig-out/bin/geode 2>/dev/null | grep -qE "libssl|libcrypto|msquic"; then
    echo "   ✅ Crypto libraries linked (msquic includes crypto)"
else
    echo "   ⚠️  Crypto linkage unclear (msquic may bundle crypto)"
fi

# Check 7: Test script port
echo "7. Checking test script port..."
if grep -q "default=3141" test_msquic_protocol.py; then
    echo "   ✅ Test script uses port 3141"
else
    echo "   ⚠️  Test script port may be incorrect"
fi

# Check 8: Debug logging
echo "8. Checking debug logging..."
DEBUG_COUNT=$(grep -h "// DEBUG: std.debug.print" src/transport/msquic_wrapper.zig src/transport/quic_msquic.zig 2>/dev/null | wc -l || echo 0)
if [ "$DEBUG_COUNT" -gt 20 ]; then
    echo "   ✅ Debug logging commented out ($DEBUG_COUNT lines)"
else
    echo "   ⚠️  Debug logging count: $DEBUG_COUNT lines"
fi

echo ""
echo "==================================="
if [ $ERRORS -eq 0 ]; then
    echo "✅ All checks passed!"
    echo "Migration is properly integrated"
    echo "==================================="
    exit 0
else
    echo "❌ $ERRORS check(s) failed"
    echo "Migration may have issues"
    echo "==================================="
    exit 1
fi
