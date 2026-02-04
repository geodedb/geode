#!/usr/bin/env bash
# Simple QUIC test for Geode (stdio server removed)

set -e

echo "=== Simple QUIC Test ==="

# Build first
make build > /dev/null 2>&1

SERVER_PORT=8452
ADMIN_USER="${GEODE_ADMIN_USERNAME:-geode}"
ADMIN_PASS="${GEODE_DEFAULT_PASSWORD:-geode-test-password}"
DATA_DIR=$(mktemp -d /tmp/geode_simple_quic_XXXXXX)
GEODE_ADMIN_USERNAME="${ADMIN_USER}" GEODE_DEFAULT_PASSWORD="${ADMIN_PASS}" \
    ./zig-out/bin/geode serve --listen 127.0.0.1:${SERVER_PORT} --data-dir "${DATA_DIR}" > /tmp/geode_simple_quic.log 2>&1 &
SERVER_PID=$!
sleep 2

cleanup() {
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
    rm -rf "${DATA_DIR}"
    rm -f /tmp/geode_simple_quic.log
}
trap cleanup EXIT

QUERY_CMD="./zig-out/bin/geode query --server 127.0.0.1:${SERVER_PORT} --insecure --user ${ADMIN_USER} --password ${ADMIN_PASS}"

echo "Test 1: Integer query"
output1=$(timeout 5 $QUERY_CMD "RETURN 1 AS num" 2>/dev/null | head -1)
if echo "$output1" | grep -q "\"num\":1"; then
    echo "✓ PASS: Integer query works"
else
    echo "✗ FAIL: Integer query failed"
    echo "Output: $output1"
    exit 1
fi

echo "Test 2: String literal query"
output2=$(timeout 5 $QUERY_CMD "RETURN \"hello\" AS greeting" 2>/dev/null | head -1)
if echo "$output2" | grep -q "\"greeting\":\"hello\""; then
    echo "✓ PASS: String literal query works"
else
    echo "✗ FAIL: String literal query failed"
    echo "Output: $output2"
    exit 1
fi

echo "Test 3: Invalid query surfaces error"
output3=$(timeout 5 $QUERY_CMD "RETURN" 2>&1 | head -1 || true)
if echo "$output3" | grep -q "ParseError\|error"; then
    echo "✓ PASS: Invalid query error reported"
else
    echo "✗ FAIL: Invalid query should report error"
    echo "Output: $output3"
    exit 1
fi

echo
echo "All QUIC tests passed."
