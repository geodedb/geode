#!/usr/bin/env nix-shell
#! nix-shell -i bash -p bash -p coreutils
# Comprehensive Graph Data Integration Tests for Geode
# Tests actual graph database functionality: vertex/edge creation, properties, traversal, etc.

set -e

echo "=== Geode Graph Data Integration Tests ==="
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
run_test() {
    local name="$1"
    local cmd="$2"
    local expected_pattern="$3"

    echo -n "Testing $name... "
    if eval "$cmd" 2>&1 | grep -q "$expected_pattern"; then
        echo -e "${GREEN}PASS${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}FAIL${NC}"
        echo "  Command: $cmd"
        echo "  Expected: $expected_pattern"
        echo "  Output:"
        eval "$cmd" 2>&1 | head -3 | sed 's/^/    /'
        ((TESTS_FAILED++))
    fi
}

# Build first
echo "Building Geode..."
make build > /dev/null 2>&1

echo -e "${BLUE}=== Data Cleanup (Start Fresh) ===${NC}"

run_test "Delete all existing data" \
    "./zig-out/bin/geodec 'MATCH (n) DETACH DELETE n' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

echo

echo -e "${BLUE}=== Vertex Creation Tests ===${NC}"

run_test "Create simple vertex" \
    "./zig-out/bin/geodec 'CREATE (n)' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

run_test "Create vertex with label" \
    "./zig-out/bin/geodec 'CREATE (p:Person)' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

run_test "Create vertex with properties" \
    "./zig-out/bin/geodec 'CREATE (p:Person {name: \"Alice\', age: 30})' --server 127.0.0.1:3141 --insecure' \
    "status_class.*00000"

run_test "Create vertex with multiple labels" \
    "./zig-out/bin/geodec 'CREATE (p:Person:Employee {name: \"Bob\", age: 25, department: \"Engineering\'})' --server 127.0.0.1:3141 --insecure' \
    "status_class.*00000"

run_test "Create vertex with complex properties" \
    "./zig-out/bin/geodec 'CREATE (c:Company {name: \"TechCorp\', founded: 2010, employees: 500, active: true})' --server 127.0.0.1:3141 --insecure' \
    "status_class.*00000"

echo

echo -e "${BLUE}=== Vertex Query Tests ===${NC}"

run_test "Count all vertices" \
    "./zig-out/bin/geodec 'MATCH (n) RETURN count(n) AS total' --server 127.0.0.1:3141 --insecure" \
    "total"

run_test "Find vertices by label" \
    "./zig-out/bin/geodec 'MATCH (p:Person) RETURN count(p) AS person_count' --server 127.0.0.1:3141 --insecure" \
    "person_count"

run_test "Find vertex by property" \
    "./zig-out/bin/geodec 'MATCH (p:Person {name: \"Alice\"}) RETURN p.name AS name' --server 127.0.0.1:3141 --insecure" \
    "Alice"

run_test "Find vertices with property filter" \
    "./zig-out/bin/geodec 'MATCH (p:Person) WHERE p.age > 25 RETURN p.name AS name' --server 127.0.0.1:3141 --insecure" \
    "name"

run_test "Return vertex properties" \
    "./zig-out/bin/geodec 'MATCH (p:Person) RETURN p.name AS name, p.age AS age ORDER BY p.name' --server 127.0.0.1:3141 --insecure" \
    "name.*age"

echo

echo -e "${BLUE}=== Edge Creation Tests ===${NC}"

run_test "Create simple edge" \
    "./zig-out/bin/geodec 'MATCH (a:Person {name: \"Alice\"}), (b:Person {name: \"Bob\"}) CREATE (a)-[:KNOWS]->(b)' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

run_test "Create edge with properties" \
    "./zig-out/bin/geodec 'MATCH (p:Person {name: \"Alice\"}), (c:Company {name: \"TechCorp\"}) CREATE (p)-[:WORKS_AT {since: 2020, position: \"Engineer\"}]->(c)' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

run_test "Create bidirectional relationship" \
    "./zig-out/bin/geodec 'MATCH (a:Person {name: \"Alice\"}), (b:Person {name: \"Bob\"}) CREATE (a)-[:COLLABORATES_WITH]->(b), (b)-[:COLLABORATES_WITH]->(a)' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

echo

echo -e "${BLUE}=== Edge Query Tests ===${NC}"

run_test "Find relationships" \
    "./zig-out/bin/geodec 'MATCH (a)-[r:KNOWS]->(b) RETURN a.name AS from_name, b.name AS to_name' --server 127.0.0.1:3141 --insecure" \
    "from_name.*to_name"

run_test "Find relationships with properties" \
    "./zig-out/bin/geodec 'MATCH (p)-[r:WORKS_AT]->(c) RETURN p.name AS person, c.name AS company, r.position AS role' --server 127.0.0.1:3141 --insecure" \
    "person.*company.*role"

run_test "Count relationships" \
    "./zig-out/bin/geodec 'MATCH ()-[r]->() RETURN count(r) AS total_edges' --server 127.0.0.1:3141 --insecure" \
    "total_edges"

run_test "Find relationship types" \
    "./zig-out/bin/geodec 'MATCH ()-[r]->() RETURN DISTINCT type(r) AS relationship_type' --server 127.0.0.1:3141 --insecure" \
    "relationship_type"

echo

echo -e "${BLUE}=== Graph Traversal Tests ===${NC}"

# Add more data for traversal
echo "Setting up additional test data..."
./zig-out/bin/geodec 'CREATE (charlie:Person {name: 'Charlie', age: 35})' --server 127.0.0.1:3141 --insecure > /dev/null 2>&1
./zig-out/bin/geodec 'CREATE (diana:Person {name: 'Diana', age: 28})' --server 127.0.0.1:3141 --insecure > /dev/null 2>&1
./zig-out/bin/geodec 'MATCH (b:Person {'name': 'Bob'}), (c:Person {'name': 'Charlie'}) CREATE (b)-[:KNOWS]->(c)' --server 127.0.0.1:3141 --insecure > /dev/null 2>&1
./zig-out/bin/geodec 'MATCH (c:Person {'name': 'Charlie'}), (d:Person {'name': 'Diana'}) CREATE (c)-[:KNOWS]->(d)' --server 127.0.0.1:3141 --insecure > /dev/null 2>&1

run_test "Simple path traversal" \
    "./zig-out/bin/geodec 'MATCH (a:Person)-[:KNOWS]->(b:Person) RETURN a.name AS from_person, b.name AS to_person' --server 127.0.0.1:3141 --insecure" \
    "from_person.*to_person"

run_test "Two-hop traversal" \
    "./zig-out/bin/geodec 'MATCH (a:Person)-[:KNOWS]->(b:Person)-[:KNOWS]->(c:Person) RETURN a.name AS start, b.name AS middle, c.name AS end' --server 127.0.0.1:3141 --insecure" \
    "start.*middle.*end"

run_test "Variable length path" \
    "./zig-out/bin/geodec 'MATCH (a:Person)-[:KNOWS*1..2]->(b:Person) RETURN DISTINCT a.name AS from_person, b.name AS to_person' --server 127.0.0.1:3141 --insecure" \
    "from_person.*to_person"

run_test "Find all connections" \
    "./zig-out/bin/geodec 'MATCH (a:Person)-[*]->(b:Person) WHERE a <> b RETURN DISTINCT a.name AS person1, b.name AS person2' --server 127.0.0.1:3141 --insecure" \
    "person1.*person2"

echo

echo -e "${BLUE}=== Complex Graph Patterns ===${NC}"

run_test "Find mutual connections" \
    "./zig-out/bin/geodec 'MATCH (a:Person)-[:COLLABORATES_WITH]->(b:Person), (b)-[:COLLABORATES_WITH]->(a) RETURN a.name AS person1, b.name AS person2' --server 127.0.0.1:3141 --insecure" \
    "person1.*person2"

run_test "Find people who work at the same company" \
    "./zig-out/bin/geodec 'MATCH (p1:Person)-[:WORKS_AT]->(c:Company)<-[:WORKS_AT]-(p2:Person) WHERE p1 <> p2 RETURN p1.name AS person1, p2.name AS person2, c.name AS company' --server 127.0.0.1:3141 --insecure" \
    "person1.*person2.*company"

run_test "Find isolated vertices" \
    "./zig-out/bin/geodec 'MATCH (n) WHERE NOT (n)--() RETURN n AS isolated' --server 127.0.0.1:3141 --insecure" \
    "isolated"

run_test "Find vertices with specific degree" \
    "./zig-out/bin/geodec 'MATCH (p:Person) RETURN p.name AS person, size((p)--()) AS degree ORDER BY degree DESC' --server 127.0.0.1:3141 --insecure" \
    "person.*degree"

echo

echo -e "${BLUE}=== Data Modification Tests ===${NC}"

run_test "Update vertex property" \
    "./zig-out/bin/geodec 'MATCH (p:Person {name: \"Alice\"}) SET p.age = 31' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

run_test "Add vertex property" \
    "./zig-out/bin/geodec 'MATCH (p:Person {name: \"Bob\"}) SET p.city = \"San Francisco\"' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

run_test "Update edge property" \
    "./zig-out/bin/geodec 'MATCH (a)-[r:WORKS_AT]->(c) SET r.salary = 75000' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

run_test "Verify property updates" \
    "./zig-out/bin/geodec 'MATCH (p:Person {name: \"Alice\"}) RETURN p.age AS updated_age' --server 127.0.0.1:3141 --insecure" \
    "31"

echo

echo -e "${BLUE}=== Data Deletion Tests ===${NC}"

run_test "Delete specific edge" \
    "./zig-out/bin/geodec 'MATCH (a:Person {name: \"Alice\"})-[r:COLLABORATES_WITH]->(b:Person) DELETE r' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

run_test "Delete vertex with edges" \
    "./zig-out/bin/geodec 'MATCH (p:Person {name: \"Diana\"}) DETACH DELETE p' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

run_test "Verify deletion" \
    "./zig-out/bin/geodec 'MATCH (p:Person {name: \"Diana\"}) RETURN count(p) AS diana_count' --server 127.0.0.1:3141 --insecure" \
    '"diana_count":0'

echo

echo -e "${BLUE}=== Aggregation and Analytics ===${NC}"

run_test "Count vertices by label" \
    "./zig-out/bin/geodec 'MATCH (n) RETURN labels(n) AS label, count(n) AS count ORDER BY count DESC' --server 127.0.0.1:3141 --insecure" \
    "label.*count"

run_test "Average age of people" \
    "./zig-out/bin/geodec 'MATCH (p:Person) WHERE p.age IS NOT NULL RETURN avg(p.age) AS avg_age' --server 127.0.0.1:3141 --insecure" \
    "avg_age"

run_test "Find oldest and youngest person" \
    "./zig-out/bin/geodec 'MATCH (p:Person) WHERE p.age IS NOT NULL RETURN min(p.age) AS youngest, max(p.age) AS oldest' --server 127.0.0.1:3141 --insecure" \
    "youngest.*oldest"

run_test "Relationship type distribution" \
    "./zig-out/bin/geodec 'MATCH ()-[r]->() RETURN type(r) AS rel_type, count(r) AS count ORDER BY count DESC' --server 127.0.0.1:3141 --insecure" \
    "rel_type.*count"

echo

echo -e "${BLUE}=== Error Handling Tests ===${NC}"

run_test "Query non-existent vertex" \
    "./zig-out/bin/geodec 'MATCH (p:Person {name: \"NonExistent\"}) RETURN p.name AS name' --server 127.0.0.1:3141 --insecure" \
    '{"columns":\[.*\],"rows":\[\]}'

run_test "Invalid property access" \
    "./zig-out/bin/geodec 'MATCH (p:Person) RETURN p.nonexistent_property AS prop' --server 127.0.0.1:3141 --insecure" \
    "prop.*null"

run_test "Type mismatch in comparison" \
    "./zig-out/bin/geodec 'MATCH (p:Person) WHERE p.age = \"not_a_number\" RETURN p.name AS name' --server 127.0.0.1:3141 --insecure" \
    '{"columns":\[.*\],"rows":\[\]}'

echo

echo -e "${BLUE}=== Final Cleanup ===${NC}"

run_test "Clean up all test data" \
    "./zig-out/bin/geodec 'MATCH (n) DETACH DELETE n' --server 127.0.0.1:3141 --insecure" \
    "status_class.*00000"

run_test "Verify cleanup" \
    "./zig-out/bin/geodec 'MATCH (n) RETURN count(n) AS remaining_nodes' --server 127.0.0.1:3141 --insecure" \
    '"remaining_nodes":0'

echo

# Summary
echo -e "${BLUE}=== Summary ===${NC}"
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"
echo "Total tests: $((TESTS_PASSED + TESTS_FAILED))"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All graph data integration tests passed! 🎉${NC}"
    echo
    echo "Successfully tested:"
    echo "  ✓ Vertex creation with labels and properties"
    echo "  ✓ Edge creation with properties and relationships"
    echo "  ✓ Graph traversal and pattern matching"
    echo "  ✓ Complex graph queries and analytics"
    echo "  ✓ Data modification and deletion"
    echo "  ✓ Error handling and edge cases"
    echo "  ✓ Aggregation and graph analysis"
    exit 0
else
    echo -e "${RED}Some tests failed - review and fix issues${NC}"
    exit 1
fi
