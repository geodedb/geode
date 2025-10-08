#!/bin/bash
set -e

echo "=========================================="
echo "QUIC Comprehensive Test Suite"
echo "=========================================="
echo ""

# Ensure clean state
pkill -9 geode 2>/dev/null || true
sleep 1

# Start geode server
echo "Starting Geode server..."
../zig-out/bin/geode serve --listen 127.0.0.1:3141 > server.log 2>&1 &
if [ ! -f "../zig-out/bin/geode" ]; then
    # Try from current directory
    ./zig-out/bin/geode serve --listen 127.0.0.1:3141 > server.log 2>&1 &
fi
SERVER_PID=$!

# Wait for server to start
echo "Waiting for server to initialize..."
sleep 3

# Check if server is running
if ! ps -p $SERVER_PID > /dev/null; then
    echo "❌ Server failed to start"
    cat server.log
    exit 1
fi

echo "✅ Server started (PID: $SERVER_PID)"
echo ""

# Run comprehensive tests
echo "Running comprehensive QUIC tests..."
if go run comprehensive_quic.go; then
    TEST_RESULT=0
else
    TEST_RESULT=$?
fi

# Cleanup
echo ""
echo "Cleaning up..."
kill -9 $SERVER_PID 2>/dev/null || true
pkill -9 geode 2>/dev/null || true

if [ $TEST_RESULT -eq 0 ]; then
    echo ""
    echo "=========================================="
    echo "✅ ALL TESTS PASSED"
    echo "=========================================="
    exit 0
else
    echo ""
    echo "=========================================="
    echo "❌ TESTS FAILED"
    echo "=========================================="
    echo ""
    echo "Server log:"
    tail -100 server.log
    exit $TEST_RESULT
fi
