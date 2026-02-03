#!/usr/bin/env bash
# Regression test for TLS handshake issues

set -e

echo "=== TLS Handshake Regression Test ==="
echo

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASSED=0
FAILED=0

# Build first
echo "Building Geode..."
make build > /dev/null 2>&1 || { echo -e "${RED}Build failed${NC}"; exit 1; }

echo "Starting server..."
# Generate self-signed certificate
mkdir -p /tmp/test-certs
openssl req -x509 -newkey rsa:2048 -keyout /tmp/test-certs/server.key -out /tmp/test-certs/server.crt -days 1 -nodes -subj "/CN=localhost" 2>/dev/null

# Start server with test certificates
./zig-out/bin/geode serve --listen-quic 0.0.0.0:8443 --cert /tmp/test-certs/server.crt --key /tmp/test-certs/server.key > /tmp/server.log 2>&1 &
SERVER_PID=$!
sleep 2

echo
echo "Test 1: Connection with --insecure flag (should work)"
if timeout 5 ./zig-out/bin/geode query 'RETURN 1 AS x' --server 127.0.0.1:8443 --insecure 2>/dev/null | grep -q '"x":1'; then
    echo -e "${GREEN}PASS${NC} - Insecure connection works"
    ((PASSED++))
else
    echo -e "${RED}FAIL${NC} - Insecure connection failed"
    ((FAILED++))
fi

echo "Test 2: Multiple sequential insecure connections"
SUCCESS=true
for i in {1..5}; do
    if ! timeout 5 ./zig-out/bin/geode query "RETURN $i AS n" --server 127.0.0.1:8443 --insecure 2>/dev/null | grep -q "\"n\":$i"; then
        SUCCESS=false
        break
    fi
done

if [ "$SUCCESS" = true ]; then
    echo -e "${GREEN}PASS${NC} - Multiple connections work"
    ((PASSED++))
else
    echo -e "${RED}FAIL${NC} - Multiple connections failed at iteration $i"
    ((FAILED++))
fi

echo "Test 3: Handshake timeout handling"
# Kill server to test timeout
kill $SERVER_PID 2>/dev/null
wait $SERVER_PID 2>/dev/null

START_TIME=$(date +%s)
timeout 10 ./zig-out/bin/geode query 'RETURN 1 AS x' --server 127.0.0.1:8443 --insecure 2>/dev/null || true
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

if [ $ELAPSED -le 6 ]; then
    echo -e "${GREEN}PASS${NC} - Handshake timeout works (${ELAPSED}s)"
    ((PASSED++))
else
    echo -e "${RED}FAIL${NC} - Handshake timeout too long (${ELAPSED}s)"
    ((FAILED++))
fi

# Cleanup
rm -rf /tmp/test-certs
rm -f /tmp/server.log

echo
echo "=== Summary ==="
echo "Tests passed: $PASSED"
echo "Tests failed: $FAILED"

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All regression tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some regression tests failed${NC}"
    exit 1
fi
