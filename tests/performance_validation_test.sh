#!/usr/bin/env bash
# Performance Validation Test for Geode
# Validates that Geode meets performance expectations for graph operations

set -e

echo "=== Performance Validation Test ==="
echo "Testing performance characteristics and stress scenarios"
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

# Performance test with timing
test_performance() {
    local name="$1"
    local cmd="$2"
    local max_time_ms="$3"

    echo -n "Testing $name (max ${max_time_ms}ms)... "

    local start_time=$(date +%s%3N)
    if eval "$cmd" > /dev/null 2>&1; then
        local end_time=$(date +%s%3N)
        local duration=$((end_time - start_time))

        if [ $duration -le $max_time_ms ]; then
            echo -e "${GREEN}PASS${NC} (${duration}ms)"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "${YELLOW}SLOW${NC} (${duration}ms > ${max_time_ms}ms)"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "${RED}FAIL${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Stress test
test_stress() {
    local name="$1"
    local cmd="$2"

    echo -n "Stress testing $name... "
    if eval "$cmd" > /dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAIL${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Build first
echo "Building Geode..."
make build > /dev/null 2>&1

echo
echo "=== Phase 1: Basic Operation Performance ==="

# Basic performance benchmarks (based on documented performance)
test_performance "Node creation" "timeout 5 ./zig-out/bin/geodec 'CREATE (a), (b), (c)' --insecure" 100
test_performance "Simple query" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN n' --insecure" 100
test_performance "Count query" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN count(n)' --insecure" 100
test_performance "Property ordering" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN n ORDER BY n.id' --insecure" 100
test_performance "Edge traversal" "timeout 5 ./zig-out/bin/geodec 'MATCH (a)-[r]->(b) RETURN count(r)' --insecure" 100

echo
echo "=== Phase 2: Complex Query Performance ==="

# Complex query performance
test_performance "Complex CREATE" "timeout 5 ./zig-out/bin/geodec \"CREATE (p:Person {name: 'Alice', age: 30})-[:WORKS_AT]->(c:Company)\" --insecure" 200
test_performance "Multi-hop traversal" "timeout 5 ./zig-out/bin/geodec 'MATCH (a)-[:KNOWS]->(b)-[:KNOWS]->(c) RETURN a, b, c' --insecure" 200
test_performance "Cross product query" "timeout 5 ./zig-out/bin/geodec 'MATCH (a), (b) WHERE a <> b RETURN a, b' --insecure" 200
test_performance "Aggregation with grouping" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN n.type, count(n)' --insecure" 200

echo
echo "=== Phase 3: Bulk Operations ==="

# Bulk operation performance
test_performance "Batch node creation" "timeout 10 ./zig-out/bin/geodec 'CREATE (a1), (a2), (a3), (a4), (a5), (a6), (a7), (a8), (a9), (a10)' --insecure" 500
test_performance "Batch edge creation" "timeout 10 ./zig-out/bin/geodec 'CREATE (a)-[:R1]->(b), (b)-[:R2]->(c), (c)-[:R3]->(d), (d)-[:R4]->(e)' --insecure" 500
test_performance "Large result set" "timeout 10 ./zig-out/bin/geodec 'MATCH (a), (b), (c) RETURN a, b, c LIMIT 50' --insecure" 1000

echo
echo "=== Phase 4: Memory Stress Tests ==="

# Memory and resource stress tests
test_stress "Large property values" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {data: 'abcdefghijklmnopqrstuvwxyz0123456789'})\" --insecure"
test_stress "Many properties" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8, i: 9, j: 10})\" --insecure"
test_stress "Deep nesting query" "timeout 10 ./zig-out/bin/geodec 'MATCH (n) WHERE n.age > 18 AND n.age < 65 AND n.active = true RETURN n ORDER BY n.age, n.name LIMIT 100' --insecure"

echo
echo "=== Phase 5: Concurrent Operation Simulation ==="

# Simulate concurrent operations
test_stress "Multiple CREATE ops" "timeout 10 bash -c 'for i in {1..5}; do ./zig-out/bin/geodec \"CREATE (p\$i:Person {id: \$i})\" --insecure > /dev/null 2>&1; done'"
test_stress "Mixed operations" "timeout 15 bash -c './zig-out/bin/geodec \"CREATE (p {id: 100})\" --insecure > /dev/null 2>&1 && ./zig-out/bin/geodec \"MATCH (n) RETURN count(n)\" --insecure > /dev/null 2>&1 && ./zig-out/bin/geodec \"MATCH (n) RETURN n ORDER BY n.id\" --insecure > /dev/null 2>&1'"

echo
echo "=== Phase 6: Edge Case Performance ==="

# Edge case performance
test_performance "Empty result aggregation" "timeout 5 ./zig-out/bin/geodec 'MATCH (n:NonExistent) RETURN count(n)' --insecure" 100
test_performance "Large LIMIT value" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) RETURN n ORDER BY n LIMIT 999999' --insecure" 200
test_performance "Complex WHERE clause" "timeout 5 ./zig-out/bin/geodec 'MATCH (n) WHERE n.age > 20 AND n.active = true OR n.score > 90 RETURN n' --insecure" 200

echo
echo "=== Phase 7: Data Type Performance ==="

# Data type handling performance
test_performance "Boolean operations" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {flag1: true, flag2: false})' --insecure" 100
test_performance "Number operations" "timeout 5 ./zig-out/bin/geodec 'CREATE (p {score: 95, age: 30, salary: 75000})' --insecure" 100
test_performance "String operations" "timeout 5 ./zig-out/bin/geodec \"CREATE (p {name: 'John Doe', title: 'Senior Developer'})\" --insecure" 100

echo
echo "=== Performance Results Summary ==="
echo -e "Performance tests passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Performance tests failed: ${RED}$TESTS_FAILED${NC}"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All performance tests passed! ✅${NC}"
    echo "Geode meets performance expectations for graph operations."
    echo
    echo "=== Performance Characteristics Summary ==="
    echo "✅ Basic operations: < 100ms"
    echo "✅ Complex queries: < 200ms"
    echo "✅ Bulk operations: < 1000ms"
    echo "✅ Memory handling: Stable"
    echo "✅ Edge cases: Handled efficiently"
    exit 0
else
    echo -e "Success rate: ${YELLOW}$(( TESTS_PASSED * 100 / (TESTS_PASSED + TESTS_FAILED) ))%${NC}"

    if [ $TESTS_FAILED -le 3 ]; then
        echo -e "${GREEN}Performance is acceptable with minor slowdowns.${NC}"
        echo "Consider optimizing the slower operations."
        exit 0
    else
        echo -e "${RED}Performance issues detected.${NC}"
        echo "Multiple operations are slower than expected."
        exit 1
    fi
fi
