#!/bin/sh
# QUIC Integration Test Suite
# Tests critical QUIC fixes to prevent regression

set -e

echo "=== QUIC Integration Test Suite ==="
echo ""
ADMIN_USER="${GEODE_ADMIN_USERNAME:-geode}"
ADMIN_PASS="${GEODE_DEFAULT_PASSWORD:-Geode Test Admin Passphrase}"

# Test 1: Basic QUIC query execution
echo "Test 1: Basic QUIC query execution"
echo "Starting server..."
GEODE_ADMIN_USERNAME="${ADMIN_USER}" GEODE_DEFAULT_PASSWORD="${ADMIN_PASS}" \
    ./zig-out/bin/geode serve --listen 127.0.0.1:8443 > test_server.log 2>&1 &
SERVER_PID=$!
sleep 2

echo "Executing query..."
OUTPUT=$(./zig-out/bin/geode query --server 127.0.0.1:8443 --insecure --user "${ADMIN_USER}" --password "${ADMIN_PASS}" "RETURN 1 AS test" 2>&1 || true)

# Check for expected output
if echo "$OUTPUT" | grep -q "\"status_class\":\"00000\""; then
    echo "✓ Status received"
else
    echo "✗ Status missing"
    echo "$OUTPUT"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
fi

kill $SERVER_PID 2>/dev/null || true
echo "✓ Test 1 passed"
echo ""

# Test 2: Handshake timeout with unreachable server
echo "Test 2: Handshake timeout handling"
OUTPUT=$(timeout 3 ./zig-out/bin/geode query --server 127.0.0.1:19999 --insecure --user "${ADMIN_USER}" --password "${ADMIN_PASS}" "RETURN 1" 2>&1 || true)

if echo "$OUTPUT" | grep -q "QUIC handshake failed"; then
    echo "✓ Handshake timeout detected"
else
    echo "✗ Handshake timeout not properly handled"
    echo "$OUTPUT"
    exit 1
fi

if echo "$OUTPUT" | grep -q "Ensure the server is running"; then
    echo "✓ Helpful error message shown"
else
    echo "✗ Error message missing"
    echo "$OUTPUT"
    exit 1
fi

echo "✓ Test 2 passed"
echo ""

# Test 3: Multiple queries to same server (tests readStream fix)
echo "Test 3: Multiple sequential queries"
echo "Starting server..."
GEODE_ADMIN_USERNAME="${ADMIN_USER}" GEODE_DEFAULT_PASSWORD="${ADMIN_PASS}" \
    ./zig-out/bin/geode serve --listen 127.0.0.1:8444 > test_server2.log 2>&1 &
SERVER_PID=$!
sleep 2

QUERY1=$(./zig-out/bin/geode query --server 127.0.0.1:8444 --insecure --user "${ADMIN_USER}" --password "${ADMIN_PASS}" "RETURN 1 AS x" 2>&1 || true)
if echo "$QUERY1" | grep -q '"x":1'; then
    echo "✓ Query 1 successful"
else
    echo "✗ Query 1 failed"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
fi

QUERY2=$(./zig-out/bin/geode query --server 127.0.0.1:8444 --insecure --user "${ADMIN_USER}" --password "${ADMIN_PASS}" "RETURN 2 AS y" 2>&1 || true)
if echo "$QUERY2" | grep -q '"y":2'; then
    echo "✓ Query 2 successful"
else
    echo "✗ Query 2 failed"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
fi

QUERY3=$(./zig-out/bin/geode query --server 127.0.0.1:8444 --insecure --user "${ADMIN_USER}" --password "${ADMIN_PASS}" "RETURN 'test' AS z" 2>&1 || true)
if echo "$QUERY3" | grep -q '"z":"test"'; then
    echo "✓ Query 3 successful"
else
    echo "✗ Query 3 failed"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
fi

kill $SERVER_PID 2>/dev/null || true
echo "✓ Test 3 passed"
echo ""

# Test 4: Verify no excessive debug output
echo "Test 4: Debug output suppression"
echo "Starting server..."
GEODE_ADMIN_USERNAME="${ADMIN_USER}" GEODE_DEFAULT_PASSWORD="${ADMIN_PASS}" \
    ./zig-out/bin/geode serve --listen 127.0.0.1:8445 > test_server3.log 2>&1 &
SERVER_PID=$!
sleep 2

OUTPUT=$(./zig-out/bin/geode query --server 127.0.0.1:8445 --insecure --user "${ADMIN_USER}" --password "${ADMIN_PASS}" "RETURN 1" 2>&1 || true)

if echo "$OUTPUT" | grep -q "DEBUG: poll called"; then
    echo "✗ Verbose polling debug still present"
    exit 1
else
    echo "✓ Polling debug suppressed"
fi

if echo "$OUTPUT" | grep -q "DEBUG: readStream called"; then
    echo "✗ Verbose readStream debug still present"
    exit 1
else
    echo "✓ ReadStream debug suppressed"
fi

kill $SERVER_PID 2>/dev/null || true
echo "✓ Test 4 passed"
echo ""

echo "=== All QUIC integration tests passed ==="
echo ""
echo "Summary:"
echo "- ReadStream WouldBlock fix: ✓"
echo "- Handshake timeout handling: ✓"
echo "- Multiple query execution: ✓"
echo "- Debug output cleanup: ✓"
