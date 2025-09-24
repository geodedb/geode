#!/bin/bash
# Integration test script for Geode with all transport modes

set -e

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
    if eval "$cmd" > /dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}FAIL${NC}"
        ((TESTS_FAILED++))
    fi
}

# Build everything first
echo "Building Geode..."
make build > /dev/null 2>&1 || { echo "Build failed"; exit 1; }
echo "Build successful"
echo

# Test 1: Process mode (stdio)
echo "=== Process Mode Tests ==="
run_test "Basic query" "./zig-out/bin/geodec 'RETURN 1 AS x ORDER BY x LIMIT 1' --no-quic"
run_test "Error handling" "! ./zig-out/bin/geodec 'RETURN 1 LIMIT 10 OFFSET 5' --no-quic 2>&1 | grep -q US001"
run_test "Set operations" "./zig-out/bin/geodec 'RETURN 1 AS x UNION RETURN 1 AS x' --no-quic"
echo

# Test 2: QUIC mode
echo "=== QUIC Mode Tests ==="
# Start QUIC server
./zig-out/bin/geoded --listen-quic 127.0.0.1:7567 > /dev/null 2>&1 &
QUIC_PID=$!
sleep 1

run_test "QUIC server responds" "./zig-out/bin/geodec 'RETURN 1 AS x' --server 127.0.0.1:7567"

# Stop QUIC server
kill $QUIC_PID 2>/dev/null || true
wait $QUIC_PID 2>/dev/null || true
echo

# Test 4: Go client library
echo "=== Go Client Tests ==="
run_test "Go library build" "cd clients/go/gql && go build ./..."
run_test "Go process mode" "cd clients/go/gql && go test -run TestGQL_OrderLimit -timeout 10s"
run_test "Go error handling" "cd clients/go/gql && go test -run TestGQL_UnorderedPaginationError -timeout 10s"
run_test "Go set operations" "cd clients/go/gql && go test -run TestGQL_SetDistinct -timeout 10s"
echo

# Test 5: Example program
echo "=== Example Program Tests ==="
run_test "Example build" "cd clients/go/gql && go build -o ../../../zig-out/bin/gql-example ./example"
run_test "Example process mode" "./zig-out/bin/gql-example -mode process"
echo

# Test 6: Zig tests
echo "=== Zig Unit Tests ==="
run_test "Parser tests" "zig test src/parser.zig"
run_test "Planner tests" "zig test src/planner.zig"
run_test "Protocol tests" "zig test src/protocol.zig"
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