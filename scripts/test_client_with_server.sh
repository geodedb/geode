#!/bin/bash
# Test client with automatic server management

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Configuration
SERVER_PORT=3141
SERVER_BIN="./zig-out/bin/geode"
TEST_SCRIPT="$1"
WAIT_TIME=3

# Cleanup function
cleanup() {
    if [ -n "$SERVER_PID" ]; then
        echo "Stopping server (PID $SERVER_PID)..."
        kill $SERVER_PID 2>/dev/null || true
        wait $SERVER_PID 2>/dev/null || true
    fi
}

trap cleanup EXIT

# Check if server binary exists
if [ ! -x "$SERVER_BIN" ]; then
    echo "❌ Error: Server binary not found at $SERVER_BIN"
    echo "Run 'make build' first"
    exit 1
fi

# Check if test script exists
if [ ! -f "$TEST_SCRIPT" ]; then
    echo "❌ Error: Test script not found: $TEST_SCRIPT"
    exit 1
fi

# Check if port is already in use
if netstat -tuln 2>/dev/null | grep -q ":$SERVER_PORT "; then
    echo "⚠ Warning: Port $SERVER_PORT is already in use"
    echo "Attempting to use existing server..."
    sleep 1
else
    # Start server in background
    echo "Starting server on port $SERVER_PORT..."
    DATA_DIR=$(mktemp -d)
    $SERVER_BIN serve --data-dir "$DATA_DIR" --listen "0.0.0.0:$SERVER_PORT" > /tmp/geode_test_server.log 2>&1 &
    SERVER_PID=$!

    echo "Server started (PID $SERVER_PID), waiting ${WAIT_TIME}s for initialization..."
    sleep $WAIT_TIME

    # Check if server is still running
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        echo "❌ Error: Server failed to start"
        cat /tmp/geode_test_server.log
        exit 1
    fi

    echo "✓ Server is running"
fi

# Run the test
echo "Running test: $TEST_SCRIPT"
python3 "$TEST_SCRIPT"
TEST_EXIT=$?

if [ $TEST_EXIT -eq 0 ]; then
    echo "✓ Test passed"
else
    echo "❌ Test failed with exit code $TEST_EXIT"
    if [ -f /tmp/geode_test_server.log ]; then
        echo "=== Server log ==="
        tail -50 /tmp/geode_test_server.log
    fi
fi

exit $TEST_EXIT
