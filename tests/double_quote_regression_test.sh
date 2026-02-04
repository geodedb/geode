#!/usr/bin/env bash
# Regression Test for Double Quote Parser Fix
# Ensures double quotes don't cause parser hangs

set -e

echo "=== Double Quote Parser Regression Test ==="
echo

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASSED=0
FAILED=0

test_quotes() {
    local name="$1"
    local input="$2"
    local timeout_sec="${3:-2}"

    echo -n "Testing $name... "

    local output
    local exit_code=0

    # Use timeout to prevent hangs
    output=$(timeout $timeout_sec $QUERY_CMD "$input" 2>&1) || exit_code=$?

    if [ $exit_code -eq 124 ]; then
        # Timeout occurred
        echo -e "${RED}HANG DETECTED${NC}"
        echo "  Query hangs with: $input"
        ((FAILED++))
    elif echo "$output" | grep -qE "status_class|error"; then
        # Query processed (either success or error)
        echo -e "${GREEN}PASS${NC} (processed without hanging)"
        ((PASSED++))
    else
        # Unexpected behavior
        echo -e "${YELLOW}WARNING${NC}"
        echo "  Unexpected output for: $input"
        ((FAILED++))
    fi
}

# Build
echo "Building Geode..."
make build > /dev/null 2>&1 || { echo -e "${RED}Build failed${NC}"; exit 1; }

SERVER_PORT=8453
ADMIN_USER="${GEODE_ADMIN_USERNAME:-geode}"
ADMIN_PASS="${GEODE_DEFAULT_PASSWORD:-geode-test-password}"
DATA_DIR=$(mktemp -d /tmp/geode_double_quote_XXXXXX)
GEODE_ADMIN_USERNAME="${ADMIN_USER}" GEODE_DEFAULT_PASSWORD="${ADMIN_PASS}" \
    ./zig-out/bin/geode serve --listen 127.0.0.1:${SERVER_PORT} --data-dir "${DATA_DIR}" > /tmp/geode_double_quote.log 2>&1 &
SERVER_PID=$!
sleep 2

cleanup() {
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
    rm -rf "${DATA_DIR}"
    rm -f /tmp/geode_double_quote.log
}
trap cleanup EXIT

QUERY_CMD="./zig-out/bin/geode query --server 127.0.0.1:${SERVER_PORT} --insecure --user ${ADMIN_USER} --password ${ADMIN_PASS}"

echo
echo "Testing string literal handling..."

# Test single quotes (should work)
test_quotes "Single quotes in RETURN" "RETURN 'test' AS x"
test_quotes "Single quotes in properties" "CREATE (n {name: 'Alice'})"
test_quotes "Single quotes with escapes" "RETURN 'It\\'s working' AS msg"

# Test double quotes (should not hang after fix)
test_quotes "Double quotes in RETURN" 'RETURN "test" AS x'
test_quotes "Double quotes in properties" 'CREATE (n {name: "Alice"})'
test_quotes "Double quotes with escapes" 'RETURN "Say \\"hello\\"" AS msg'

# Test mixed quotes
test_quotes "Mixed quotes (outer single)" "CREATE (n {name: 'Bob', title: 'CEO'})"
test_quotes "Mixed quotes (outer double)" 'CREATE (n {name: "Bob", title: "CEO"})'

# Test edge cases
test_quotes "Empty string (single)" "RETURN '' AS empty"
test_quotes "Empty string (double)" 'RETURN "" AS empty'
test_quotes "Unterminated single quote" "RETURN 'unterminated"
test_quotes "Unterminated double quote" 'RETURN "unterminated'

echo
echo "=== Summary ==="
echo "Tests passed: $PASSED"
echo "Tests failed: $FAILED"
echo "Total tests: $((PASSED + FAILED))"

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed! Double quote handling is fixed.${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed. Double quote issue may persist.${NC}"
    exit 1
fi
