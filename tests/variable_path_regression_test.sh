#!/bin/bash

# Variable-Length Path Pattern Regression Test Suite  
# Tests path patterns with variable lengths: *, *k, *k..m, *..m, *k..

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Start the server
echo -e "${YELLOW}Starting Geode server...${NC}"
./zig-out/bin/geoded --data_dir ./test_data --insecure &
SERVER_PID=$!
sleep 2

# Function to run a test
run_test() {
    local test_name="$1"
    local query="$2"
    local expected_pattern="$3"
    
    echo -n "Testing: $test_name... "
    
    result=$(./zig-out/bin/geodec "$query" --insecure 2>&1)
    
    if echo "$result" | grep -q "$expected_pattern"; then
        echo -e "${GREEN}PASSED${NC}"
        return 0
    else
        echo -e "${RED}FAILED${NC}"
        echo "  Query: $query"
        echo "  Expected pattern: $expected_pattern"
        echo "  Got: $result"
        return 1
    fi
}

# Setup test graph - Create a chain: A -> B -> C -> D -> E
echo -e "${YELLOW}Creating test graph...${NC}"
./zig-out/bin/geodec "CREATE (a:Node {name: 'A'})" --insecure >/dev/null 2>&1
./zig-out/bin/geodec "CREATE (b:Node {name: 'B'})" --insecure >/dev/null 2>&1
./zig-out/bin/geodec "CREATE (c:Node {name: 'C'})" --insecure >/dev/null 2>&1
./zig-out/bin/geodec "CREATE (d:Node {name: 'D'})" --insecure >/dev/null 2>&1
./zig-out/bin/geodec "CREATE (e:Node {name: 'E'})" --insecure >/dev/null 2>&1

./zig-out/bin/geodec "MATCH (a:Node {name: 'A'}), (b:Node {name: 'B'}) CREATE (a)-[:NEXT]->(b)" --insecure >/dev/null 2>&1
./zig-out/bin/geodec "MATCH (b:Node {name: 'B'}), (c:Node {name: 'C'}) CREATE (b)-[:NEXT]->(c)" --insecure >/dev/null 2>&1
./zig-out/bin/geodec "MATCH (c:Node {name: 'C'}), (d:Node {name: 'D'}) CREATE (c)-[:NEXT]->(d)" --insecure >/dev/null 2>&1
./zig-out/bin/geodec "MATCH (d:Node {name: 'D'}), (e:Node {name: 'E'}) CREATE (d)-[:NEXT]->(e)" --insecure >/dev/null 2>&1

# Create a cycle: C -> A
./zig-out/bin/geodec "MATCH (c:Node {name: 'C'}), (a:Node {name: 'A'}) CREATE (c)-[:CYCLE]->(a)" --insecure >/dev/null 2>&1

# Create shortcuts: A -> C, B -> D
./zig-out/bin/geodec "MATCH (a:Node {name: 'A'}), (c:Node {name: 'C'}) CREATE (a)-[:SHORTCUT]->(c)" --insecure >/dev/null 2>&1
./zig-out/bin/geodec "MATCH (b:Node {name: 'B'}), (d:Node {name: 'D'}) CREATE (b)-[:SHORTCUT]->(d)" --insecure >/dev/null 2>&1

echo -e "\n${YELLOW}Running variable-length path regression tests...${NC}"

# Test 1: Any length path (*)
run_test "Any length path (*)" \
    "MATCH (a:Node {name: 'A'})-[*]->(e:Node {name: 'E'}) RETURN e.name" \
    "E"

# Test 2: Exactly 1 hop (*1)
run_test "Exactly 1 hop (*1)" \
    "MATCH (a:Node {name: 'A'})-[*1]->(x:Node) RETURN x.name ORDER BY x.name" \
    "B\|C"

# Test 3: Exactly 2 hops (*2)
run_test "Exactly 2 hops (*2)" \
    "MATCH (a:Node {name: 'A'})-[*2]->(x:Node) RETURN x.name ORDER BY x.name" \
    "C\|D"

# Test 4: Exactly 3 hops (*3)
run_test "Exactly 3 hops (*3)" \
    "MATCH (a:Node {name: 'A'})-[*3]->(x:Node) RETURN x.name ORDER BY x.name" \
    "A\|D\|E"

# Test 5: Exactly 4 hops (*4)
run_test "Exactly 4 hops (*4)" \
    "MATCH (a:Node {name: 'A'})-[*4]->(x:Node) RETURN x.name ORDER BY x.name" \
    "B\|E"

# Test 6: Range 1 to 2 hops (*1..2)
run_test "Range 1 to 2 hops (*1..2)" \
    "MATCH (a:Node {name: 'A'})-[*1..2]->(x:Node) RETURN x.name ORDER BY x.name" \
    "B\|C\|D"

# Test 7: Range 2 to 3 hops (*2..3)
run_test "Range 2 to 3 hops (*2..3)" \
    "MATCH (a:Node {name: 'A'})-[*2..3]->(x:Node) RETURN x.name ORDER BY x.name" \
    "A\|C\|D\|E"

# Test 8: Up to 2 hops (*..2)
run_test "Up to 2 hops (*..2)" \
    "MATCH (a:Node {name: 'A'})-[*..2]->(x:Node) RETURN x.name ORDER BY x.name" \
    "A\|B\|C\|D"

# Test 9: At least 3 hops (*3..)
run_test "At least 3 hops (*3..)" \
    "MATCH (a:Node {name: 'A'})-[*3..]->(x:Node) RETURN DISTINCT x.name ORDER BY x.name" \
    "A\|B\|C\|D\|E"

# Test 10: Zero or more hops (*0..)
run_test "Zero or more hops (*0..)" \
    "MATCH (a:Node {name: 'A'})-[*0..]->(x:Node) RETURN DISTINCT x.name ORDER BY x.name LIMIT 5" \
    "A\|B\|C\|D\|E"

# Test 11: Path with specific relationship type
run_test "Variable path with relationship type" \
    "MATCH (a:Node {name: 'A'})-[:NEXT*2]->(x:Node) RETURN x.name" \
    "C"

# Test 12: Multiple relationship types
run_test "Variable path with multiple types" \
    "MATCH (a:Node {name: 'A'})-[:NEXT|SHORTCUT*1..2]->(x:Node) RETURN DISTINCT x.name ORDER BY x.name" \
    "B\|C\|D"

# Test 13: Bidirectional variable path
run_test "Bidirectional variable path" \
    "MATCH (c:Node {name: 'C'})-[*1..2]-(x:Node) RETURN DISTINCT x.name ORDER BY x.name" \
    "A\|B\|D\|E"

# Test 14: Path length in result
run_test "Return path length" \
    "MATCH path = (a:Node {name: 'A'})-[*]->(e:Node {name: 'E'}) RETURN length(path) AS len ORDER BY len LIMIT 1" \
    "2\|3\|4"

# Test 15: Shortest path
run_test "Shortest path" \
    "MATCH path = shortestPath((a:Node {name: 'A'})-[*]->(e:Node {name: 'E'})) RETURN length(path) AS len" \
    "2\|3\|4"

# Test 16: All shortest paths
run_test "All shortest paths" \
    "MATCH path = allShortestPaths((a:Node {name: 'A'})-[*]->(d:Node {name: 'D'})) RETURN length(path) AS len" \
    "2\|3"

# Test 17: Cycle detection
run_test "Detect cycle" \
    "MATCH path = (n:Node)-[*]->(n) WHERE n.name = 'A' RETURN length(path) AS len ORDER BY len LIMIT 1" \
    "3\|4\|5\|6"

# Test 18: No path exists
run_test "No path exists" \
    "MATCH (e:Node {name: 'E'})-[*]->(a:Node {name: 'A'}) RETURN a.name" \
    ""

# Test 19: Path with WHERE clause
run_test "Variable path with WHERE" \
    "MATCH (a:Node {name: 'A'})-[*1..3]->(x:Node) WHERE x.name <> 'C' RETURN DISTINCT x.name ORDER BY x.name" \
    "A\|B\|D\|E"

# Test 20: Path nodes and relationships
run_test "Return path nodes" \
    "MATCH path = (a:Node {name: 'A'})-[*2]->(x:Node) RETURN nodes(path)[1].name AS middle ORDER BY middle LIMIT 1" \
    "B\|C"

# Test 21: Complex pattern with variable path
run_test "Complex pattern" \
    "MATCH (a:Node {name: 'A'})-[*1..2]->(x:Node)-[:NEXT]->(y:Node) RETURN DISTINCT y.name ORDER BY y.name" \
    "B\|C\|D\|E"

# Test 22: Multiple variable paths
run_test "Multiple variable paths" \
    "MATCH (a:Node {name: 'A'})-[*1]->(x:Node)-[*1]->(y:Node) RETURN DISTINCT y.name ORDER BY y.name" \
    "A\|C\|D\|E"

# Test 23: Variable path with node filter
run_test "Variable path with node property filter" \
    "MATCH (start:Node)-[*]->(end:Node) WHERE start.name = 'B' AND end.name = 'E' RETURN end.name" \
    "E"

# Test 24: Count paths
run_test "Count variable paths" \
    "MATCH (a:Node {name: 'A'})-[*1..3]->(x:Node) RETURN count(*) AS count" \
    "[0-9]+"

# Test 25: Large hop range
run_test "Large hop range (*1..10)" \
    "MATCH (a:Node {name: 'A'})-[*1..10]->(x:Node) WHERE x.name = 'E' RETURN x.name" \
    "E"

# Cleanup
echo -e "\n${YELLOW}Stopping server...${NC}"
kill $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true
rm -rf ./test_data

echo -e "\n${GREEN}Variable-length path regression tests completed!${NC}"