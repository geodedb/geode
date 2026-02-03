#!/usr/bin/env bash
# Regression Test for All Fixed Issues
# Tests all the issues that were resolved to ensure they don't regress

set -e

echo "=== Regression Test for Fixed Issues ==="
echo "Testing all resolved issues to prevent regression"
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

# Test function
test_feature() {
    local name="$1"
    local cmd="$2"

    echo -n "Testing $name... "
    if eval "$cmd" > /dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAIL${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  Command: $cmd"
    fi
}

# Build first
echo "Building Geode..."
make build > /dev/null 2>&1

echo
echo "=== Phase 1: String Literal Parsing (PARTIAL FIX) ==="
echo "Known Issue: Double quotes still cause hangs"
echo "Workaround: Use single quotes for all strings"
echo

# Test single quotes work correctly
test_feature "Single quote string in RETURN" \
    "timeout 5 ./zig-out/bin/geode query \"RETURN 'hello world'\" --insecure"

test_feature "Single quote string in CREATE" \
    "timeout 5 ./zig-out/bin/geode query \"CREATE (p {name: 'Alice', age: 30})\" --insecure"

test_feature "Single quotes in properties" \
    "timeout 5 ./zig-out/bin/geode query \"CREATE (p {name: 'Bob', city: 'New York'})\" --insecure"

test_feature "Single quoted property names" \
    "timeout 5 ./zig-out/bin/geode query \"CREATE (p {'first_name': 'Charlie', 'last_name': 'Brown'})\" --insecure"

test_feature "Escaped single quotes" \
    "timeout 5 ./zig-out/bin/geode query \"RETURN 'She said \\\"hello\\\"'\" --insecure"

echo
echo "=== Phase 2: Property Names Support (FIXED) ==="
echo "Previously: Numeric and quoted property names didn't work"
echo "Fixed: All property name formats now supported"
echo

# Test various property name formats
test_feature "Numeric property names (quoted)" \
    "timeout 5 ./zig-out/bin/geode query \"CREATE (p {'123': 'numeric_key', '456': 789})\" --insecure"

test_feature "Single quoted property names" \
    "timeout 5 ./zig-out/bin/geode query \"CREATE (p {'prop_name': 'value'})\" --insecure"

test_feature "Property names with spaces" \
    "timeout 5 ./zig-out/bin/geode query \"CREATE (p {'full name': 'John Doe'})\" --insecure"

test_feature "Property names with special chars" \
    "timeout 5 ./zig-out/bin/geode query \"CREATE (p {'prop-name': 'value', 'prop.name': 'other'})\" --insecure"

echo
echo "=== Phase 3: Long String Handling (FIXED) ==="
echo "Previously: Long strings with certain keywords caused issues"
echo "Fixed: All string lengths work, keyword collision resolved"
echo

# Test long strings and keyword edge cases
test_feature "Very long string value" \
    "timeout 5 ./zig-out/bin/geode query \"CREATE (p {description: 'This is a very long string that tests the limits of string property handling in the database system and ensures that long strings are properly processed without any truncation or parsing errors'})\" --insecure"

test_feature "String with SQL-like content" \
    "timeout 5 ./zig-out/bin/geode query \"CREATE (p {query: 'SELECT * FROM users WHERE id = 123'})\" --insecure"

test_feature "String with GQL keywords" \
    "timeout 5 ./zig-out/bin/geode query \"CREATE (p {content: 'MATCH and RETURN and CREATE and DELETE'})\" --insecure"

# Note: 'desc' is a reserved keyword, so we use 'description' instead
test_feature "Property name avoiding reserved word" \
    "timeout 5 ./zig-out/bin/geode query \"CREATE (p {description: 'avoiding desc keyword', note: 'DESC is reserved for ORDER BY DESC'})\" --insecure"

echo
echo "=== Phase 4: Multiple MATCH Clauses (FIXED) ==="
echo "Previously: Multiple MATCH clauses were not supported"
echo "Fixed: Can chain multiple MATCH clauses"
echo

# Test multiple MATCH patterns
test_feature "Two MATCH clauses" \
    "timeout 5 ./zig-out/bin/geode query 'MATCH (a) MATCH (b) RETURN a, b LIMIT 1' --insecure"

test_feature "Three MATCH clauses" \
    "timeout 5 ./zig-out/bin/geode query 'MATCH (a) MATCH (b) MATCH (c) RETURN a, b, c LIMIT 1' --insecure"

test_feature "Multiple MATCH with WHERE" \
    "timeout 5 ./zig-out/bin/geode query 'MATCH (a) MATCH (b) WHERE a <> b RETURN a, b LIMIT 1' --insecure"

test_feature "Multiple MATCH with labels" \
    "timeout 5 ./zig-out/bin/geode query 'MATCH (a:Person) MATCH (b:Person) WHERE a <> b RETURN a, b LIMIT 1' --insecure"

echo
echo "=== Phase 5: OPTIONAL MATCH Support (FIXED) ==="
echo "Previously: OPTIONAL MATCH after MATCH didn't work"
echo "Fixed: OPTIONAL MATCH fully functional"
echo

# Test OPTIONAL MATCH functionality
test_feature "Single OPTIONAL MATCH" \
    "timeout 5 ./zig-out/bin/geode query 'OPTIONAL MATCH (n) RETURN n LIMIT 1' --insecure"

test_feature "MATCH with OPTIONAL MATCH" \
    "timeout 5 ./zig-out/bin/geode query 'MATCH (a) OPTIONAL MATCH (b:NonExistent) RETURN a, b LIMIT 1' --insecure"

test_feature "Multiple OPTIONAL MATCH" \
    "timeout 5 ./zig-out/bin/geode query 'OPTIONAL MATCH (a) OPTIONAL MATCH (b) RETURN a, b LIMIT 1' --insecure"

test_feature "OPTIONAL MATCH with WHERE" \
    "timeout 5 ./zig-out/bin/geode query 'OPTIONAL MATCH (n) WHERE n.age > 25 RETURN n LIMIT 1' --insecure"

echo
echo "=== Phase 6: Property-Based Ordering (Previously Fixed) ==="
echo "Regression test for previously fixed feature"
echo

# Verify property ordering still works
test_feature "ORDER BY node property" \
    "timeout 5 ./zig-out/bin/geode query 'MATCH (n) RETURN n ORDER BY n.name LIMIT 1' --insecure"

test_feature "ORDER BY with DESC" \
    "timeout 5 ./zig-out/bin/geode query 'MATCH (n) RETURN n ORDER BY n.age DESC LIMIT 1' --insecure"

test_feature "Multiple property ordering" \
    "timeout 5 ./zig-out/bin/geode query 'MATCH (n) RETURN n ORDER BY n.name, n.age LIMIT 1' --insecure"

echo
echo "=== Phase 7: Count Aggregation (Previously Fixed) ==="
echo "Regression test for previously fixed feature"
echo

# Verify count aggregation still works
test_feature "Basic count" \
    "timeout 5 ./zig-out/bin/geode query 'MATCH (n) RETURN count(n)' --insecure"

test_feature "Count with filter" \
    "timeout 5 ./zig-out/bin/geode query 'MATCH (n:Person) RETURN count(n)' --insecure"

test_feature "Count distinct" \
    "timeout 5 ./zig-out/bin/geode query 'MATCH (n) RETURN count(DISTINCT n.name)' --insecure"

echo
echo "=== Phase 8: Complex Integration Tests ==="
echo "Testing combinations of fixed features"
echo

# Test combinations of fixes
test_feature "Single quotes with multiple MATCH" \
    "timeout 5 ./zig-out/bin/geode query \"MATCH (a {name: 'Alice'}) MATCH (b) RETURN a, b LIMIT 1\" --insecure"

test_feature "OPTIONAL MATCH with single quotes" \
    "timeout 5 ./zig-out/bin/geode query \"MATCH (a) OPTIONAL MATCH (b {status: 'active'}) RETURN a, b LIMIT 1\" --insecure"

test_feature "Complex property names with single quotes" \
    "timeout 5 ./zig-out/bin/geode query \"CREATE (p {'user-id': 1, 'full name': 'Test User'})\" --insecure"

test_feature "All features combined" \
    "timeout 5 ./zig-out/bin/geode query \"MATCH (a {name: 'Test'}) OPTIONAL MATCH (b) WHERE b.age > 20 RETURN a, b ORDER BY b.age DESC LIMIT 5\" --insecure"

echo
echo "=== Regression Test Results Summary ==="
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✅ All regression tests passed! No regressions detected.${NC}"
    exit 0
else
    echo -e "${RED}❌ Some regression tests failed. Issues may have been reintroduced.${NC}"
    echo "Please review the failures above and ensure the fixes are properly applied."
    exit 1
fi
