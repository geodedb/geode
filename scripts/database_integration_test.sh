#!/usr/bin/env nix-shell
#! nix-shell -i bash -p bash -p coreutils
# Comprehensive Database Integration Tests for Geode
# Tests all major database functionality including CRUD, transactions, constraints, etc.

set -e

echo "=== Geode Database Integration Tests ==="
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test results
TESTS_PASSED=0
TESTS_FAILED=0
TOTAL_TESTS=0

# Function to run a test
run_test() {
    local name="$1"
    local cmd="$2"
    local expected_pattern="$3"
    
    ((TOTAL_TESTS++))
    echo -n "Testing $name... "
    
    if [ -n "$expected_pattern" ]; then
        # Test with expected output pattern
        if eval "$cmd" 2>&1 | grep -q "$expected_pattern"; then
            echo -e "${GREEN}PASS${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${RED}FAIL${NC}"
            ((TESTS_FAILED++))
            echo "  Expected pattern: $expected_pattern"
            echo "  Actual output:"
            eval "$cmd" 2>&1 | head -3 | sed 's/^/    /'
        fi
    else
        # Test for successful execution (no error)
        if eval "$cmd" > /dev/null 2>&1; then
            echo -e "${GREEN}PASS${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${RED}FAIL${NC}"
            ((TESTS_FAILED++))
            echo "  Command failed with error:"
            eval "$cmd" 2>&1 | head -3 | sed 's/^/    /'
        fi
    fi
}

# Function to run a test expecting failure
run_failure_test() {
    local name="$1"
    local cmd="$2"
    local expected_error="$3"
    
    ((TOTAL_TESTS++))
    echo -n "Testing $name... "
    
    if eval "$cmd" 2>&1 | grep -q "$expected_error"; then
        echo -e "${GREEN}PASS${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}FAIL${NC}"
        ((TESTS_FAILED++))
        echo "  Expected error: $expected_error"
        echo "  Actual output:"
        eval "$cmd" 2>&1 | head -3 | sed 's/^/    /'
    fi
}

# Build everything first
echo "Building Geode..."
make build > /dev/null 2>&1 || { echo "Build failed"; exit 1; }
echo "Build successful"
echo

# Test 1: Basic Database Operations
echo -e "${BLUE}=== Basic Database Operations ===${NC}"

run_test "Simple return query" \
    "./zig-out/bin/geodec 'RETURN 1 AS num' --no-quic" \
    '"num":1'

run_test "Basic arithmetic" \
    "./zig-out/bin/geodec 'RETURN 2 + 3 AS sum' --no-quic" \
    '"sum":5'

run_test "Boolean values" \
    "./zig-out/bin/geodec 'RETURN true AS bool_val, false AS bool_false' --no-quic" \
    '"bool_val":true'

run_test "Multiple columns" \
    "./zig-out/bin/geodec 'RETURN 1 AS a, 2 AS b, 3 AS c' --no-quic" \
    '"a":1'

echo

# Test 2: Node and Relationship Creation
echo -e "${BLUE}=== Node and Relationship Creation ===${NC}"

run_test "Create single node" \
    "./zig-out/bin/geodec 'CREATE (n:Person {age: 30})' --no-quic"

run_test "Create multiple nodes" \
    "./zig-out/bin/geodec 'CREATE (n:Person {name: \"Bob\', age: 25}), (m:Person {name: \'Charlie\", age: 35})' --no-quic"

run_test "Create relationship" \
    "./zig-out/bin/geodec 'MATCH (a:Person {name: \"Alice\"}), (b:Person {name: \"Bob\"}) CREATE (a)-[:KNOWS {since: 2020}]->(b)' --no-quic"

run_test "Create complex graph" \
    "./zig-out/bin/geodec 'CREATE (a:Person {name: \"David\'})-[:WORKS_AT {role: \'Engineer\"}]->(c:Company {name: \"TechCorp\"})' --no-quic"

echo

# Test 3: Data Retrieval and MATCH Queries
echo -e "${BLUE}=== Data Retrieval and MATCH Queries ===${NC}"

run_test "Match all nodes" \
    "./zig-out/bin/geodec 'MATCH (n) RETURN count(n) AS node_count' --no-quic" \
    '"node_count":'

run_test "Match specific label" \
    "./zig-out/bin/geodec 'MATCH (p:Person) RETURN p.name AS name ORDER BY p.name' --no-quic" \
    '"name":'

run_test "Match with property filter" \
    "./zig-out/bin/geodec 'MATCH (p:Person) WHERE p.age > 25 RETURN p.name, p.age ORDER BY p.age' --no-quic" \
    '"name":'

run_test "Match relationships" \
    "./zig-out/bin/geodec 'MATCH (a:Person)-[r:KNOWS]->(b:Person) RETURN a.name, r.since, b.name' --no-quic" \
    '"name":'

run_test "Path traversal" \
    "./zig-out/bin/geodec 'MATCH (p:Person)-[:WORKS_AT]->(c:Company) RETURN p.name, c.name' --no-quic" \
    '"name":'

echo

# Test 4: Data Modification Operations
echo -e "${BLUE}=== Data Modification Operations ===${NC}"

run_test "SET property" \
    "./zig-out/bin/geodec 'MATCH (p:Person {name: \"Alice\"}) SET p.city = \"New York\"' --no-quic"

run_test "UPDATE property" \
    "./zig-out/bin/geodec 'MATCH (p:Person {name: \"Bob\"}) SET p.age = p.age + 1' --no-quic"

run_test "REMOVE property" \
    "./zig-out/bin/geodec 'MATCH (p:Person {name: \"Charlie\"}) REMOVE p.age' --no-quic"

run_test "Verify updates" \
    "./zig-out/bin/geodec 'MATCH (p:Person {name: \"Alice\"}) RETURN p.city AS city' --no-quic" \
    '"city":"New York"'

echo

# Test 5: Aggregation and Advanced Queries
echo -e "${BLUE}=== Aggregation and Advanced Queries ===${NC}"

run_test "COUNT aggregation" \
    "./zig-out/bin/geodec 'MATCH (p:Person) RETURN count(p) AS person_count' --no-quic" \
    '"person_count":'

run_test "AVG aggregation" \
    "./zig-out/bin/geodec 'MATCH (p:Person) WHERE p.age IS NOT NULL RETURN avg(p.age) AS avg_age' --no-quic" \
    '"avg_age":'

run_test "MIN/MAX aggregation" \
    "./zig-out/bin/geodec 'MATCH (p:Person) WHERE p.age IS NOT NULL RETURN min(p.age) AS min_age, max(p.age) AS max_age' --no-quic" \
    '"min_age":'

run_test "GROUP BY" \
    "./zig-out/bin/geodec 'MATCH (p:Person) RETURN count(p) AS count, \"people\" AS group_name' --no-quic" \
    '"count":'

echo

# Test 6: Ordering and Limiting
echo -e "${BLUE}=== Ordering and Limiting ===${NC}"

run_test "ORDER BY ASC" \
    "./zig-out/bin/geodec 'MATCH (p:Person) WHERE p.age IS NOT NULL RETURN p.name, p.age ORDER BY p.age ASC' --no-quic" \
    '"name":'

run_test "ORDER BY DESC" \
    "./zig-out/bin/geodec 'MATCH (p:Person) WHERE p.age IS NOT NULL RETURN p.name, p.age ORDER BY p.age DESC' --no-quic" \
    '"name":'

run_test "LIMIT results" \
    "./zig-out/bin/geodec 'MATCH (p:Person) RETURN p.name LIMIT 2' --no-quic" \
    '"name":'

run_test "SKIP and LIMIT" \
    "./zig-out/bin/geodec 'MATCH (p:Person) RETURN p.name ORDER BY p.name SKIP 1 LIMIT 2' --no-quic" \
    '"name":'

echo

# Test 7: Data Types Testing
echo -e "${BLUE}=== Data Types Testing ===${NC}"

run_test "Integer types" \
    "./zig-out/bin/geodec 'RETURN 42 AS int, 9223372036854775807 AS bigint' --no-quic" \
    '"int":42'

run_test "Floating point types" \
    "./zig-out/bin/geodec 'RETURN 3.14159 AS pi, 2.718281828 AS e' --no-quic" \
    '"pi":3.14159'

run_test "Boolean types" \
    "./zig-out/bin/geodec 'RETURN true AS bool_true, false AS bool_false' --no-quic" \
    '"bool_true":true'

run_test "String types" \
    "./zig-out/bin/geodec 'RETURN \"hello\" AS str, \"unicode: 🌟\" AS unicode_str' --no-quic" \
    '"str":"hello"'

run_test "Date/Time types" \
    "./zig-out/bin/geodec 'RETURN date(\"2023-12-25\") AS christmas' --no-quic" \
    '"christmas":'

run_test "Array types" \
    "./zig-out/bin/geodec 'RETURN [1, 2, 3, 4, 5] AS numbers' --no-quic" \
    '"numbers":'

echo

# Test 8: Set Operations
echo -e "${BLUE}=== Set Operations ===${NC}"

run_test "UNION operation" \
    "./zig-out/bin/geodec 'RETURN 1 AS x UNION RETURN 2 AS x' --no-quic" \
    '"x":'

run_test "UNION ALL operation" \
    "./zig-out/bin/geodec 'RETURN 1 AS x UNION ALL RETURN 1 AS x' --no-quic" \
    '"x":1'

run_test "INTERSECT operation" \
    "./zig-out/bin/geodec 'RETURN 1 AS x INTERSECT RETURN 1 AS x' --no-quic" \
    '"x":1'

run_test "EXCEPT operation" \
    "./zig-out/bin/geodec 'RETURN 1 AS x EXCEPT RETURN 2 AS x' --no-quic" \
    '"x":1'

echo

# Test 9: Transaction Testing
echo -e "${BLUE}=== Transaction Testing ===${NC}"

run_test "Begin transaction" \
    "./zig-out/bin/geodec 'BEGIN' --no-quic"

run_test "Transaction with CREATE" \
    "./zig-out/bin/geodec 'BEGIN' --no-quic && ./zig-out/bin/geodec 'CREATE (n:TestNode {id: 999})' --no-quic"

run_test "Commit transaction" \
    "./zig-out/bin/geodec 'COMMIT' --no-quic"

run_test "Rollback transaction" \
    "./zig-out/bin/geodec 'BEGIN' --no-quic && ./zig-out/bin/geodec 'CREATE (n:TempNode {id: 888})' --no-quic && ./zig-out/bin/geodec 'ROLLBACK' --no-quic"

echo

# Test 10: Error Handling
echo -e "${BLUE}=== Error Handling ===${NC}"

run_failure_test "Invalid syntax" \
    "./zig-out/bin/geodec 'INVALID QUERY SYNTAX' --no-quic" \
    "error"

run_failure_test "Unordered pagination" \
    "./zig-out/bin/geodec 'MATCH (n) RETURN n LIMIT 10 OFFSET 5' --no-quic" \
    "US001"

run_failure_test "Invalid property access" \
    "./zig-out/bin/geodec 'MATCH (n) RETURN n.nonexistent_property.invalid' --no-quic" \
    "error"

run_failure_test "Type mismatch" \
    "./zig-out/bin/geodec 'RETURN \"string\" + 123' --no-quic" \
    "error"

echo

# Test 11: Complex Graph Patterns
echo -e "${BLUE}=== Complex Graph Patterns ===${NC}"

run_test "Multi-hop traversal" \
    "./zig-out/bin/geodec 'MATCH (a)-[*1..3]->(b) RETURN count(*) AS path_count' --no-quic" \
    '"path_count":'

run_test "Variable length paths" \
    "./zig-out/bin/geodec 'MATCH p = (a:Person)-[*]->(b) RETURN length(p) AS path_length LIMIT 5' --no-quic" \
    '"path_length":'

run_test "Optional match" \
    "./zig-out/bin/geodec 'MATCH (p:Person) OPTIONAL MATCH (p)-[:KNOWS]->(friend) RETURN p.name, friend.name' --no-quic" \
    '"name":'

echo

# Test 12: Performance and Stress Tests
echo -e "${BLUE}=== Performance and Stress Tests ===${NC}"

run_test "Large result set" \
    "./zig-out/bin/geodec 'UNWIND range(1, 1000) AS i RETURN i AS number LIMIT 10' --no-quic" \
    '"number":'

run_test "Complex aggregation" \
    "./zig-out/bin/geodec 'UNWIND range(1, 100) AS i WITH i WHERE i % 2 = 0 RETURN count(i) AS even_count' --no-quic" \
    '"even_count":'

run_test "Nested queries" \
    "./zig-out/bin/geodec 'MATCH (p:Person) WITH count(p) AS person_count RETURN person_count * 2 AS doubled' --no-quic" \
    '"doubled":'

echo

# Test 13: Data Deletion
echo -e "${BLUE}=== Data Deletion ===${NC}"

run_test "DELETE nodes" \
    "./zig-out/bin/geodec 'MATCH (n:TestNode) DELETE n' --no-quic"

run_test "DELETE relationships" \
    "./zig-out/bin/geodec 'MATCH ()-[r:KNOWS]->() DELETE r' --no-quic"

run_test "DETACH DELETE" \
    "./zig-out/bin/geodec 'MATCH (n:Person {name: \"David\"}) DETACH DELETE n' --no-quic"

echo

# Summary
echo -e "${BLUE}=== Test Summary ===${NC}"
echo -e "Total tests run: ${YELLOW}$TOTAL_TESTS${NC}"
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All database integration tests passed!${NC}"
    echo -e "${GREEN}Geode database is functioning correctly.${NC}"
    exit 0
else
    echo -e "${RED}Some database integration tests failed${NC}"
    echo -e "${YELLOW}Success rate: $(( TESTS_PASSED * 100 / TOTAL_TESTS ))%${NC}"
    exit 1
fi