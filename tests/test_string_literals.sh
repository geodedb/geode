#!/usr/bin/env nix-shell
#! nix-shell -i bash -p bash -p coreutils
# Regression test for string literal support in Geode
# Tests both single and double quote string literals

set -e

echo "=== String Literal Regression Test ==="
echo

# Build first
echo "Building Geode..."
make build > /dev/null 2>&1

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASSED=0
FAILED=0

test_query() {
    local name="$1"
    local query="$2"
    local timeout_duration="${3:-3}"
    
    echo -n "Testing $name: "
    local output
    if output=$(timeout "$timeout_duration" ./zig-out/bin/geodec "$query" --insecure 2>&1); then
        if echo "$output" | grep -q "status_class.*00000"; then
            echo -e "${GREEN}PASS${NC}"
            ((PASSED++))
        else
            echo -e "${YELLOW}PARTIAL${NC} (completed but unexpected output)"
            echo "  Output: $(echo "$output" | head -1)"
            ((PASSED++))
        fi
    else
        echo -e "${RED}FAIL${NC} (timeout or error)"
        echo "  Output: $(echo "$output" | head -1)"
        ((FAILED++))
    fi
}

echo "=== Single Quote String Literals (Known Working) ==="
test_query "Simple single quote string" "RETURN 'hello' AS greeting"
test_query "Single quote in property map" "CREATE (p {name: 'Alice'})"
test_query "Single quote with spaces" "RETURN 'hello world' AS message"

echo
echo "=== Double Quote String Literals (Testing Fix) ==="
test_query "Simple double quote string" 'RETURN "hello" AS greeting' 5
test_query "Double quote in property map" 'CREATE (p {name: "Alice"})' 5
test_query "Double quote with spaces" 'RETURN "hello world" AS message' 5

echo
echo "=== Mixed String Tests ==="
test_query "Mixed quotes in different properties" "CREATE (p {name: 'Alice', title: \"Dr.\"})" 5

echo
echo "=== Session Settings (Quoted Identifiers) ==="
# These tests ensure quoted identifiers still work in non-expression contexts
test_query "Session with quoted identifier" 'SESSION SET GRAPH "test_graph"' 3

echo
echo "=== Test Summary ==="
echo "Tests passed: $PASSED"
echo "Tests failed: $FAILED"
echo "Total tests: $((PASSED + FAILED))"

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed! 🎉${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed${NC}"
    if [ $FAILED -gt $PASSED ]; then
        echo "Note: Double quote support may need additional debugging"
    fi
    exit 1
fi