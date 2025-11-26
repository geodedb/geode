#!/usr/bin/env nix-shell
#! nix-shell -i bash -p bash -p coreutils
# Comprehensive Graph Database Integration Test
# Systematically tests all graph database features and identifies issues to fix

set -e

echo "=== Comprehensive Geode Graph Database Test ==="
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PASSED=0
FAILED=0
ISSUES_FOUND=()

# Test function
test_feature() {
    local category="$1"
    local name="$2"
    local cmd="$3"
    local expected_pattern="$4"
    local expect_failure="${5:-false}"
    
    echo -n "[$category] Testing $name... "
    
    local output
    local exit_code
    output=$(timeout 10 bash -c "$cmd" 2>&1) || exit_code=$?
    
    if [ "$expect_failure" = "true" ]; then
        # We expect this to fail (known issue)
        if echo "$output" | grep -q "$expected_pattern"; then
            echo -e "${YELLOW}EXPECTED FAILURE${NC} (${expected_pattern})"
            ISSUES_FOUND+=("$category: $name - $expected_pattern")
        else
            echo -e "${RED}UNEXPECTED BEHAVIOR${NC}"
            echo "  Expected failure pattern: $expected_pattern"
            echo "  Actual output: $(echo "$output" | head -1)"
            ((FAILED++))
        fi
    else
        # We expect this to work
        if echo "$output" | grep -q "$expected_pattern"; then
            echo -e "${GREEN}PASS${NC}"
            ((PASSED++))
        else
            echo -e "${RED}FAIL${NC}"
            echo "  Command: $cmd"
            echo "  Expected: $expected_pattern"
            echo "  Actual: $(echo "$output" | head -1)"
            ((FAILED++))
            ISSUES_FOUND+=("$category: $name - Failed unexpectedly")
        fi
    fi
}

# Helper function to count created nodes (for verification)
count_nodes() {
    local count_output
    count_output=$(./zig-out/bin/geodec 'MATCH (n) RETURN count(n) AS total' --server 127.0.0.1:3141 --insecure 2>/dev/null | grep '"total":' | grep -o '[0-9]\+' || echo "0")
    echo "$count_output"
}

# Build first
echo "Building Geode..."
make build > /dev/null 2>&1

echo
echo -e "${BLUE}=== Phase 1: Basic Node Creation ===${NC}"

test_feature "NODE_CREATION" "Anonymous node" \
    "./zig-out/bin/geodec 'CREATE (n)' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

test_feature "NODE_CREATION" "Labeled node" \
    "./zig-out/bin/geodec 'CREATE (p:Person)' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

test_feature "NODE_CREATION" "Multiple labels" \
    "./zig-out/bin/geodec 'CREATE (p:Person:Employee)' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

test_feature "NODE_CREATION" "Integer properties" \
    "./zig-out/bin/geodec 'CREATE (p {age: 30, score: 95})' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

test_feature "NODE_CREATION" "Boolean properties" \
    "./zig-out/bin/geodec 'CREATE (p {active: true, verified: false})' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

test_feature "NODE_CREATION" "String properties" \
    "./zig-out/bin/geodec 'CREATE (p {name: \"Alice\'})' --server 127.0.0.1:3141 --insecure' \
    "ParseError\\|timeout\\|hang" \
    true

test_feature "NODE_CREATION" "Mixed properties" \
    "./zig-out/bin/geodec 'CREATE (p:Person {name: \"Alice\', age: 30, active: true})' --server 127.0.0.1:3141 --insecure' \
    "ParseError\\|timeout\\|hang" \
    true

echo
echo -e "${BLUE}=== Phase 2: Node Querying ===${NC}"

test_feature "NODE_QUERY" "Count all nodes" \
    "./zig-out/bin/geodec 'MATCH (n) RETURN count(n) AS total' --server 127.0.0.1:3141 --insecure" \
    '"total":'

test_feature "NODE_QUERY" "Find by label" \
    "./zig-out/bin/geodec 'MATCH (p:Person) RETURN count(p) AS person_count' --server 127.0.0.1:3141 --insecure" \
    '"person_count":'

test_feature "NODE_QUERY" "Property access" \
    "./zig-out/bin/geodec 'MATCH (p) WHERE p.age > 25 RETURN count(p) AS older' --server 127.0.0.1:3141 --insecure" \
    '"older":'

test_feature "NODE_QUERY" "Return node properties" \
    "./zig-out/bin/geodec 'MATCH (p) RETURN p.age AS age, p.active AS active' --server 127.0.0.1:3141 --insecure" \
    '"age":'

echo
echo -e "${BLUE}=== Phase 3: Edge Creation ===${NC}"

test_feature "EDGE_CREATION" "Simple edge" \
    "./zig-out/bin/geodec 'CREATE (a)-[:KNOWS]->(b)' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

test_feature "EDGE_CREATION" "Edge with properties" \
    "./zig-out/bin/geodec 'CREATE (a)-[:KNOWS {since: 2020}]->(b)' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

test_feature "EDGE_CREATION" "Labeled nodes with edge" \
    "./zig-out/bin/geodec 'CREATE (a:Person)-[:KNOWS]->(b:Person)' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

test_feature "EDGE_CREATION" "Complex pattern" \
    "./zig-out/bin/geodec 'CREATE (a:Person {age: 25})-[:WORKS_AT {since: 2020}]->(c:Company {name: \"TechCorp\"})' --server 127.0.0.1:3141 --insecure" \
    "ParseError\\|timeout\\|hang" \
    true

echo
echo -e "${BLUE}=== Phase 4: Edge Querying ===${NC}"

test_feature "EDGE_QUERY" "Count relationships" \
    "./zig-out/bin/geodec 'MATCH ()-[r]->() RETURN count(r) AS edge_count' --server 127.0.0.1:3141 --insecure" \
    '"edge_count":'

test_feature "EDGE_QUERY" "Find specific relationship" \
    "./zig-out/bin/geodec 'MATCH (a)-[r:KNOWS]->(b) RETURN count(r) AS knows_count' --server 127.0.0.1:3141 --insecure" \
    '"knows_count":'

test_feature "EDGE_QUERY" "Relationship properties" \
    "./zig-out/bin/geodec 'MATCH ()-[r]->() RETURN r.since AS since' --server 127.0.0.1:3141 --insecure" \
    '"since":'

test_feature "EDGE_QUERY" "Path traversal" \
    "./zig-out/bin/geodec 'MATCH (a)-[r:KNOWS]->(b) RETURN a, r, b' --server 127.0.0.1:3141 --insecure" \
    '"a":'

echo
echo -e "${BLUE}=== Phase 5: Data Modification ===${NC}"

test_feature "MODIFICATION" "SET property" \
    "./zig-out/bin/geodec 'MATCH (p) SET p.updated = true' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000\\|ParseError\\|NotImplemented" \
    true

test_feature "MODIFICATION" "UPDATE property" \
    "./zig-out/bin/geodec 'MATCH (p) WHERE p.age = 30 SET p.age = 31' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000\\|ParseError\\|NotImplemented" \
    true

test_feature "MODIFICATION" "DELETE relationship" \
    "./zig-out/bin/geodec 'MATCH (a)-[r:KNOWS]->(b) DELETE r' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000\\|ParseError\\|NotImplemented" \
    true

test_feature "MODIFICATION" "DELETE node" \
    "./zig-out/bin/geodec 'MATCH (n) WHERE n.age = 25 DELETE n' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000\\|ParseError\\|NotImplemented" \
    true

test_feature "MODIFICATION" "DETACH DELETE" \
    "./zig-out/bin/geodec 'MATCH (n) DETACH DELETE n' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000\\|ParseError\\|NotImplemented" \
    true

echo
echo -e "${BLUE}=== Phase 6: Advanced Queries ===${NC}"

test_feature "ADVANCED_QUERY" "Variable length paths" \
    "./zig-out/bin/geodec 'MATCH (a)-[*1..3]->(b) RETURN count(*) AS paths' --server 127.0.0.1:3141 --insecure" \
    '"paths":\\|ParseError\\|NotImplemented' \
    true

test_feature "ADVANCED_QUERY" "OPTIONAL MATCH" \
    "./zig-out/bin/geodec 'MATCH (a) OPTIONAL MATCH (a)-[r]->(b) RETURN a, b' --server 127.0.0.1:3141 --insecure" \
    '"a":\\|ParseError\\|NotImplemented' \
    true

test_feature "ADVANCED_QUERY" "UNION queries" \
    "./zig-out/bin/geodec 'MATCH (a:Person) RETURN a.age UNION MATCH (c:Company) RETURN c.employees' --server 127.0.0.1:3141 --insecure" \
    '"age":\\|ParseError\\|NotImplemented' \
    true

test_feature "ADVANCED_QUERY" "Subqueries" \
    "./zig-out/bin/geodec 'MATCH (p:Person) WHERE EXISTS { MATCH (p)-[:KNOWS]->() } RETURN p' --server 127.0.0.1:3141 --insecure" \
    '"p":\\|ParseError\\|NotImplemented' \
    true

echo
echo -e "${BLUE}=== Phase 7: Aggregation and Analytics ===${NC}"

test_feature "AGGREGATION" "COUNT function" \
    "./zig-out/bin/geodec 'MATCH (p:Person) RETURN count(p) AS total' --server 127.0.0.1:3141 --insecure" \
    '"total":'

test_feature "AGGREGATION" "SUM function" \
    "./zig-out/bin/geodec 'MATCH (p) WHERE p.age IS NOT NULL RETURN sum(p.age) AS total_age' --server 127.0.0.1:3141 --insecure" \
    '"total_age":'

test_feature "AGGREGATION" "AVG function" \
    "./zig-out/bin/geodec 'MATCH (p) WHERE p.age IS NOT NULL RETURN avg(p.age) AS avg_age' --server 127.0.0.1:3141 --insecure" \
    '"avg_age":'

test_feature "AGGREGATION" "MIN/MAX functions" \
    "./zig-out/bin/geodec 'MATCH (p) RETURN min(p.age) AS min_age, max(p.age) AS max_age' --server 127.0.0.1:3141 --insecure" \
    '"min_age":'

test_feature "AGGREGATION" "GROUP BY" \
    "./zig-out/bin/geodec 'MATCH (p) RETURN p.active, count(p) AS count GROUP BY p.active' --server 127.0.0.1:3141 --insecure" \
    '"active":\\|ParseError\\|NotImplemented' \
    true

echo
echo -e "${BLUE}=== Phase 8: Data Types ===${NC}"

test_feature "DATA_TYPES" "NULL values" \
    "./zig-out/bin/geodec 'CREATE (p {value: null})' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

test_feature "DATA_TYPES" "Negative numbers" \
    "./zig-out/bin/geodec 'CREATE (p {debt: -1000, score: -5.5})' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

test_feature "DATA_TYPES" "Large integers" \
    "./zig-out/bin/geodec 'CREATE (p {big: 9223372036854775807})' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

test_feature "DATA_TYPES" "Decimal numbers" \
    "./zig-out/bin/geodec 'CREATE (p {pi: 3.14159, e: 2.718})' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

test_feature "DATA_TYPES" "Arrays" \
    "./zig-out/bin/geodec 'CREATE (p {tags: [\"tag1\", \"tag2\", \"tag3\']})' --server 127.0.0.1:3141 --insecure' \
    "status_class.*00000\\|ParseError\\|NotImplemented" \
    true

echo
echo -e "${BLUE}=== Phase 9: Error Handling ===${NC}"

test_feature "ERROR_HANDLING" "Invalid syntax" \
    "./zig-out/bin/geodec 'INVALID QUERY SYNTAX' --server 127.0.0.1:3141 --insecure" \
    "ParseError\\|error"

test_feature "ERROR_HANDLING" "Non-existent property" \
    "./zig-out/bin/geodec 'MATCH (p) RETURN p.nonexistent AS prop' --server 127.0.0.1:3141 --insecure" \
    '"prop":'

test_feature "ERROR_HANDLING" "Type mismatch" \
    "./zig-out/bin/geodec 'MATCH (p) WHERE p.age = \"not_a_number\" RETURN p' --server 127.0.0.1:3141 --insecure" \
    '"p":'

test_feature "ERROR_HANDLING" "Division by zero" \
    "./zig-out/bin/geodec 'RETURN 1 / 0 AS result' --server 127.0.0.1:3141 --insecure" \
    "error\\|null\\|result"

echo
echo -e "${BLUE}=== Phase 10: Transactions ===${NC}"

test_feature "TRANSACTIONS" "BEGIN transaction" \
    "./zig-out/bin/geodec 'BEGIN' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000\\|ParseError\\|NotImplemented" \
    true

test_feature "TRANSACTIONS" "COMMIT transaction" \
    "./zig-out/bin/geodec 'COMMIT' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000\\|ParseError\\|NotImplemented" \
    true

test_feature "TRANSACTIONS" "ROLLBACK transaction" \
    "./zig-out/bin/geodec 'ROLLBACK' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000\\|ParseError\\|NotImplemented" \
    true

echo
echo -e "${CYAN}=== Test Summary ===${NC}"
echo
echo "Tests passed: $PASSED"
echo "Tests failed: $FAILED"
echo "Total tests: $((PASSED + FAILED))"
echo

if [ ${#ISSUES_FOUND[@]} -gt 0 ]; then
    echo -e "${YELLOW}=== Issues Identified for Fixing ===${NC}"
    printf '%s\n' "${ISSUES_FOUND[@]}" | sort | uniq
    echo
fi

echo -e "${CYAN}=== Next Steps ===${NC}"
echo "1. Fix string literal parsing in property expressions"
echo "2. Implement missing SET/DELETE operations"
echo "3. Add support for advanced query features"
echo "4. Implement proper transaction handling"
echo "5. Add support for arrays and complex data types"
echo "6. Create regression tests for all fixes"

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All expected tests passed! 🎉${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed unexpectedly - needs investigation${NC}"
    exit 1
fi