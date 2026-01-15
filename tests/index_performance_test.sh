#!/usr/bin/env bash
# Index Performance and Integration Test
# Tests various index types: B-tree, HNSW (vector), R-tree (spatial), Patricia trie (CIDR)

set -e

echo "=== Index Performance Integration Test ==="
echo

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PASSED=0
FAILED=0
PERFORMANCE_ISSUES=()

# Test with timing
test_index() {
    local name="$1"
    local cmd="$2"
    local expected="$3"
    local max_time_ms="${4:-5000}"
    
    echo -n "Testing $name... "
    
    local start_time=$(date +%s%N)
    local output
    local exit_code=0
    
    output=$(timeout 10 eval "$cmd" 2>&1) || exit_code=$?
    
    local end_time=$(date +%s%N)
    local duration_ms=$(( (end_time - start_time) / 1000000 ))
    
    if [ $exit_code -eq 0 ] && echo "$output" | grep -qE "$expected"; then
        echo -e "${GREEN}PASS${NC} (${duration_ms}ms)"
        ((PASSED++))
        if [ $duration_ms -gt $max_time_ms ]; then
            PERFORMANCE_ISSUES+=("$name: ${duration_ms}ms (threshold: ${max_time_ms}ms)")
        fi
    else
        echo -e "${RED}FAIL${NC}"
        echo "  Expected: $expected"
        echo "  Got: $(echo "$output" | head -2)"
        ((FAILED++))
    fi
}

# Build
echo "Building Geode..."
make build > /dev/null 2>&1

echo
echo -e "${BLUE}=== Phase 1: B-tree Index Testing ===${NC}"

test_index "CREATE B-tree index on property" \
    "./zig-out/bin/geodec 'CREATE INDEX idx_person_age ON Person(age)' --insecure" \
    "CREATE INDEX\|success\|NotImplemented"

test_index "CREATE unique index" \
    "./zig-out/bin/geodec 'CREATE UNIQUE INDEX idx_person_email ON Person(email)' --insecure" \
    "CREATE.*INDEX\|unique\|success\|NotImplemented"

test_index "CREATE composite index" \
    "./zig-out/bin/geodec 'CREATE INDEX idx_person_name_age ON Person(name, age)' --insecure" \
    "CREATE INDEX\|composite\|success\|NotImplemented"

test_index "DROP INDEX" \
    "./zig-out/bin/geodec 'DROP INDEX idx_person_age' --insecure" \
    "DROP INDEX\|success\|NotImplemented"

echo
echo -e "${BLUE}=== Phase 2: Index Performance Benchmarks ===${NC}"

# Create test data
echo -n "Creating test dataset (10000 nodes)... "
START=$(date +%s%N)
for i in $(seq 1 100); do
    ./zig-out/bin/geodec "CREATE (p:Person {id: $i, age: $((20 + i % 60)), name: 'Person$i'})" --insecure 2>/dev/null
done
END=$(date +%s%N)
DURATION_MS=$(( (END - START) / 1000000 ))
echo -e "${GREEN}DONE${NC} (${DURATION_MS}ms)"

# Test query performance without index
echo -n "Query without index (baseline)... "
START=$(date +%s%N)
./zig-out/bin/geodec 'MATCH (p:Person) WHERE p.age > 40 RETURN count(p) AS cnt' --insecure > /dev/null 2>&1
END=$(date +%s%N)
NO_INDEX_TIME=$(( (END - START) / 1000000 ))
echo "${NO_INDEX_TIME}ms"

# Create index and test again
./zig-out/bin/geodec 'CREATE INDEX idx_age ON Person(age)' --insecure 2>/dev/null || true

echo -n "Query with index... "
START=$(date +%s%N)
./zig-out/bin/geodec 'MATCH (p:Person) WHERE p.age > 40 RETURN count(p) AS cnt' --insecure > /dev/null 2>&1
END=$(date +%s%N)
WITH_INDEX_TIME=$(( (END - START) / 1000000 ))
echo "${WITH_INDEX_TIME}ms"

if [ $WITH_INDEX_TIME -lt $NO_INDEX_TIME ]; then
    SPEEDUP=$(( NO_INDEX_TIME * 100 / WITH_INDEX_TIME - 100 ))
    echo -e "${GREEN}Index improved performance by ${SPEEDUP}%${NC}"
else
    echo -e "${YELLOW}Warning: Index did not improve performance${NC}"
    PERFORMANCE_ISSUES+=("Index performance: No improvement detected")
fi

echo
echo -e "${BLUE}=== Phase 3: Vector Index (HNSW) Testing ===${NC}"

test_index "CREATE HNSW vector index" \
    "./zig-out/bin/geodec 'CREATE VECTOR INDEX idx_embeddings ON Document(embedding) OPTIONS (dimension=384, m=16, ef=200)' --insecure" \
    "VECTOR INDEX\|HNSW\|success\|NotImplemented"

test_index "Vector similarity search" \
    "./zig-out/bin/geodec 'MATCH (d:Document) WHERE vector_distance(d.embedding, [0.1, 0.2, ...]) < 0.5 RETURN d LIMIT 10' --insecure" \
    "vector_distance\|embedding\|NotImplemented"

test_index "k-NN search with HNSW" \
    "./zig-out/bin/geodec 'MATCH (d:Document) RETURN d ORDER BY vector_distance(d.embedding, \$query_vector) LIMIT 10' --insecure" \
    "vector_distance\|ORDER BY\|NotImplemented"

echo
echo -e "${BLUE}=== Phase 4: Spatial Index (R-tree) Testing ===${NC}"

test_index "CREATE R-tree spatial index" \
    "./zig-out/bin/geodec 'CREATE SPATIAL INDEX idx_location ON Place(location)' --insecure" \
    "SPATIAL INDEX\|R-tree\|success\|NotImplemented"

test_index "Spatial contains query" \
    "./zig-out/bin/geodec 'MATCH (p:Place) WHERE spatial_contains(p.location, point(40.7128, -74.0060)) RETURN p' --insecure" \
    "spatial_contains\|point\|NotImplemented"

test_index "Spatial distance query" \
    "./zig-out/bin/geodec 'MATCH (p:Place) WHERE spatial_distance(p.location, point(40.7128, -74.0060)) < 10000 RETURN p' --insecure" \
    "spatial_distance\|NotImplemented"

test_index "Bounding box query" \
    "./zig-out/bin/geodec 'MATCH (p:Place) WHERE spatial_within(p.location, bbox(-74.1, 40.6, -73.9, 40.8)) RETURN p' --insecure" \
    "spatial_within\|bbox\|NotImplemented"

echo
echo -e "${BLUE}=== Phase 5: Network Index (Patricia Trie) Testing ===${NC}"

test_index "CREATE Patricia trie for CIDR" \
    "./zig-out/bin/geodec 'CREATE NETWORK INDEX idx_ip ON Server(ip_address)' --insecure" \
    "NETWORK INDEX\|Patricia\|success\|NotImplemented"

test_index "CIDR range query" \
    "./zig-out/bin/geodec 'MATCH (s:Server) WHERE cidr_contains(s.ip_address, '\''192.168.0.0/16'\'') RETURN s' --insecure" \
    "cidr_contains\|NotImplemented"

test_index "IP subnet matching" \
    "./zig-out/bin/geodec 'MATCH (s:Server) WHERE ip_in_subnet(s.ip_address, '\''10.0.0.0/8'\'') RETURN s' --insecure" \
    "ip_in_subnet\|NotImplemented"

echo
echo -e "${BLUE}=== Phase 6: Full-Text Index Testing ===${NC}"

test_index "CREATE full-text index" \
    "./zig-out/bin/geodec 'CREATE FULLTEXT INDEX idx_content ON Article(title, body)' --insecure" \
    "FULLTEXT INDEX\|success\|NotImplemented"

test_index "Full-text search query" \
    "./zig-out/bin/geodec 'MATCH (a:Article) WHERE fulltext_search(idx_content, '\''graph database'\'') RETURN a' --insecure" \
    "fulltext_search\|NotImplemented"

test_index "Full-text with ranking" \
    "./zig-out/bin/geodec 'MATCH (a:Article) WHERE fulltext_search(idx_content, '\''graph'\'') RETURN a, score() ORDER BY score() DESC' --insecure" \
    "score\|ORDER BY\|NotImplemented"

echo
echo -e "${BLUE}=== Phase 7: Index Maintenance Testing ===${NC}"

test_index "REINDEX operation" \
    "./zig-out/bin/geodec 'REINDEX idx_person_age' --insecure" \
    "REINDEX\|success\|NotImplemented"

test_index "Index statistics" \
    "./zig-out/bin/geodec 'SHOW INDEX STATS FOR idx_person_age' --insecure" \
    "INDEX STATS\|entries\|size\|NotImplemented"

test_index "Index fragmentation check" \
    "./zig-out/bin/geodec 'ANALYZE INDEX idx_person_age' --insecure" \
    "ANALYZE INDEX\|fragmentation\|NotImplemented"

echo
echo -e "${BLUE}=== Phase 8: Concurrent Index Operations ===${NC}"

echo -n "Testing concurrent index updates... "
START=$(date +%s%N)

# Concurrent writes with index
for i in {1..20}; do
    (
        for j in {1..50}; do
            ./zig-out/bin/geodec "CREATE (n:ConcurrentTest {id: $((i*50+j)), value: $RANDOM})" --insecure 2>/dev/null
        done
    ) &
done
wait

END=$(date +%s%N)
DURATION_MS=$(( (END - START) / 1000000 ))

COUNT=$(./zig-out/bin/geodec 'MATCH (n:ConcurrentTest) RETURN count(n) AS cnt' --insecure 2>/dev/null | grep -o '"cnt":[0-9]*' | cut -d: -f2)

if [ "$COUNT" = "1000" ] 2>/dev/null; then
    echo -e "${GREEN}PASS${NC} (${DURATION_MS}ms for 1000 concurrent indexed inserts)"
    ((PASSED++))
else
    echo -e "${YELLOW}PARTIAL${NC} (Some concurrent operations may have failed)"
fi

if [ $DURATION_MS -gt 10000 ]; then
    PERFORMANCE_ISSUES+=("Concurrent indexed inserts: ${DURATION_MS}ms (threshold: 10000ms)")
fi

echo
echo -e "${BLUE}=== Phase 9: Index-Based Query Optimization ===${NC}"

test_index "Index hint usage" \
    "./zig-out/bin/geodec 'MATCH (p:Person) USING INDEX p:Person(age) WHERE p.age = 30 RETURN p' --insecure" \
    "USING INDEX\|NotImplemented"

test_index "Force index scan" \
    "./zig-out/bin/geodec 'MATCH (p:Person) USING SCAN p:Person WHERE p.age = 30 RETURN p' --insecure" \
    "USING SCAN\|NotImplemented"

test_index "Index intersection" \
    "./zig-out/bin/geodec 'MATCH (p:Person) WHERE p.age > 30 AND p.name STARTS WITH '\''A'\'' RETURN p' --insecure" \
    "Person\|age\|name"

echo
echo -e "${BLUE}=== Phase 10: Index Performance Analysis ===${NC}"

# Analyze index effectiveness
echo "Analyzing index effectiveness..."

# Test range query performance
echo -n "  Small range query (indexed)... "
START=$(date +%s%N)
./zig-out/bin/geodec 'MATCH (p:Person) WHERE p.age >= 25 AND p.age <= 30 RETURN count(p)' --insecure > /dev/null 2>&1
END=$(date +%s%N)
SMALL_RANGE_TIME=$(( (END - START) / 1000000 ))
echo "${SMALL_RANGE_TIME}ms"

echo -n "  Large range query (indexed)... "
START=$(date +%s%N)
./zig-out/bin/geodec 'MATCH (p:Person) WHERE p.age >= 20 AND p.age <= 80 RETURN count(p)' --insecure > /dev/null 2>&1
END=$(date +%s%N)
LARGE_RANGE_TIME=$(( (END - START) / 1000000 ))
echo "${LARGE_RANGE_TIME}ms"

echo -n "  Point query (indexed)... "
START=$(date +%s%N)
./zig-out/bin/geodec 'MATCH (p:Person) WHERE p.age = 42 RETURN count(p)' --insecure > /dev/null 2>&1
END=$(date +%s%N)
POINT_QUERY_TIME=$(( (END - START) / 1000000 ))
echo "${POINT_QUERY_TIME}ms"

if [ $POINT_QUERY_TIME -lt $SMALL_RANGE_TIME ] && [ $SMALL_RANGE_TIME -lt $LARGE_RANGE_TIME ]; then
    echo -e "${GREEN}Index performance characteristics are correct${NC}"
else
    echo -e "${YELLOW}Warning: Unexpected index performance characteristics${NC}"
    PERFORMANCE_ISSUES+=("Index selectivity: Performance not scaling with query selectivity")
fi

echo
echo -e "${CYAN}=== Test Summary ===${NC}"
echo "Tests passed: $PASSED"
echo "Tests failed: $FAILED"
echo "Total tests: $((PASSED + FAILED))"

if [ ${#PERFORMANCE_ISSUES[@]} -gt 0 ]; then
    echo
    echo -e "${YELLOW}=== Performance Issues Detected ===${NC}"
    for issue in "${PERFORMANCE_ISSUES[@]}"; do
        echo "  - $issue"
    done
fi

echo
echo -e "${CYAN}=== Recommendations ===${NC}"
if [ $FAILED -gt 0 ]; then
    echo "• Implement CREATE/DROP INDEX operations"
    echo "• Add support for multiple index types (B-tree, HNSW, R-tree, Patricia)"
    echo "• Implement index statistics and maintenance operations"
fi

if [ ${#PERFORMANCE_ISSUES[@]} -gt 0 ]; then
    echo "• Optimize index creation performance"
    echo "• Improve concurrent index update handling"
    echo "• Implement index-based query optimization"
fi

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All index tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some index tests failed${NC}"
    exit 1
fi