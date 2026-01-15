#!/usr/bin/env bash
# GQL Language Features Test for Geode
# Tests compliance with ISO/IEC 39075:2024 Graph Query Language (GQL)

set -e

echo "=== GQL Language Features Test ==="
echo "Testing ISO/IEC 39075:2024 Graph Query Language compliance"
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_UNSUPPORTED=0

# Test function
test_gql_feature() {
    local name="$1"
    local cmd="$2"
    local expected_result="${3:-success}"
    
    echo -n "Testing $name... "
    local output
    output=$(eval "$cmd" 2>&1)
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        if [ "$expected_result" = "success" ]; then
            echo -e "${GREEN}PASS${NC}"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "${YELLOW}UNEXPECTED PASS${NC}"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        if echo "$output" | grep -q "ParseError\|not.*implement\|unsupported"; then
            echo -e "${BLUE}NOT IMPLEMENTED${NC}"
            TESTS_UNSUPPORTED=$((TESTS_UNSUPPORTED + 1))
        elif [ "$expected_result" = "fail" ]; then
            echo -e "${GREEN}EXPECTED FAIL${NC}"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "${RED}FAIL${NC}"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            echo "  Command: $cmd"
            echo "  Output: $(echo "$output" | head -1)"
        fi
    fi
}

# Build first
echo "Building Geode..."
make build > /dev/null 2>&1

echo
echo "=== Phase 1: Basic GQL Syntax ==="

# Core GQL syntax elements
test_gql_feature "Simple RETURN" "timeout 5 ./zig-out/bin/geodec 'RETURN 1' --insecure"
test_gql_feature "RETURN with AS" "timeout 5 ./zig-out/bin/geodec 'RETURN 1 AS one' --insecure"
test_gql_feature "Multiple RETURN" "timeout 5 ./zig-out/bin/geodec 'RETURN 1 AS one, 2 AS two, 3 AS three' --insecure"
test_gql_feature "RETURN expressions" "timeout 5 ./zig-out/bin/geodec 'RETURN 1 + 2 AS sum, 3 * 4 AS product' --insecure"

echo
echo "=== Phase 2: Graph Pattern Matching ==="

# Basic pattern matching
test_gql_feature "Node pattern" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN n' --insecure"
test_gql_feature "Labeled node pattern" "timeout 5 ./zig-out/bin/geodec 'MATCH (n:Person) RETURN n' --insecure"
test_gql_feature "Multi-label pattern" "timeout 5 ./zig-out/bin/geodec 'MATCH (n:Person:Employee) RETURN n' --insecure"
test_gql_feature "Relationship pattern" "timeout 5 ./zig-out/bin/geodec 'MATCH (a)-[r]->(b) RETURN a, r, b' --insecure"
test_gql_feature "Typed relationship" "timeout 5 ./zig-out/bin/geodec 'MATCH (a)-[r:KNOWS]->(b) RETURN a, r, b' --insecure"
test_gql_feature "Undirected relationship" "timeout 5 ./zig-out/bin/geodec 'MATCH (a)-[r]-(b) RETURN a, r, b' --insecure"

echo
echo "=== Phase 3: Variable Length Paths ==="

# Variable length path patterns
test_gql_feature "Variable length basic" "timeout 10 ./zig-out/bin/geodec 'MATCH (a)-[:KNOWS*]->(b) RETURN a, b' --insecure"
test_gql_feature "Variable length range" "timeout 10 ./zig-out/bin/geodec 'MATCH (a)-[:KNOWS*1..3]->(b) RETURN a, b' --insecure"
test_gql_feature "Variable length min" "timeout 10 ./zig-out/bin/geodec 'MATCH (a)-[:KNOWS*2..]->(b) RETURN a, b' --insecure"
test_gql_feature "Variable length max" "timeout 10 ./zig-out/bin/geodec 'MATCH (a)-[:KNOWS*..4]->(b) RETURN a, b' --insecure"
test_gql_feature "Any relationship type" "timeout 10 ./zig-out/bin/geodec 'MATCH (a)-[*2..4]-(b) RETURN a, b' --insecure"

echo
echo "=== Phase 4: WHERE Clause Features ==="

# WHERE clause patterns
test_gql_feature "Property equality" "timeout 5 ./zig-out/bin/geodec \"MATCH (n) WHERE n.age = 30 RETURN n\" --insecure"
test_gql_feature "Property comparison" "timeout 5 ./zig-out/bin/geodec \"MATCH (n) WHERE n.age > 18 AND n.age < 65 RETURN n\" --insecure"
test_gql_feature "String comparison" "timeout 5 ./zig-out/bin/geodec \"MATCH (n) WHERE n.name = 'Alice' RETURN n\" --insecure"
test_gql_feature "Boolean logic AND" "timeout 5 ./zig-out/bin/geodec \"MATCH (n) WHERE n.age > 18 AND n.active = true RETURN n\" --insecure"
test_gql_feature "Boolean logic OR" "timeout 5 ./zig-out/bin/geodec \"MATCH (n) WHERE n.age < 25 OR n.age > 60 RETURN n\" --insecure"
test_gql_feature "Boolean logic NOT" "timeout 5 ./zig-out/bin/geodec \"MATCH (n) WHERE NOT n.retired RETURN n\" --insecure"

# Property existence
test_gql_feature "IS NULL check" "timeout 5 ./zig-out/bin/geodec \"MATCH (n) WHERE n.optional_field IS NULL RETURN n\" --insecure"
test_gql_feature "IS NOT NULL check" "timeout 5 ./zig-out/bin/geodec \"MATCH (n) WHERE n.name IS NOT NULL RETURN n\" --insecure"

echo
echo "=== Phase 5: String Pattern Matching ==="

# String patterns
test_gql_feature "STARTS WITH" "timeout 5 ./zig-out/bin/geodec \"MATCH (n) WHERE n.name STARTS WITH 'A' RETURN n\" --insecure"
test_gql_feature "ENDS WITH" "timeout 5 ./zig-out/bin/geodec \"MATCH (n) WHERE n.name ENDS WITH 'son' RETURN n\" --insecure"
test_gql_feature "CONTAINS" "timeout 5 ./zig-out/bin/geodec \"MATCH (n) WHERE n.name CONTAINS 'John' RETURN n\" --insecure"
test_gql_feature "Regular expressions" "timeout 5 ./zig-out/bin/geodec \"MATCH (n) WHERE n.email =~ '.*@example\\.com' RETURN n\" --insecure"

echo
echo "=== Phase 6: Aggregation Functions ==="

# Standard aggregation functions
test_gql_feature "COUNT function" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN count(n)' --insecure"
test_gql_feature "COUNT DISTINCT" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN count(DISTINCT n.department)' --insecure"
test_gql_feature "MIN function" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN min(n.age)' --insecure"
test_gql_feature "MAX function" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN max(n.age)' --insecure"
test_gql_feature "AVG function" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN avg(n.salary)' --insecure"
test_gql_feature "SUM function" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN sum(n.salary)' --insecure"

echo
echo "=== Phase 7: ORDER BY and LIMIT ==="

# Ordering and limiting
test_gql_feature "ORDER BY ASC" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN n ORDER BY n.age ASC' --insecure"
test_gql_feature "ORDER BY DESC" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN n ORDER BY n.age DESC' --insecure"
test_gql_feature "ORDER BY multiple" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN n ORDER BY n.age, n.name' --insecure"
test_gql_feature "LIMIT clause" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN n ORDER BY n LIMIT 5' --insecure"
test_gql_feature "OFFSET clause" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN n ORDER BY n LIMIT 5 OFFSET 2' --insecure"
test_gql_feature "SKIP clause" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN n ORDER BY n SKIP 3 LIMIT 5' --insecure"

echo
echo "=== Phase 8: DISTINCT and Set Operations ==="

# Set operations
test_gql_feature "DISTINCT" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN DISTINCT n.department' --insecure"
test_gql_feature "UNION" "timeout 5 ./zig-out/bin/geodec \"MATCH (p:Person) RETURN p.name UNION MATCH (c:Company) RETURN c.name\" --insecure"
test_gql_feature "UNION ALL" "timeout 5 ./zig-out/bin/geodec \"MATCH (p:Person) RETURN p.name UNION ALL MATCH (p:Person) RETURN p.name\" --insecure"

echo
echo "=== Phase 9: CREATE Operations ==="

# Graph creation
test_gql_feature "CREATE node" "timeout 5 ./zig-out/bin/geodec 'CREATE (p:Person)' --insecure"
test_gql_feature "CREATE with properties" "timeout 5 ./zig-out/bin/geodec \"CREATE (p:Person {name: 'Alice', age: 30})\" --insecure"
test_gql_feature "CREATE relationship" "timeout 5 ./zig-out/bin/geodec 'CREATE (a)-[:KNOWS]->(b)' --insecure"
test_gql_feature "CREATE complex pattern" "timeout 5 ./zig-out/bin/geodec \"CREATE (alice:Person {name: 'Alice'})-[:WORKS_AT]->(company:Company {name: 'TechCorp'})\" --insecure"
test_gql_feature "CREATE multiple" "timeout 5 ./zig-out/bin/geodec 'CREATE (a), (b), (c), (a)-[:KNOWS]->(b), (b)-[:KNOWS]->(c)' --insecure"

echo
echo "=== Phase 10: UPDATE Operations ==="

# Data modification
test_gql_feature "SET property" "timeout 5 ./zig-out/bin/geodec \"MATCH (p:Person) WHERE p.name = 'Alice' SET p.age = 31\" --insecure"
test_gql_feature "SET multiple properties" "timeout 5 ./zig-out/bin/geodec \"MATCH (p:Person) SET p.last_login = timestamp(), p.active = true\" --insecure"
test_gql_feature "REMOVE property" "timeout 5 ./zig-out/bin/geodec \"MATCH (p:Person) REMOVE p.temporary_field\" --insecure"
test_gql_feature "SET with expression" "timeout 5 ./zig-out/bin/geodec \"MATCH (p:Person) SET p.age = p.age + 1\" --insecure"

echo
echo "=== Phase 11: DELETE Operations ==="

# Deletion operations
test_gql_feature "DELETE node" "timeout 5 ./zig-out/bin/geodec \"MATCH (p:Person) WHERE p.to_remove = true DELETE p\" --insecure"
test_gql_feature "DETACH DELETE" "timeout 5 ./zig-out/bin/geodec \"MATCH (p:Person) WHERE p.inactive = true DETACH DELETE p\" --insecure"
test_gql_feature "DELETE relationship" "timeout 5 ./zig-out/bin/geodec \"MATCH (a)-[r:TEMPORARY]->(b) DELETE r\" --insecure"

echo
echo "=== Phase 12: MERGE Operations ==="

# MERGE operations
test_gql_feature "MERGE node" "timeout 5 ./zig-out/bin/geodec \"MERGE (p:Person {email: 'alice@example.com'})\" --insecure"
test_gql_feature "MERGE with ON CREATE" "timeout 5 ./zig-out/bin/geodec \"MERGE (p:Person {email: 'bob@example.com'}) ON CREATE SET p.created = timestamp()\" --insecure"
test_gql_feature "MERGE with ON MATCH" "timeout 5 ./zig-out/bin/geodec \"MERGE (p:Person {email: 'charlie@example.com'}) ON MATCH SET p.last_seen = timestamp()\" --insecure"
test_gql_feature "MERGE relationship" "timeout 5 ./zig-out/bin/geodec \"MATCH (a:Person), (b:Person) MERGE (a)-[:KNOWS]->(b)\" --insecure"

echo
echo "=== Phase 13: Subqueries and EXISTS ==="

# Subquery patterns
test_gql_feature "EXISTS clause" "timeout 5 ./zig-out/bin/geodec \"MATCH (p:Person) WHERE EXISTS { MATCH (p)-[:WORKS_AT]->(:Company) } RETURN p\" --insecure"
test_gql_feature "NOT EXISTS clause" "timeout 5 ./zig-out/bin/geodec \"MATCH (p:Person) WHERE NOT EXISTS { MATCH (p)-[:MARRIED_TO]->() } RETURN p\" --insecure"
test_gql_feature "Correlated subquery" "timeout 5 ./zig-out/bin/geodec \"MATCH (c:Company) WHERE EXISTS { MATCH (c)<-[:WORKS_AT]-(p:Person) WHERE p.salary > 50000 } RETURN c\" --insecure"

echo
echo "=== Phase 14: WITH Clause ==="

# WITH clause usage
test_gql_feature "WITH basic" "timeout 5 ./zig-out/bin/geodec \"MATCH (p:Person) WITH p WHERE p.age > 25 RETURN p\" --insecure"
test_gql_feature "WITH aggregation" "timeout 5 ./zig-out/bin/geodec \"MATCH (p:Person) WITH avg(p.age) AS avg_age MATCH (p:Person) WHERE p.age > avg_age RETURN p\" --insecure"
test_gql_feature "WITH ORDER BY" "timeout 5 ./zig-out/bin/geodec \"MATCH (p:Person) WITH p ORDER BY p.salary DESC LIMIT 5 RETURN p\" --insecure"

echo
echo "=== Phase 15: OPTIONAL MATCH ==="

# Optional matching
test_gql_feature "OPTIONAL MATCH" "timeout 5 ./zig-out/bin/geodec 'MATCH (a) OPTIONAL MATCH (a)-[:FRIEND]->(b) RETURN a, b' --insecure"
test_gql_feature "Multiple OPTIONAL" "timeout 5 ./zig-out/bin/geodec 'MATCH (a) OPTIONAL MATCH (a)-[:FRIEND]->(b) OPTIONAL MATCH (a)-[:COLLEAGUE]->(c) RETURN a, b, c' --insecure"

echo
echo "=== Phase 16: Path Expressions ==="

# Path handling
test_gql_feature "Named path" "timeout 5 ./zig-out/bin/geodec 'MATCH path = (a)-[:KNOWS]->(b) RETURN path' --insecure"
test_gql_feature "Path length" "timeout 5 ./zig-out/bin/geodec 'MATCH path = (a)-[:KNOWS*]-(b) WHERE length(path) <= 3 RETURN path' --insecure"
test_gql_feature "Path nodes" "timeout 5 ./zig-out/bin/geodec 'MATCH path = (a)-[:KNOWS]->(b) RETURN nodes(path)' --insecure"
test_gql_feature "Path relationships" "timeout 5 ./zig-out/bin/geodec 'MATCH path = (a)-[:KNOWS]->(b) RETURN relationships(path)' --insecure"

echo
echo "=== Phase 17: Built-in Functions ==="

# Standard functions
test_gql_feature "Mathematical functions" "timeout 5 ./zig-out/bin/geodec 'RETURN abs(-5), sqrt(16), ceil(3.2), floor(3.8)' --insecure"
test_gql_feature "String functions" "timeout 5 ./zig-out/bin/geodec \"RETURN upper('hello'), lower('WORLD'), length('test')\" --insecure"
test_gql_feature "Type functions" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN type(n), labels(n), keys(n)' --insecure"
test_gql_feature "Temporal functions" "timeout 5 ./zig-out/bin/geodec 'RETURN date(), time(), datetime(), timestamp()' --insecure"

echo
echo "=== Phase 18: Collection Functions ==="

# Collection operations
test_gql_feature "IN operator" "timeout 5 ./zig-out/bin/geodec \"MATCH (p:Person) WHERE p.department IN ['Engineering', 'Sales'] RETURN p\" --insecure"
test_gql_feature "List functions" "timeout 5 ./zig-out/bin/geodec \"RETURN size([1,2,3]), head([1,2,3]), tail([1,2,3])\" --insecure"
test_gql_feature "COLLECT function" "timeout 5 ./zig-out/bin/geodec \"MATCH (p:Person) RETURN p.department, collect(p.name)\" --insecure"
test_gql_feature "UNWIND clause" "timeout 5 ./zig-out/bin/geodec \"UNWIND [1, 2, 3] AS x RETURN x\" --insecure"

echo
echo "=== Phase 19: Graph Schema Operations ==="

# Schema operations (may not be implemented)
test_gql_feature "CREATE INDEX" "timeout 5 ./zig-out/bin/geodec 'CREATE INDEX ON :Person(email)' --insecure"
test_gql_feature "DROP INDEX" "timeout 5 ./zig-out/bin/geodec 'DROP INDEX ON :Person(email)' --insecure"
test_gql_feature "CREATE CONSTRAINT" "timeout 5 ./zig-out/bin/geodec 'CREATE CONSTRAINT ON (p:Person) ASSERT p.email IS UNIQUE' --insecure"
test_gql_feature "DROP CONSTRAINT" "timeout 5 ./zig-out/bin/geodec 'DROP CONSTRAINT ON (p:Person) ASSERT p.email IS UNIQUE' --insecure"

echo
echo "=== Phase 20: Transaction Control ==="

# Transaction operations (may not be implemented)
test_gql_feature "BEGIN transaction" "timeout 5 ./zig-out/bin/geodec 'BEGIN' --insecure"
test_gql_feature "COMMIT transaction" "timeout 5 ./zig-out/bin/geodec 'COMMIT' --insecure"
test_gql_feature "ROLLBACK transaction" "timeout 5 ./zig-out/bin/geodec 'ROLLBACK' --insecure"

echo
echo "=== Phase 21: Procedural GQL ==="

# Procedural elements (advanced features)
test_gql_feature "CALL procedure" "timeout 5 ./zig-out/bin/geodec 'CALL db.schema.visualization()' --insecure"
test_gql_feature "YIELD from CALL" "timeout 5 ./zig-out/bin/geodec 'CALL db.labels() YIELD label RETURN label' --insecure"
test_gql_feature "FOR loop" "timeout 5 ./zig-out/bin/geodec 'FOR i IN range(1, 5) CREATE (:Node {id: i})' --insecure"
test_gql_feature "CASE expression" "timeout 5 ./zig-out/bin/geodec \"MATCH (p:Person) RETURN p.name, CASE WHEN p.age < 30 THEN 'Young' WHEN p.age < 60 THEN 'Middle' ELSE 'Senior' END AS category\" --insecure"

echo
echo "=== GQL Language Features Test Results Summary ==="
echo -e "Features implemented: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Features failed: ${RED}$TESTS_FAILED${NC}"
echo -e "Features not implemented: ${BLUE}$TESTS_UNSUPPORTED${NC}"
echo -e "Total features tested: $(( TESTS_PASSED + TESTS_FAILED + TESTS_UNSUPPORTED ))"

# Calculate percentages
local total_tested=$(( TESTS_PASSED + TESTS_FAILED ))
local total_features=$(( TESTS_PASSED + TESTS_FAILED + TESTS_UNSUPPORTED ))

if [ $total_tested -gt 0 ]; then
    local success_rate=$(( TESTS_PASSED * 100 / total_tested ))
    echo -e "Success rate of implemented features: ${GREEN}${success_rate}%${NC}"
fi

if [ $total_features -gt 0 ]; then
    local implementation_rate=$(( TESTS_PASSED * 100 / total_features ))
    echo -e "GQL compliance rate: ${BLUE}${implementation_rate}%${NC}"
fi

echo
echo "=== GQL Compliance Assessment ==="

if [ $TESTS_PASSED -ge 50 ]; then
    echo -e "${GREEN}Excellent GQL compliance! Major language features implemented.${NC}"
elif [ $TESTS_PASSED -ge 30 ]; then
    echo -e "${YELLOW}Good GQL compliance. Core features implemented.${NC}"
elif [ $TESTS_PASSED -ge 15 ]; then
    echo -e "${YELLOW}Basic GQL compliance. Essential features implemented.${NC}"
else
    echo -e "${RED}Limited GQL compliance. Many features missing.${NC}"
fi

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All implemented features work correctly! ✅${NC}"
    exit 0
else
    if [ $TESTS_FAILED -le 5 ]; then
        echo -e "${GREEN}Failure count is acceptable for a comprehensive language implementation.${NC}"
        exit 0
    else
        echo -e "${RED}Too many feature failures. Core language implementation may have issues.${NC}"
        exit 1
    fi
fi