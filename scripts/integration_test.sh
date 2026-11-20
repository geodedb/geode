#!/usr/bin/env bash
# Integration test script for Geode (QUIC + gRPC)

set -e

# Get the script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
cd "$PROJECT_ROOT"

echo "=== Geode Integration Tests ==="
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test results
TESTS_PASSED=0
TESTS_FAILED=0

# Function to run a test
run_test() {
    local name="$1"
    local cmd="$2"

    echo -n "Testing $name... "
    if bash -c "$cmd" > /dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAIL${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Build everything first
echo "Building Geode..."
make build > /dev/null 2>&1 || { echo "Build failed"; exit 1; }
echo "Build successful"
echo

# Start QUIC server
SERVER_PORT=8451
DATA_DIR=$(mktemp -d /tmp/geode_integration_XXXXXX)
ADMIN_USER="${GEODE_ADMIN_USERNAME:-geode}"
ADMIN_PASS="${GEODE_DEFAULT_PASSWORD:-Geode Test Admin Passphrase}"

GEODE_ADMIN_USERNAME="${ADMIN_USER}" GEODE_DEFAULT_PASSWORD="${ADMIN_PASS}" \
    ./zig-out/bin/geode serve --listen 127.0.0.1:${SERVER_PORT} --data_dir "${DATA_DIR}" >/tmp/geode_integration.log 2>&1 &
SERVER_PID=$!

cleanup() {
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
    rm -rf "${DATA_DIR}"
    rm -f /tmp/geode_integration.log
}
trap cleanup EXIT

sleep 2

# Test 1: QUIC mode
echo "=== QUIC Mode Tests ==="
run_test "Basic query" "./zig-out/bin/geode query 'RETURN 1 AS x ORDER BY x LIMIT 1' --server 127.0.0.1:${SERVER_PORT} --insecure --user ${ADMIN_USER} --password '${ADMIN_PASS}'"
run_test "Error handling" "./zig-out/bin/geode query 'MATCH (n:InvalidLabel--)' --server 127.0.0.1:${SERVER_PORT} --insecure --user ${ADMIN_USER} --password '${ADMIN_PASS}' 2>&1 | grep -qi 'error'"
run_test "Set operations" "./zig-out/bin/geode query 'RETURN 1 AS x UNION RETURN 1 AS x' --server 127.0.0.1:${SERVER_PORT} --insecure --user ${ADMIN_USER} --password '${ADMIN_PASS}'"
echo

# Test 4: Go client library (if available)
if [ -d "clients/go/gql" ]; then
    echo "=== Go Client Tests ==="
    run_test "Go library build" "cd clients/go/gql && go build ./..."
    run_test "Go client tests" "cd clients/go/gql && go test -timeout 10s"
    echo

    # Test 5: Example program
    echo "=== Example Program Tests ==="
    run_test "Example build" "cd clients/go/gql && go build -o ../../../zig-out/bin/gql-example ./example"
    run_test "Example run" "./zig-out/bin/gql-example -server 127.0.0.1:${SERVER_PORT}"
    echo
else
    echo "=== Go Client Tests ==="
    echo "Go client directory not found - skipping Go tests"
    echo
fi

# Test 6: Zig tests
echo "=== Zig Unit Tests ==="
echo "Running Zig unit tests..."
if make test > /tmp/zig_test_output.log 2>&1; then
    echo -e "${GREEN}PASS${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}FAIL${NC}"
    echo "See /tmp/zig_test_output.log for details"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi
echo

# Summary
echo "=== Test Summary ==="
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
fi
