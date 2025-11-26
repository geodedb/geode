#!/usr/bin/env nix-shell
#! nix-shell -i bash -p bash -p coreutils
# Focused Database Integration Tests - Testing working functionality

set -e

echo "=== Focused Geode Database Tests ==="
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

# Test function
run_test() {
    local name="$1"
    local cmd="$2"
    local pattern="$3"
    
    echo -n "Testing $name... "
    if [ -n "$pattern" ]; then
        if eval "$cmd" 2>&1 | grep -q "$pattern"; then
            echo -e "${GREEN}PASS${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${RED}FAIL${NC}"
            ((TESTS_FAILED++))
        fi
    else
        if eval "$cmd" > /dev/null 2>&1; then
            echo -e "${GREEN}PASS${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${RED}FAIL${NC}"
            ((TESTS_FAILED++))
        fi
    fi
}

# Build first
echo "Building Geode..."
make build > /dev/null 2>&1

# Test 1: Basic Data Types
echo -e "${BLUE}=== Basic Data Types ===${NC}"

run_test "Integer values" \
    "./zig-out/bin/geodec 'RETURN 42 AS answer' --server 127.0.0.1:3141 --insecure" \
    '"answer":42'

run_test "Floating point" \
    "./zig-out/bin/geodec 'RETURN 3.14159 AS pi' --server 127.0.0.1:3141 --insecure" \
    '"pi":3.14159'

run_test "Boolean values" \
    "./zig-out/bin/geodec 'RETURN true AS bool_true, false AS bool_false' --server 127.0.0.1:3141 --insecure" \
    '"bool_true":true'

run_test "NULL values" \
    "./zig-out/bin/geodec 'RETURN null AS null_val' --server 127.0.0.1:3141 --insecure" \
    '"null_val":null'

echo

# Test 2: Arithmetic Operations
echo -e "${BLUE}=== Arithmetic Operations ===${NC}"

run_test "Addition" \
    "./zig-out/bin/geodec 'RETURN 2 + 3 AS sum' --server 127.0.0.1:3141 --insecure" \
    '"sum":5'

run_test "Subtraction" \
    "./zig-out/bin/geodec 'RETURN 10 - 4 AS diff' --server 127.0.0.1:3141 --insecure" \
    '"diff":6'

run_test "Multiplication" \
    "./zig-out/bin/geodec 'RETURN 6 * 7 AS product' --server 127.0.0.1:3141 --insecure" \
    '"product":42'

run_test "Division" \
    "./zig-out/bin/geodec 'RETURN 15 / 3 AS quotient' --server 127.0.0.1:3141 --insecure" \
    '"quotient":5'

echo

# Test 3: Comparison Operations
echo -e "${BLUE}=== Comparison Operations ===${NC}"

run_test "Equality" \
    "./zig-out/bin/geodec 'RETURN 5 = 5 AS equal' --server 127.0.0.1:3141 --insecure" \
    '"equal":true'

run_test "Inequality" \
    "./zig-out/bin/geodec 'RETURN 5 <> 3 AS not_equal' --server 127.0.0.1:3141 --insecure" \
    '"not_equal":true'

run_test "Greater than" \
    "./zig-out/bin/geodec 'RETURN 10 > 5 AS greater' --server 127.0.0.1:3141 --insecure" \
    '"greater":true'

run_test "Less than or equal" \
    "./zig-out/bin/geodec 'RETURN 3 <= 5 AS less_or_equal' --server 127.0.0.1:3141 --insecure" \
    '"less_or_equal":true'

echo

# Test 4: Logical Operations
echo -e "${BLUE}=== Logical Operations ===${NC}"

run_test "AND operation" \
    "./zig-out/bin/geodec 'RETURN true AND true AS and_result' --server 127.0.0.1:3141 --insecure" \
    '"and_result":true'

run_test "OR operation" \
    "./zig-out/bin/geodec 'RETURN false OR true AS or_result' --server 127.0.0.1:3141 --insecure" \
    '"or_result":true'

run_test "NOT operation" \
    "./zig-out/bin/geodec 'RETURN NOT false AS not_result' --server 127.0.0.1:3141 --insecure" \
    '"not_result":true'

echo

# Test 5: Mathematical Functions
echo -e "${BLUE}=== Mathematical Functions ===${NC}"

run_test "ABS function" \
    "./zig-out/bin/geodec 'RETURN abs(-42) AS absolute' --server 127.0.0.1:3141 --insecure" \
    '"absolute":42'

run_test "ROUND function" \
    "./zig-out/bin/geodec 'RETURN round(3.7) AS rounded' --server 127.0.0.1:3141 --insecure" \
    '"rounded":4'

run_test "MIN function" \
    "./zig-out/bin/geodec 'RETURN min(5, 3) AS minimum' --server 127.0.0.1:3141 --insecure" \
    '"minimum":3'

run_test "MAX function" \
    "./zig-out/bin/geodec 'RETURN max(5, 3) AS maximum' --server 127.0.0.1:3141 --insecure" \
    '"maximum":5'

echo

# Test 6: Simple Node Operations (without string properties)
echo -e "${BLUE}=== Simple Node Operations ===${NC}"

run_test "Create node with integer property" \
    "./zig-out/bin/geodec 'CREATE (n:Person {age: 30})' --server 127.0.0.1:3141 --insecure"

run_test "Create node with multiple properties" \
    "./zig-out/bin/geodec 'CREATE (n:Person {age: 25, score: 95})' --server 127.0.0.1:3141 --insecure"

run_test "Match nodes" \
    "./zig-out/bin/geodec 'MATCH (n) RETURN count(n) AS node_count' --server 127.0.0.1:3141 --insecure" \
    '"node_count":'

run_test "Match with label" \
    "./zig-out/bin/geodec 'MATCH (p:Person) RETURN count(p) AS person_count' --server 127.0.0.1:3141 --insecure" \
    '"person_count":'

echo

# Test 7: Property Operations
echo -e "${BLUE}=== Property Operations ===${NC}"

run_test "Match with property filter" \
    "./zig-out/bin/geodec 'MATCH (p:Person) WHERE p.age > 25 RETURN count(p) AS older_count' --server 127.0.0.1:3141 --insecure" \
    '"older_count":'

run_test "Set property" \
    "./zig-out/bin/geodec 'MATCH (p:Person) WHERE p.age = 30 SET p.updated = true' --server 127.0.0.1:3141 --insecure"

run_test "Update property" \
    "./zig-out/bin/geodec 'MATCH (p:Person) WHERE p.age = 25 SET p.age = 26' --server 127.0.0.1:3141 --insecure"

echo

# Test 8: Aggregation Functions
echo -e "${BLUE}=== Aggregation Functions ===${NC}"

run_test "COUNT aggregation" \
    "./zig-out/bin/geodec 'MATCH (p:Person) RETURN count(p) AS total' --server 127.0.0.1:3141 --insecure" \
    '"total":'

run_test "SUM aggregation" \
    "./zig-out/bin/geodec 'MATCH (p:Person) RETURN sum(p.age) AS total_age' --server 127.0.0.1:3141 --insecure" \
    '"total_age":'

run_test "AVG aggregation" \
    "./zig-out/bin/geodec 'MATCH (p:Person) RETURN avg(p.age) AS avg_age' --server 127.0.0.1:3141 --insecure" \
    '"avg_age":'

run_test "MIN/MAX aggregation" \
    "./zig-out/bin/geodec 'MATCH (p:Person) RETURN min(p.age) AS min_age, max(p.age) AS max_age' --server 127.0.0.1:3141 --insecure" \
    '"min_age":'

echo

# Test 9: Ordering and Limiting
echo -e "${BLUE}=== Ordering and Limiting ===${NC}"

run_test "ORDER BY" \
    "./zig-out/bin/geodec 'MATCH (p:Person) RETURN p.age ORDER BY p.age' --server 127.0.0.1:3141 --insecure" \
    '"age":'

run_test "LIMIT" \
    "./zig-out/bin/geodec 'MATCH (p:Person) RETURN p.age LIMIT 1' --server 127.0.0.1:3141 --insecure" \
    '"age":'

run_test "ORDER BY with LIMIT" \
    "./zig-out/bin/geodec 'MATCH (p:Person) RETURN p.age ORDER BY p.age DESC LIMIT 1' --server 127.0.0.1:3141 --insecure" \
    '"age":'

echo

# Test 10: Set Operations
echo -e "${BLUE}=== Set Operations ===${NC}"

run_test "UNION" \
    "./zig-out/bin/geodec 'RETURN 1 AS x UNION RETURN 2 AS x' --server 127.0.0.1:3141 --insecure" \
    '"x":'

run_test "UNION ALL" \
    "./zig-out/bin/geodec 'RETURN 1 AS x UNION ALL RETURN 1 AS x' --server 127.0.0.1:3141 --insecure" \
    '"x":1'

echo

# Test 11: Error Handling
echo -e "${BLUE}=== Error Handling ===${NC}"

echo -n "Testing invalid syntax... "
if ./zig-out/bin/geodec 'INVALID QUERY' --server 127.0.0.1:3141 --insecure 2>&1 | grep -q "error"; then
    echo -e "${GREEN}PASS${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${RED}FAIL${NC}"
    ((TESTS_FAILED++))
fi

echo -n "Testing unordered pagination... "
if ./zig-out/bin/geodec 'MATCH (n) RETURN n LIMIT 5 OFFSET 2' --server 127.0.0.1:3141 --insecure 2>&1 | grep -q "US001"; then
    echo -e "${GREEN}PASS${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${RED}FAIL${NC}"
    ((TESTS_FAILED++))
fi

echo

# Test 12: Cleanup
echo -e "${BLUE}=== Cleanup ===${NC}"

run_test "Delete all nodes" \
    "./zig-out/bin/geodec 'MATCH (n) DETACH DELETE n' --server 127.0.0.1:3141 --insecure"

run_test "Verify cleanup" \
    "./zig-out/bin/geodec 'MATCH (n) RETURN count(n) AS remaining' --server 127.0.0.1:3141 --insecure" \
    '"remaining":0'

echo

# Summary
echo -e "${BLUE}=== Summary ===${NC}"
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"
echo "Total tests: $((TESTS_PASSED + TESTS_FAILED))"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All focused database tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
fi