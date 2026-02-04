#!/usr/bin/env bash
# Regression test for QUIC/protobuf query path (stdio server removed)
# Validates JSON output formatting and basic query execution via QUIC.

set -e

echo "=== Geode QUIC Regression Tests ==="
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

SERVER_PORT=8451
ADMIN_USER="${GEODE_ADMIN_USERNAME:-geode}"
ADMIN_PASS="${GEODE_DEFAULT_PASSWORD:-geode-test-password}"
DATA_DIR=$(mktemp -d /tmp/geode_quic_regression_XXXXXX)
GEODE_ADMIN_USERNAME="${ADMIN_USER}" GEODE_DEFAULT_PASSWORD="${ADMIN_PASS}" \
    ./zig-out/bin/geode serve --listen 127.0.0.1:${SERVER_PORT} --data-dir "${DATA_DIR}" > /tmp/geode_quic_regression.log 2>&1 &
SERVER_PID=$!
sleep 2

cleanup() {
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
    rm -rf "${DATA_DIR}"
    rm -f /tmp/geode_quic_regression.log
}
trap cleanup EXIT

QUERY_CMD="./zig-out/bin/geode query --server 127.0.0.1:${SERVER_PORT} --insecure --user ${ADMIN_USER} --password ${ADMIN_PASS}"

# Test function
run_query_test() {
    local name="$1"
    local query="$2"
    local expected_pattern="$3"

    echo -n "Testing $name... "
    local output
    output=$(timeout 5 $QUERY_CMD "$query" 2>/dev/null | head -1)
    if echo "$output" | grep -q "$expected_pattern"; then
        echo -e "${GREEN}PASS${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}FAIL${NC}"
        echo "  Expected pattern: $expected_pattern"
        echo "  Actual output: $output"
        ((TESTS_FAILED++))
    fi
}

# Build first
echo "Building Geode..."
make build > /dev/null 2>&1

# Test 1: Basic Query Tests
echo -e "${BLUE}=== Basic Query Tests ===${NC}"

run_query_test "Integer query" \
    "RETURN 1 AS num" \
    "\"num\":1"

run_query_test "String literal query" \
    "RETURN \"hello\" AS greeting" \
    "\"greeting\":\"hello\""

run_query_test "Boolean query" \
    "RETURN true AS flag" \
    "\"flag\":true"

run_query_test "Mathematical expression" \
    "RETURN 2 + 3 AS sum" \
    "\"sum\":5"

echo

# Test 2: Edge Cases
echo -e "${BLUE}=== Edge Case Tests ===${NC}"

run_query_test "Empty string" \
    "RETURN \"\" AS empty" \
    "\"empty\":\"\""

run_query_test "Special characters in string" \
    "RETURN \"hello\\nworld\" AS multiline" \
    "\"multiline\""

run_query_test "Unicode string" \
    "RETURN \"star\" AS star" \
    "\"star\""

echo

# Test 3: Error Cases
echo -e "${BLUE}=== Error Handling Tests ===${NC}"

echo -n "Testing invalid query... "
INVALID_OUTPUT=$(timeout 5 $QUERY_CMD "RETURN" 2>&1 | head -1 || true)
if echo "$INVALID_OUTPUT" | grep -q "ParseError\|error"; then
    echo -e "${GREEN}PASS${NC} (error surfaced)"
    ((TESTS_PASSED++))
else
    echo -e "${RED}FAIL${NC} (expected error)"
    echo "  Output: $INVALID_OUTPUT"
    ((TESTS_FAILED++))
fi

echo

# Summary
echo -e "${BLUE}=== Summary ===${NC}"
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"
echo "Total tests: $((TESTS_PASSED + TESTS_FAILED))"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All QUIC regression tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
fi
