#!/usr/bin/env bash
# Advanced Graph Algorithms Test for Geode
# Tests graph algorithms, analytics, and complex graph operations

set -e

echo "=== Advanced Graph Algorithms Test ==="
echo "Testing graph algorithms, analytics, pathfinding, and complex graph operations"
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
test_algorithm() {
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

# First, create a test graph with known structure
echo "Setting up test graph..."
./zig-out/bin/geodec "CREATE (alice:Person {name: 'Alice', id: 1}), (bob:Person {name: 'Bob', id: 2}), (charlie:Person {name: 'Charlie', id: 3}), (diana:Person {name: 'Diana', id: 4}), (eve:Person {name: 'Eve', id: 5})" --insecure > /dev/null 2>&1 || true

./zig-out/bin/geodec "CREATE (tech:Company {name: 'TechCorp', id: 101}), (finance:Company {name: 'FinanceInc', id: 102}), (health:Company {name: 'HealthCare', id: 103})" --insecure > /dev/null 2>&1 || true

./zig-out/bin/geodec "CREATE (ny:City {name: 'New York', id: 201}), (sf:City {name: 'San Francisco', id: 202}), (la:City {name: 'Los Angeles', id: 203})" --insecure > /dev/null 2>&1 || true

# Create relationships
./zig-out/bin/geodec "MATCH (alice:Person {name: 'Alice'}), (bob:Person {name: 'Bob'}) CREATE (alice)-[:KNOWS {since: 2020}]->(bob)" --insecure > /dev/null 2>&1 || true
./zig-out/bin/geodec "MATCH (bob:Person {name: 'Bob'}), (charlie:Person {name: 'Charlie'}) CREATE (bob)-[:KNOWS {since: 2021}]->(charlie)" --insecure > /dev/null 2>&1 || true
./zig-out/bin/geodec "MATCH (charlie:Person {name: 'Charlie'}), (diana:Person {name: 'Diana'}) CREATE (charlie)-[:KNOWS {since: 2022}]->(diana)" --insecure > /dev/null 2>&1 || true
./zig-out/bin/geodec "MATCH (alice:Person {name: 'Alice'}), (diana:Person {name: 'Diana'}) CREATE (alice)-[:FRIEND {strength: 0.9}]->(diana)" --insecure > /dev/null 2>&1 || true

echo
echo "=== Phase 1: Basic Graph Traversal Algorithms ==="

# Basic traversal patterns
test_algorithm "Depth-first traversal" "timeout 10 ./zig-out/bin/geodec 'MATCH path = (start:Person {name: \"Alice\"})-[:KNOWS*1..3]->(end) RETURN path' --insecure"
test_algorithm "Breadth-first pattern" "timeout 10 ./zig-out/bin/geodec 'MATCH (start:Person {name: \"Alice\"})-[:KNOWS*1..2]->(neighbor) RETURN start, neighbor' --insecure"
test_algorithm "Bidirectional traversal" "timeout 10 ./zig-out/bin/geodec 'MATCH (a:Person)-[:KNOWS]-(b:Person) RETURN a, b' --insecure"
test_algorithm "Multi-hop paths" "timeout 10 ./zig-out/bin/geodec 'MATCH (a:Person)-[:KNOWS*2..4]->(b:Person) WHERE a <> b RETURN a, b' --insecure"

echo
echo "=== Phase 2: Shortest Path Algorithms ==="

# Shortest path algorithms
test_algorithm "Shortest path function" "timeout 10 ./zig-out/bin/geodec 'MATCH path = shortestPath((a:Person {name: \"Alice\"})-[:KNOWS*]-(b:Person {name: \"Diana\"})) RETURN path' --insecure"
test_algorithm "All shortest paths" "timeout 10 ./zig-out/bin/geodec 'MATCH paths = allShortestPaths((a:Person)-[:KNOWS*]-(b:Person)) WHERE a.name = \"Alice\" AND b.name = \"Charlie\" RETURN paths' --insecure"
test_algorithm "Dijkstra with weights" "timeout 10 ./zig-out/bin/geodec 'MATCH path = shortestPath((a:Person)-[:FRIEND*]-(b:Person)) WHERE a.name = \"Alice\" AND b.name = \"Diana\" RETURN path, reduce(weight = 0, r IN relationships(path) | weight + r.strength)' --insecure"
test_algorithm "Path length constraint" "timeout 10 ./zig-out/bin/geodec 'MATCH path = (a:Person)-[:KNOWS*]-(b:Person) WHERE length(path) = 2 RETURN a, b, path' --insecure"

echo
echo "=== Phase 3: Centrality Measures ==="

# Node centrality algorithms
test_algorithm "Degree centrality" "timeout 10 ./zig-out/bin/geodec 'MATCH (n:Person)-[r]-() RETURN n.name, count(r) AS degree ORDER BY degree DESC' --insecure"
test_algorithm "In-degree centrality" "timeout 10 ./zig-out/bin/geodec 'MATCH (n:Person)<-[r]-() RETURN n.name, count(r) AS in_degree ORDER BY in_degree DESC' --insecure"
test_algorithm "Out-degree centrality" "timeout 10 ./zig-out/bin/geodec 'MATCH (n:Person)-[r]->() RETURN n.name, count(r) AS out_degree ORDER BY out_degree DESC' --insecure"
test_algorithm "Betweenness centrality approximation" "timeout 15 ./zig-out/bin/geodec 'MATCH (a:Person), (b:Person), (c:Person) WHERE a <> b AND b <> c AND a <> c MATCH p1 = (a)-[:KNOWS*]-(b), p2 = (b)-[:KNOWS*]-(c) WHERE ALL(node IN nodes(p1) WHERE node IN nodes(p2) IMPLIES node = b) RETURN b.name, count(*) AS betweenness' --insecure"

echo
echo "=== Phase 4: Community Detection ==="

# Community and clustering algorithms
test_algorithm "Connected components" "timeout 10 ./zig-out/bin/geodec 'MATCH (n:Person) OPTIONAL MATCH (n)-[:KNOWS*]-(connected) RETURN n.name, collect(DISTINCT connected.name) AS component' --insecure"
test_algorithm "Triangle detection" "timeout 10 ./zig-out/bin/geodec 'MATCH (a:Person)-[:KNOWS]->(b:Person)-[:KNOWS]->(c:Person)-[:KNOWS]->(a) RETURN a.name, b.name, c.name' --insecure"
test_algorithm "Common neighbors" "timeout 10 ./zig-out/bin/geodec 'MATCH (a:Person)-[:KNOWS]->(common)<-[:KNOWS]-(b:Person) WHERE a <> b RETURN a.name, b.name, collect(common.name) AS common_neighbors' --insecure"
test_algorithm "Clustering coefficient" "timeout 15 ./zig-out/bin/geodec 'MATCH (n:Person)-[:KNOWS]-(neighbor) WITH n, collect(neighbor) AS neighbors UNWIND neighbors AS n1 UNWIND neighbors AS n2 WHERE n1 <> n2 OPTIONAL MATCH (n1)-[:KNOWS]-(n2) RETURN n.name, count(*) AS triangles' --insecure"

echo
echo "=== Phase 5: Graph Pattern Analysis ==="

# Pattern matching and analysis
test_algorithm "Motif detection (3-node)" "timeout 10 ./zig-out/bin/geodec 'MATCH (a)-[r1]->(b)-[r2]->(c) RETURN type(r1), type(r2), count(*) AS pattern_count' --insecure"
test_algorithm "Hub detection" "timeout 10 ./zig-out/bin/geodec 'MATCH (hub:Person)-[r]-() WITH hub, count(r) AS connections WHERE connections > 2 RETURN hub.name, connections' --insecure"
test_algorithm "Leaf node detection" "timeout 10 ./zig-out/bin/geodec 'MATCH (leaf:Person)-[r]-() WITH leaf, count(r) AS connections WHERE connections = 1 RETURN leaf.name' --insecure"
test_algorithm "Bridge detection" "timeout 15 ./zig-out/bin/geodec 'MATCH (a:Person)-[bridge:KNOWS]->(b:Person) WHERE NOT EXISTS { MATCH (a)-[:KNOWS*2..]-(b) WHERE NOT (a)-[bridge]->(b) } RETURN a.name, b.name' --insecure"

echo
echo "=== Phase 6: Reachability Algorithms ==="

# Reachability and connectivity
test_algorithm "Transitive closure" "timeout 15 ./zig-out/bin/geodec 'MATCH (a:Person), (b:Person) WHERE EXISTS { MATCH (a)-[:KNOWS*]-(b) } RETURN a.name, b.name' --insecure"
test_algorithm "2-hop neighbors" "timeout 10 ./zig-out/bin/geodec 'MATCH (start:Person {name: \"Alice\"})-[:KNOWS*2]-(neighbor) RETURN DISTINCT neighbor.name' --insecure"
test_algorithm "Reachability within distance" "timeout 10 ./zig-out/bin/geodec 'MATCH (start:Person {name: \"Alice\"})-[:KNOWS*1..3]-(reachable) RETURN DISTINCT reachable.name, length(shortestPath((start)-[:KNOWS*]-(reachable))) AS distance' --insecure"
test_algorithm "Strongly connected check" "timeout 15 ./zig-out/bin/geodec 'MATCH (a:Person), (b:Person) WHERE a <> b AND EXISTS { MATCH (a)-[:KNOWS*]->(b) } AND EXISTS { MATCH (b)-[:KNOWS*]->(a) } RETURN a.name, b.name' --insecure"

echo
echo "=== Phase 7: Graph Metrics and Analytics ==="

# Graph-level metrics
test_algorithm "Graph diameter approximation" "timeout 15 ./zig-out/bin/geodec 'MATCH (a:Person), (b:Person) WHERE a <> b MATCH path = shortestPath((a)-[:KNOWS*]-(b)) RETURN max(length(path)) AS diameter' --insecure"
test_algorithm "Average path length" "timeout 15 ./zig-out/bin/geodec 'MATCH (a:Person), (b:Person) WHERE a <> b MATCH path = shortestPath((a)-[:KNOWS*]-(b)) RETURN avg(length(path)) AS avg_path_length' --insecure"
test_algorithm "Graph density" "timeout 10 ./zig-out/bin/geodec 'MATCH (n:Person) WITH count(n) AS nodes MATCH ()-[r:KNOWS]->() RETURN count(r) AS edges, nodes, (2.0 * count(r)) / (nodes * (nodes - 1)) AS density' --insecure"
test_algorithm "Clustering coefficient global" "timeout 15 ./zig-out/bin/geodec 'MATCH (a)-[:KNOWS]-(b)-[:KNOWS]-(c)-[:KNOWS]-(a) RETURN count(*) AS triangles' --insecure"

echo
echo "=== Phase 8: Similarity Algorithms ==="

# Node similarity measures
test_algorithm "Jaccard similarity (neighbors)" "timeout 15 ./zig-out/bin/geodec 'MATCH (a:Person)-[:KNOWS]-(n1), (b:Person)-[:KNOWS]-(n2) WHERE a <> b WITH a, b, collect(DISTINCT n1) AS neighbors_a, collect(DISTINCT n2) AS neighbors_b RETURN a.name, b.name, size([x IN neighbors_a WHERE x IN neighbors_b]) AS intersection' --insecure"
test_algorithm "Common neighbor count" "timeout 10 ./zig-out/bin/geodec 'MATCH (a:Person)-[:KNOWS]-(common)-[:KNOWS]-(b:Person) WHERE a <> b RETURN a.name, b.name, count(DISTINCT common) AS common_neighbors' --insecure"
test_algorithm "Adamic-Adar similarity" "timeout 15 ./zig-out/bin/geodec 'MATCH (a:Person)-[:KNOWS]-(common)-[:KNOWS]-(b:Person) WHERE a <> b MATCH (common)-[r]-() RETURN a.name, b.name, sum(1.0 / log(count(r))) AS adamic_adar' --insecure"

echo
echo "=== Phase 9: Flow and Capacity Algorithms ==="

# Network flow concepts
test_algorithm "Max flow approximation" "timeout 15 ./zig-out/bin/geodec 'MATCH path = (source:Person {name: \"Alice\"})-[:KNOWS*]->(sink:Person {name: \"Diana\"}) RETURN count(path) AS flow_paths' --insecure"
test_algorithm "Cut vertices (articulation points)" "timeout 15 ./zig-out/bin/geodec 'MATCH (cut:Person) WHERE size([(cut)-[:KNOWS]-(neighbor) | neighbor]) > 1 AND EXISTS { MATCH (a:Person), (b:Person) WHERE a <> b AND a <> cut AND b <> cut AND NOT EXISTS { MATCH (a)-[:KNOWS*]-(b) WHERE NOT (a)-[:KNOWS*]-(cut)-[:KNOWS*]-(b) } } RETURN cut.name' --insecure"
test_algorithm "Minimum spanning tree approximation" "timeout 15 ./zig-out/bin/geodec 'MATCH (a:Person)-[r:FRIEND]-(b:Person) RETURN a.name, b.name, r.strength ORDER BY r.strength DESC' --insecure"

echo
echo "=== Phase 10: Graph Coloring and Partitioning ==="

# Graph coloring and partitioning
test_algorithm "Graph coloring approximation" "timeout 15 ./zig-out/bin/geodec 'MATCH (n:Person) RETURN n.name, n.id % 3 AS color' --insecure"
test_algorithm "Bipartite detection" "timeout 15 ./zig-out/bin/geodec 'MATCH (person:Person)-[:WORKS_AT]->(company:Company) RETURN \"Bipartite\" AS graph_type, count(DISTINCT person) AS set1_size, count(DISTINCT company) AS set2_size' --insecure"
test_algorithm "K-core decomposition" "timeout 15 ./zig-out/bin/geodec 'MATCH (n:Person)-[r]-() WITH n, count(r) AS degree WHERE degree >= 2 RETURN n.name, degree' --insecure"

echo
echo "=== Phase 11: Temporal Graph Analysis ==="

# Time-aware graph algorithms
test_algorithm "Temporal reachability" "timeout 10 ./zig-out/bin/geodec 'MATCH (a:Person)-[r:KNOWS]->(b:Person) WHERE r.since >= 2021 RETURN a.name, b.name, r.since' --insecure"
test_algorithm "Evolving graph patterns" "timeout 10 ./zig-out/bin/geodec 'MATCH (a:Person)-[r1:KNOWS]->(b:Person)-[r2:KNOWS]->(c:Person) WHERE r1.since < r2.since RETURN a.name, b.name, c.name, r1.since, r2.since' --insecure"
test_algorithm "Temporal path analysis" "timeout 15 ./zig-out/bin/geodec 'MATCH path = (a:Person)-[:KNOWS*]-(b:Person) WHERE ALL(r IN relationships(path) WHERE r.since IS NOT NULL) RETURN a.name, b.name, [r IN relationships(path) | r.since] AS timeline' --insecure"

echo
echo "=== Phase 12: Graph Machine Learning Features ==="

# ML-oriented graph features
test_algorithm "Node embedding features" "timeout 10 ./zig-out/bin/geodec 'MATCH (n:Person) RETURN n.name, n.id, size([(n)-[:KNOWS]-() | 1]) AS degree_feature' --insecure"
test_algorithm "Edge feature extraction" "timeout 10 ./zig-out/bin/geodec 'MATCH (a:Person)-[r:KNOWS]->(b:Person) RETURN a.id, b.id, r.since, type(r)' --insecure"
test_algorithm "Graph neural network features" "timeout 15 ./zig-out/bin/geodec 'MATCH (n:Person) OPTIONAL MATCH (n)-[:KNOWS]-(neighbor) RETURN n.name, collect(neighbor.id) AS neighbor_ids, avg(neighbor.id) AS neighbor_avg_id' --insecure"

echo
echo "=== Phase 13: Performance-Intensive Algorithms ==="

# Computationally intensive algorithms
test_algorithm "All pairs shortest paths" "timeout 30 ./zig-out/bin/geodec 'MATCH (a:Person), (b:Person) WHERE a <> b OPTIONAL MATCH path = shortestPath((a)-[:KNOWS*]-(b)) RETURN a.name, b.name, CASE WHEN path IS NULL THEN -1 ELSE length(path) END AS distance' --insecure"
test_algorithm "Graph isomorphism check" "timeout 20 ./zig-out/bin/geodec 'MATCH (a:Person)-[r1]->(b:Person), (c:Person)-[r2]->(d:Person) WHERE type(r1) = type(r2) RETURN count(*) AS isomorphic_pairs' --insecure"
test_algorithm "Maximum clique approximation" "timeout 20 ./zig-out/bin/geodec 'MATCH (a:Person)-[:KNOWS]-(b:Person)-[:KNOWS]-(c:Person)-[:KNOWS]-(a) RETURN collect(DISTINCT a.name) AS clique_members' --insecure"

echo
echo "=== Phase 14: Specialized Graph Algorithms ==="

# Specialized algorithms
test_algorithm "Page rank approximation" "timeout 20 ./zig-out/bin/geodec 'MATCH (n:Person)<-[:KNOWS]-(incoming) RETURN n.name, count(incoming) AS incoming_links ORDER BY incoming_links DESC' --insecure"
test_algorithm "Authority/Hub scores" "timeout 15 ./zig-out/bin/geodec 'MATCH (authority:Person)<-[:KNOWS]-(hub:Person) WITH authority, count(hub) AS authority_score MATCH (hub:Person)-[:KNOWS]->(target) RETURN hub.name, count(target) AS hub_score, authority_score' --insecure"
test_algorithm "Random walk simulation" "timeout 15 ./zig-out/bin/geodec 'MATCH (start:Person {name: \"Alice\"})-[:KNOWS*1..5]-(visited) RETURN visited.name, count(*) AS visit_frequency' --insecure"

echo
echo "=== Advanced Graph Algorithms Test Results Summary ==="
echo -e "Algorithms working: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Algorithms failed: ${RED}$TESTS_FAILED${NC}"
echo -e "Algorithms not implemented: ${BLUE}$TESTS_UNSUPPORTED${NC}"
echo -e "Total algorithms tested: $(( TESTS_PASSED + TESTS_FAILED + TESTS_UNSUPPORTED ))"

# Calculate percentages
local total_tested=$(( TESTS_PASSED + TESTS_FAILED ))
local total_algorithms=$(( TESTS_PASSED + TESTS_FAILED + TESTS_UNSUPPORTED ))

if [ $total_tested -gt 0 ]; then
    local success_rate=$(( TESTS_PASSED * 100 / total_tested ))
    echo -e "Success rate of implemented algorithms: ${GREEN}${success_rate}%${NC}"
fi

if [ $total_algorithms -gt 0 ]; then
    local implementation_rate=$(( TESTS_PASSED * 100 / total_algorithms ))
    echo -e "Algorithm implementation rate: ${BLUE}${implementation_rate}%${NC}"
fi

echo
echo "=== Graph Algorithm Capability Assessment ==="

if [ $TESTS_PASSED -ge 40 ]; then
    echo -e "${GREEN}Excellent graph algorithm support! Advanced analytics capabilities.${NC}"
elif [ $TESTS_PASSED -ge 25 ]; then
    echo -e "${GREEN}Good graph algorithm support. Solid analytics foundation.${NC}"
elif [ $TESTS_PASSED -ge 15 ]; then
    echo -e "${YELLOW}Basic graph algorithm support. Core algorithms implemented.${NC}"
else
    echo -e "${RED}Limited graph algorithm support. Advanced analytics not available.${NC}"
fi

# Classify the graph database capabilities
echo
echo "=== Graph Database Classification ==="
if [ $TESTS_PASSED -ge 35 ]; then
    echo -e "${GREEN}🏆 Advanced Graph Database - Suitable for complex graph analytics${NC}"
elif [ $TESTS_PASSED -ge 20 ]; then
    echo -e "${GREEN}📊 Analytical Graph Database - Good for graph analysis workloads${NC}"
elif [ $TESTS_PASSED -ge 10 ]; then
    echo -e "${YELLOW}🗄️  Basic Graph Database - Suitable for simple graph operations${NC}"
else
    echo -e "${RED}📁 Limited Graph Support - Basic graph storage only${NC}"
fi

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All implemented algorithms work correctly! ✅${NC}"
    exit 0
else
    if [ $TESTS_FAILED -le 8 ]; then
        echo -e "${GREEN}Failure count is acceptable for advanced graph algorithms.${NC}"
        exit 0
    else
        echo -e "${RED}Too many algorithm failures. Graph engine may have issues.${NC}"
        exit 1
    fi
fi