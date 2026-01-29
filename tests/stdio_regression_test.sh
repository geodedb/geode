#!/usr/bin/env nix-shell
#! nix-shell -i bash -p bash -p coreutils
# Regression test for stdio mode communication
# Tests direct server communication via stdin/stdout with proper JSON protocol

set -e

echo "=== Geode Stdio Mode Regression Tests ==="
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

# Test function
run_stdio_test() {
    local name="$1"
    local json_message="$2"
    local expected_pattern="$3"

    echo -n "Testing $name... "
    local output
    output=$(echo "$json_message" | timeout 3 ./zig-out/bin/geoded 2>/dev/null | head -1)
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

# Test 1: Integer RETURN query
echo -e "${BLUE}=== Basic Query Tests ===${NC}"

run_stdio_test "Integer query" \
    '{"type":"RUN_GQL","text":"RETURN 1 AS num"}' \
    '"name":"num".*"type":"INT"'

run_stdio_test "String literal query" \
    '{"type":"RUN_GQL","text":"RETURN \"hello\" AS greeting"}' \
    '"name":"greeting"'

run_stdio_test "Boolean query" \
    '{"type":"RUN_GQL","text":"RETURN true AS flag"}' \
    '"name":"flag"'

run_stdio_test "Mathematical expression" \
    '{"type":"RUN_GQL","text":"RETURN 2 + 3 AS sum"}' \
    '"name":"sum"'

echo

# Test 2: Edge Cases
echo -e "${BLUE}=== Edge Case Tests ===${NC}"

run_stdio_test "Empty string" \
    '{"type":"RUN_GQL","text":"RETURN \"\" AS empty"}' \
    '"name":"empty"'

run_stdio_test "Special characters in string" \
    '{"type":"RUN_GQL","text":"RETURN \"hello\\nworld\" AS multiline"}' \
    '"name":"multiline"'

run_stdio_test "Unicode string" \
    '{"type":"RUN_GQL","text":"RETURN \"🌟\" AS star"}' \
    '"name":"star"'

echo

# Test 3: Protocol Error Cases
echo -e "${BLUE}=== Protocol Error Tests ===${NC}"

# This should fail gracefully (wrong field name)
echo -n "Testing wrong field name... "
if echo '{"type":"RUN_GQL","gql":"RETURN 1 AS num"}' | timeout 3 ./zig-out/bin/geoded 2>/dev/null | wc -l | grep -q "^0$"; then
    echo -e "${GREEN}PASS${NC} (correctly ignored invalid message)"
    ((TESTS_PASSED++))
else
    echo -e "${RED}FAIL${NC} (should have ignored invalid message)"
    ((TESTS_FAILED++))
fi

echo

# Summary
echo -e "${BLUE}=== Summary ===${NC}"
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"
echo "Total tests: $((TESTS_PASSED + TESTS_FAILED))"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All stdio regression tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
fi
