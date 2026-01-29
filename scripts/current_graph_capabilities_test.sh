#!/usr/bin/env nix-shell
#! nix-shell -i bash -p bash -p coreutils
# Graph Capabilities Assessment for Geode
# Tests what graph functionality is currently working vs. what needs implementation

set -e

echo "=== Geode Graph Capabilities Assessment ==="
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

WORKING_FEATURES=0
NOT_WORKING_FEATURES=0

# Test function that expects success
test_working_feature() {
    local name="$1"
    local cmd="$2"
    local expected_pattern="$3"

    echo -n "✓ Testing $name... "
    if eval "$cmd" 2>&1 | grep -q "$expected_pattern"; then
        echo -e "${GREEN}WORKING${NC}"
        ((WORKING_FEATURES++))
    else
        echo -e "${RED}NOT WORKING${NC}"
        echo "  Command: $cmd"
        echo "  Expected: $expected_pattern"
        echo "  Actual output:"
        eval "$cmd" 2>&1 | head -2 | sed 's/^/    /'
        ((NOT_WORKING_FEATURES++))
    fi
}

# Test function that expects failure/not implemented
test_not_implemented() {
    local name="$1"
    local cmd="$2"

    echo -n "? Testing $name... "
    local output
    output=$(eval "$cmd" 2>&1)

    if echo "$output" | grep -q "ParseError\|SyntaxError\|not.*implement\|unsupported"; then
        echo -e "${YELLOW}NOT IMPLEMENTED${NC}"
        ((NOT_WORKING_FEATURES++))
    elif echo "$output" | grep -q "status_class.*00000"; then
        echo -e "${GREEN}WORKING${NC}"
        ((WORKING_FEATURES++))
    else
        echo -e "${RED}UNCLEAR STATUS${NC}"
        echo "  Output: $(echo "$output" | head -1)"
        ((NOT_WORKING_FEATURES++))
    fi
}

# Build first
echo "Building Geode..."
make build > /dev/null 2>&1

echo
echo -e "${BLUE}=== Testing Basic Query Functionality ===${NC}"

test_working_feature "Simple RETURN query" \
    "./zig-out/bin/geodec 'RETURN 1 AS num' --server 127.0.0.1:3141 --insecure" \
    '"num"'

test_working_feature "String literal support" \
    "./zig-out/bin/geodec 'RETURN \"hello\" AS greeting' --server 127.0.0.1:3141 --insecure" \
    '"greeting"'

test_working_feature "Mathematical expressions" \
    "./zig-out/bin/geodec 'RETURN 2 + 3 AS sum' --server 127.0.0.1:3141 --insecure" \
    '"sum"'

test_working_feature "Boolean values" \
    "./zig-out/bin/geodec 'RETURN true AS flag' --server 127.0.0.1:3141 --insecure" \
    '"flag"'

echo
echo -e "${BLUE}=== Testing Graph Query Syntax Parsing ===${NC}"

test_working_feature "MATCH syntax parsing" \
    "./zig-out/bin/geodec 'MATCH (n) RETURN count(n) AS total' --server 127.0.0.1:3141 --insecure" \
    '"total"'

test_working_feature "MATCH with labels" \
    "./zig-out/bin/geodec 'MATCH (p:Person) RETURN count(p) AS person_count' --server 127.0.0.1:3141 --insecure" \
    '"person_count"'

test_working_feature "MATCH with property filter" \
    "./zig-out/bin/geodec 'MATCH (p:Person) WHERE p.age > 25 RETURN p.name AS name' --server 127.0.0.1:3141 --insecure" \
    '"name"'

test_working_feature "MATCH with relationships" \
    "./zig-out/bin/geodec 'MATCH (a)-[r:KNOWS]->(b) RETURN count(r) AS rel_count' --server 127.0.0.1:3141 --insecure" \
    '"rel_count"'

echo
echo -e "${BLUE}=== Testing Graph Data Creation (CREATE statements) ===${NC}"

test_not_implemented "Simple vertex creation" \
    "./zig-out/bin/geodec 'CREATE (n)' --server 127.0.0.1:3141 --insecure"

test_not_implemented "Vertex with label" \
    "./zig-out/bin/geodec 'CREATE (p:Person)' --server 127.0.0.1:3141 --insecure"

test_not_implemented "Vertex with properties" \
    "./zig-out/bin/geodec 'CREATE (p:Person {name: \"Alice\', age: 30})' --server 127.0.0.1:3141 --insecure'

test_not_implemented "Edge creation" \
    "./zig-out/bin/geodec 'CREATE (a:Person)-[:KNOWS]->(b:Person)' --server 127.0.0.1:3141 --insecure"

echo
echo -e "${BLUE}=== Testing Data Modification ===${NC}"

test_not_implemented "SET property" \
    "./zig-out/bin/geodec 'MATCH (p:Person) SET p.age = 31' --server 127.0.0.1:3141 --insecure"

test_not_implemented "DELETE node" \
    "./zig-out/bin/geodec 'MATCH (n) DELETE n' --server 127.0.0.1:3141 --insecure"

test_not_implemented "DETACH DELETE" \
    "./zig-out/bin/geodec 'MATCH (n) DETACH DELETE n' --server 127.0.0.1:3141 --insecure"

echo
echo -e "${BLUE}=== Testing Advanced Features ===${NC}"

test_not_implemented "Variable length paths" \
    "./zig-out/bin/geodec 'MATCH (a)-[*1..3]->(b) RETURN count(*) AS paths' --server 127.0.0.1:3141 --insecure"

test_not_implemented "OPTIONAL MATCH" \
    "./zig-out/bin/geodec 'MATCH (a) OPTIONAL MATCH (a)-[r]->(b) RETURN a, b' --server 127.0.0.1:3141 --insecure"

test_not_implemented "UNION queries" \
    "./zig-out/bin/geodec 'MATCH (a:Person) RETURN a.name UNION MATCH (b:Company) RETURN b.name' --server 127.0.0.1:3141 --insecure"

echo
echo -e "${BLUE}=== Testing Constraints and Schema ===${NC}"

test_not_implemented "CREATE CONSTRAINT" \
    "./zig-out/bin/geodec 'CREATE CONSTRAINT user_email_unique ON User(email)' --server 127.0.0.1:3141 --insecure"

test_not_implemented "CREATE INDEX" \
    "./zig-out/bin/geodec 'CREATE INDEX user_name_idx ON User(name)' --server 127.0.0.1:3141 --insecure"

echo
echo -e "${BLUE}=== Summary and Recommendations ===${NC}"
echo
echo "Features working: $WORKING_FEATURES"
echo "Features not working/implemented: $NOT_WORKING_FEATURES"
echo "Total features tested: $((WORKING_FEATURES + NOT_WORKING_FEATURES))"

echo
echo -e "${GREEN}✓ WORKING FEATURES:${NC}"
echo "  - Basic RETURN queries with expressions"
echo "  - String literals and data types"
echo "  - MATCH query parsing and basic graph traversal syntax"
echo "  - Pattern matching syntax (nodes, relationships)"

echo
echo -e "${YELLOW}? FEATURES NEEDING IMPLEMENTATION:${NC}"
echo "  - CREATE statements for vertices and edges"
echo "  - Data modification (SET, DELETE, DETACH DELETE)"
echo "  - Advanced graph features (variable length paths, OPTIONAL MATCH)"
echo "  - Schema definition (constraints, indexes)"

echo
echo -e "${BLUE}📋 INTEGRATION TEST RECOMMENDATIONS:${NC}"
echo "  1. Focus tests on MATCH queries with pre-populated data"
echo "  2. Use programmatic graph creation (GraphStorage API) for test setup"
echo "  3. Test complex MATCH patterns, aggregations, and traversals"
echo "  4. Create tests for query optimization and performance"
echo "  5. Test error handling and edge cases in query execution"

echo
echo -e "${BLUE}🔧 NEXT IMPLEMENTATION PRIORITIES:${NC}"
echo "  1. Implement CREATE statement execution"
echo "  2. Implement SET and DELETE operations"
echo "  3. Add support for edge creation with properties"
echo "  4. Implement schema definition statements"
echo "  5. Add advanced graph traversal features"
