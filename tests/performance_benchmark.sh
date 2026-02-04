#!/usr/bin/env bash
# Comprehensive Performance Benchmarking Suite
# Identifies performance bottlenecks and slow operations

set -e

echo "=== Geode Performance Benchmarking Suite ==="
echo

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Performance thresholds (ms)
THRESHOLD_SIMPLE_QUERY=50
THRESHOLD_COMPLEX_QUERY=500
THRESHOLD_INSERT=20
THRESHOLD_UPDATE=30
THRESHOLD_DELETE=25
THRESHOLD_TRAVERSAL=100

SLOW_OPERATIONS=()
PERFORMANCE_GRADES=()

# Benchmark function
benchmark() {
    local name="$1"
    local cmd="$2"
    local iterations="${3:-10}"
    local threshold="${4:-100}"

    echo -n "Benchmarking $name ($iterations iterations)... "

    local total_time=0
    local min_time=999999
    local max_time=0
    local failures=0

    for i in $(seq 1 $iterations); do
        local start=$(date +%s%N)
        timeout 5 eval "$cmd" > /dev/null 2>&1 || ((failures++))
        local end=$(date +%s%N)
        local duration=$(( (end - start) / 1000000 ))

        total_time=$((total_time + duration))
        [ $duration -lt $min_time ] && min_time=$duration
        [ $duration -gt $max_time ] && max_time=$duration
    done

    local avg_time=$((total_time / iterations))

    # Determine performance grade
    local grade color
    if [ $avg_time -le $threshold ]; then
        grade="A"
        color=$GREEN
    elif [ $avg_time -le $((threshold * 2)) ]; then
        grade="B"
        color=$CYAN
    elif [ $avg_time -le $((threshold * 3)) ]; then
        grade="C"
        color=$YELLOW
    elif [ $avg_time -le $((threshold * 5)) ]; then
        grade="D"
        color=$MAGENTA
    else
        grade="F"
        color=$RED
        SLOW_OPERATIONS+=("$name: avg=${avg_time}ms (threshold=${threshold}ms)")
    fi

    echo -e "${color}Grade: $grade${NC}"
    echo "  Avg: ${avg_time}ms | Min: ${min_time}ms | Max: ${max_time}ms | Failures: $failures"

    PERFORMANCE_GRADES+=("$name:$grade")
}

# Build
echo "Building Geode with optimizations..."
make release > /dev/null 2>&1 || make build > /dev/null 2>&1

# Start server
echo "Starting server..."
./zig-out/bin/geode serve --listen 0.0.0.0:8443 > /tmp/perf_server.log 2>&1 &
SERVER_PID=$!
sleep 2

# Cleanup on exit
trap "kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null; rm -f /tmp/perf_server.log" EXIT

echo
echo -e "${BLUE}=== Phase 1: Basic Operation Benchmarks ===${NC}"

benchmark "Simple RETURN query" \
    "./zig-out/bin/geode query 'RETURN 1 AS x' --insecure" \
    50 \
    $THRESHOLD_SIMPLE_QUERY

benchmark "Simple CREATE node" \
    "./zig-out/bin/geode query 'CREATE (n:BenchNode {id: \$RANDOM})' --insecure" \
    50 \
    $THRESHOLD_INSERT

benchmark "Simple MATCH query" \
    "./zig-out/bin/geode query 'MATCH (n) RETURN count(n) AS cnt' --insecure" \
    50 \
    $THRESHOLD_SIMPLE_QUERY

echo
echo -e "${BLUE}=== Phase 2: Data Insertion Performance ===${NC}"

# Create test dataset for benchmarks
echo -n "Creating test dataset (1000 nodes)... "
START=$(date +%s%N)
for i in $(seq 1 1000); do
    ./zig-out/bin/geode query "CREATE (p:Person {id: $i, name: 'Person$i', age: $((20 + i % 60))})" --insecure 2>/dev/null
done
END=$(date +%s%N)
SETUP_TIME=$(( (END - START) / 1000000 ))
echo "${SETUP_TIME}ms"

benchmark "Single node insertion" \
    "./zig-out/bin/geode query 'CREATE (n:TestNode {id: \$RANDOM, timestamp: timestamp()})' --insecure" \
    100 \
    $THRESHOLD_INSERT

benchmark "Node with multiple properties" \
    "./zig-out/bin/geode query 'CREATE (n:Complex {id: \$RANDOM, name: '\''test'\'', age: 25, active: true, score: 3.14})' --insecure" \
    50 \
    $((THRESHOLD_INSERT * 2))

benchmark "Batch insertion (10 nodes)" \
    "for i in {1..10}; do ./zig-out/bin/geode query 'CREATE (n:Batch {id: '\$i'})' --insecure; done" \
    10 \
    $((THRESHOLD_INSERT * 10))

echo
echo -e "${BLUE}=== Phase 3: Query Performance ===${NC}"

benchmark "Point query (exact match)" \
    "./zig-out/bin/geode query 'MATCH (p:Person {id: 500}) RETURN p.name' --insecure" \
    50 \
    $THRESHOLD_SIMPLE_QUERY

benchmark "Range query" \
    "./zig-out/bin/geode query 'MATCH (p:Person) WHERE p.age >= 30 AND p.age <= 40 RETURN count(p)' --insecure" \
    30 \
    $THRESHOLD_COMPLEX_QUERY

benchmark "Pattern matching" \
    "./zig-out/bin/geode query 'MATCH (p:Person) WHERE p.name STARTS WITH '\''Person1'\'' RETURN count(p)' --insecure" \
    30 \
    $THRESHOLD_COMPLEX_QUERY

benchmark "Aggregation query" \
    "./zig-out/bin/geode query 'MATCH (p:Person) RETURN avg(p.age) AS avg_age, min(p.age) AS min_age, max(p.age) AS max_age' --insecure" \
    20 \
    $THRESHOLD_COMPLEX_QUERY

echo
echo -e "${BLUE}=== Phase 4: Graph Traversal Performance ===${NC}"

# Create relationships for traversal tests
echo -n "Creating relationships... "
for i in $(seq 1 100); do
    j=$((i + 1))
    ./zig-out/bin/geode query "MATCH (a:Person {id: $i}), (b:Person {id: $j}) CREATE (a)-[:KNOWS]->(b)" --insecure 2>/dev/null
done
echo "Done"

benchmark "Single-hop traversal" \
    "./zig-out/bin/geode query 'MATCH (p:Person {id: 1})-[:KNOWS]->(friend) RETURN count(friend)' --insecure" \
    30 \
    $THRESHOLD_TRAVERSAL

benchmark "Two-hop traversal" \
    "./zig-out/bin/geode query 'MATCH (p:Person {id: 1})-[:KNOWS*2]->(foaf) RETURN count(foaf)' --insecure" \
    20 \
    $((THRESHOLD_TRAVERSAL * 2))

benchmark "Variable-length path" \
    "./zig-out/bin/geode query 'MATCH path = (p:Person {id: 1})-[:KNOWS*1..3]->() RETURN count(path)' --insecure" \
    10 \
    $((THRESHOLD_TRAVERSAL * 3))

echo
echo -e "${BLUE}=== Phase 5: Update Operations ===${NC}"

benchmark "Simple property update" \
    "./zig-out/bin/geode query 'MATCH (p:Person {id: 100}) SET p.updated = true' --insecure" \
    50 \
    $THRESHOLD_UPDATE

benchmark "Computed property update" \
    "./zig-out/bin/geode query 'MATCH (p:Person {id: 100}) SET p.age = p.age + 1' --insecure" \
    50 \
    $THRESHOLD_UPDATE

benchmark "Multiple property update" \
    "./zig-out/bin/geode query 'MATCH (p:Person {id: 100}) SET p.updated = true, p.timestamp = timestamp(), p.version = 2' --insecure" \
    30 \
    $((THRESHOLD_UPDATE * 2))

echo
echo -e "${BLUE}=== Phase 6: Delete Operations ===${NC}"

benchmark "Delete single node" \
    "./zig-out/bin/geode query 'MATCH (n:TestNode) DELETE n LIMIT 1' --insecure" \
    20 \
    $THRESHOLD_DELETE

benchmark "Delete relationship" \
    "./zig-out/bin/geode query 'MATCH ()-[r:KNOWS]->() DELETE r LIMIT 1' --insecure" \
    20 \
    $THRESHOLD_DELETE

benchmark "DETACH DELETE" \
    "./zig-out/bin/geode query 'MATCH (n:Batch) DETACH DELETE n LIMIT 1' --insecure" \
    20 \
    $THRESHOLD_DELETE

echo
echo -e "${BLUE}=== Phase 7: Sorting and Pagination ===${NC}"

benchmark "ORDER BY single property" \
    "./zig-out/bin/geode query 'MATCH (p:Person) RETURN p.name ORDER BY p.age LIMIT 10' --insecure" \
    20 \
    $THRESHOLD_COMPLEX_QUERY

benchmark "ORDER BY multiple properties" \
    "./zig-out/bin/geode query 'MATCH (p:Person) RETURN p ORDER BY p.age DESC, p.name ASC LIMIT 10' --insecure" \
    20 \
    $((THRESHOLD_COMPLEX_QUERY * 2))

benchmark "SKIP and LIMIT" \
    "./zig-out/bin/geode query 'MATCH (p:Person) RETURN p ORDER BY p.id SKIP 100 LIMIT 50' --insecure" \
    20 \
    $THRESHOLD_COMPLEX_QUERY

echo
echo -e "${BLUE}=== Phase 8: Complex Query Patterns ===${NC}"

benchmark "Multiple MATCH clauses" \
    "./zig-out/bin/geode query 'MATCH (a:Person) WHERE a.age > 30 MATCH (b:Person) WHERE b.age < 25 RETURN count(a) + count(b)' --insecure" \
    10 \
    $((THRESHOLD_COMPLEX_QUERY * 2))

benchmark "OPTIONAL MATCH" \
    "./zig-out/bin/geode query 'MATCH (p:Person) OPTIONAL MATCH (p)-[:KNOWS]->(friend) RETURN p.name, friend.name LIMIT 10' --insecure" \
    10 \
    $((THRESHOLD_COMPLEX_QUERY * 2))

benchmark "WITH clause chain" \
    "./zig-out/bin/geode query 'MATCH (p:Person) WITH p WHERE p.age > 30 WITH p ORDER BY p.age LIMIT 10 RETURN p.name' --insecure" \
    10 \
    $((THRESHOLD_COMPLEX_QUERY * 2))

echo
echo -e "${BLUE}=== Phase 9: Concurrent Operations ===${NC}"

echo -n "Testing concurrent reads (100 queries)... "
START=$(date +%s%N)
for i in {1..100}; do
    ./zig-out/bin/geode query 'MATCH (p:Person) RETURN count(p)' --insecure 2>/dev/null &
done
wait
END=$(date +%s%N)
CONCURRENT_READ_TIME=$(( (END - START) / 1000000 ))
echo "${CONCURRENT_READ_TIME}ms total, $((CONCURRENT_READ_TIME / 100))ms avg per query"

echo -n "Testing concurrent writes (50 inserts)... "
START=$(date +%s%N)
for i in {1..50}; do
    ./zig-out/bin/geode query "CREATE (n:ConcurrentTest {id: $i})" --insecure 2>/dev/null &
done
wait
END=$(date +%s%N)
CONCURRENT_WRITE_TIME=$(( (END - START) / 1000000 ))
echo "${CONCURRENT_WRITE_TIME}ms total, $((CONCURRENT_WRITE_TIME / 50))ms avg per insert"

echo
echo -e "${BLUE}=== Phase 10: Memory and Resource Usage ===${NC}"

echo "Analyzing resource usage..."

# Get server PID memory usage
if [ -f /proc/$SERVER_PID/status ]; then
    MEM_KB=$(grep VmRSS /proc/$SERVER_PID/status | awk '{print $2}')
    MEM_MB=$((MEM_KB / 1024))
    echo "  Server memory usage: ${MEM_MB}MB"

    if [ $MEM_MB -gt 500 ]; then
        echo -e "  ${YELLOW}Warning: High memory usage detected${NC}"
        SLOW_OPERATIONS+=("Memory usage: ${MEM_MB}MB (threshold: 500MB)")
    fi
fi

# Test memory behavior under load
echo -n "  Testing memory stability (creating 1000 nodes)... "
START_MEM=$MEM_KB
for i in {1..1000}; do
    ./zig-out/bin/geode query "CREATE (n:MemTest {id: $i, data: 'x'})" --insecure 2>/dev/null
done
if [ -f /proc/$SERVER_PID/status ]; then
    END_MEM=$(grep VmRSS /proc/$SERVER_PID/status | awk '{print $2}')
    MEM_GROWTH=$((END_MEM - START_MEM))
    echo "Memory grew by $((MEM_GROWTH / 1024))MB"

    if [ $MEM_GROWTH -gt 102400 ]; then  # 100MB growth
        echo -e "  ${YELLOW}Warning: Excessive memory growth${NC}"
        SLOW_OPERATIONS+=("Memory growth: $((MEM_GROWTH / 1024))MB for 1000 nodes")
    fi
fi

echo
echo -e "${CYAN}=== Performance Report Card ===${NC}"

# Calculate overall grade
A_COUNT=$(echo "${PERFORMANCE_GRADES[@]}" | grep -o ":A" | wc -l)
B_COUNT=$(echo "${PERFORMANCE_GRADES[@]}" | grep -o ":B" | wc -l)
C_COUNT=$(echo "${PERFORMANCE_GRADES[@]}" | grep -o ":C" | wc -l)
D_COUNT=$(echo "${PERFORMANCE_GRADES[@]}" | grep -o ":D" | wc -l)
F_COUNT=$(echo "${PERFORMANCE_GRADES[@]}" | grep -o ":F" | wc -l)

echo "Grade Distribution:"
echo "  A (Excellent): $A_COUNT"
echo "  B (Good): $B_COUNT"
echo "  C (Average): $C_COUNT"
echo "  D (Below Average): $D_COUNT"
echo "  F (Poor): $F_COUNT"

TOTAL_TESTS=$((A_COUNT + B_COUNT + C_COUNT + D_COUNT + F_COUNT))
SCORE=$(( (A_COUNT * 100 + B_COUNT * 80 + C_COUNT * 60 + D_COUNT * 40 + F_COUNT * 20) / TOTAL_TESTS ))

echo
echo -n "Overall Performance Score: $SCORE/100 - "
if [ $SCORE -ge 90 ]; then
    echo -e "${GREEN}EXCELLENT${NC}"
elif [ $SCORE -ge 80 ]; then
    echo -e "${GREEN}GOOD${NC}"
elif [ $SCORE -ge 70 ]; then
    echo -e "${CYAN}SATISFACTORY${NC}"
elif [ $SCORE -ge 60 ]; then
    echo -e "${YELLOW}NEEDS IMPROVEMENT${NC}"
else
    echo -e "${RED}POOR${NC}"
fi

if [ ${#SLOW_OPERATIONS[@]} -gt 0 ]; then
    echo
    echo -e "${RED}=== Critical Performance Issues ===${NC}"
    for issue in "${SLOW_OPERATIONS[@]}"; do
        echo "  ❌ $issue"
    done
fi

echo
echo -e "${CYAN}=== Optimization Recommendations ===${NC}"

if [ $F_COUNT -gt 0 ]; then
    echo "• CRITICAL: Fix operations with 'F' grade immediately"
fi

if echo "${SLOW_OPERATIONS[@]}" | grep -q "traversal"; then
    echo "• Optimize graph traversal algorithms"
fi

if echo "${SLOW_OPERATIONS[@]}" | grep -q "Memory"; then
    echo "• Investigate memory leaks and optimize memory allocation"
fi

if [ $CONCURRENT_WRITE_TIME -gt 5000 ]; then
    echo "• Improve concurrent write performance with better locking"
fi

if [ $CONCURRENT_READ_TIME -gt 2000 ]; then
    echo "• Add read query caching or connection pooling"
fi

echo "• Consider implementing query compilation/caching"
echo "• Add index support for frequently queried properties"
echo "• Implement batch operation APIs for bulk inserts"

# Generate detailed report file
echo
echo "Generating detailed report..."
cat > /tmp/performance_report.txt << EOF
GEODE PERFORMANCE BENCHMARK REPORT
Generated: $(date)

ENVIRONMENT:
- Server: geoded
- Transport: stdio/QUIC
- Dataset: 1000+ nodes with relationships

PERFORMANCE GRADES:
$(printf '%s\n' "${PERFORMANCE_GRADES[@]}")

SLOW OPERATIONS:
$(printf '%s\n' "${SLOW_OPERATIONS[@]}")

RECOMMENDATIONS:
1. Focus on operations with grades D and F
2. Optimize memory usage patterns
3. Improve concurrent operation handling
4. Implement query optimization strategies

OVERALL SCORE: $SCORE/100
EOF

echo "Detailed report saved to /tmp/performance_report.txt"

exit 0
