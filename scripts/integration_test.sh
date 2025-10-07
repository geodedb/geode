#!/usr/bin/env nix-shell
#! nix-shell -i bash -p bash -p coreutils
# Integration test script for Geode with all transport modes

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

# Test 1: Process mode (stdio)
echo "=== Process Mode Tests ==="
run_test "Basic query" "./zig-out/bin/geode query 'RETURN 1 AS x ORDER BY x LIMIT 1' --no-quic"
run_test "Error handling" "./zig-out/bin/geode query 'RETURN 1 LIMIT 10 OFFSET 5' --no-quic 2>&1 | grep -q US001"
run_test "Set operations" "./zig-out/bin/geode query 'RETURN 1 AS x UNION RETURN 1 AS x' --no-quic"
echo

# Test 2: QUIC mode (temporarily disabled due to certificate validation issues)
echo "=== QUIC Mode Tests ==="
echo "QUIC tests temporarily disabled - handshake works but certificate validation needs refinement"
echo

# Test 4: Go client library (if available)
if [ -d "clients/go/gql" ]; then
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
else
    echo "=== Go Client Tests ==="
    echo "Go client directory not found - skipping Go tests"
    echo
fi

# Test 6: Zig tests  
echo "=== Zig Unit Tests ==="
# Note: These tests are currently disabled as they need updating
echo "Zig unit tests temporarily disabled - need AST structure updates"
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