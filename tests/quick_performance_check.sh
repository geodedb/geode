#!/usr/bin/env bash
# Quick Performance Check - Identifies slow operations

set -e

echo "=== Quick Performance Check ==="
echo

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Function to time operations
time_operation() {
    local name="$1"
    local cmd="$2"
    local threshold="$3"

    echo -n "$name: "
    local start=$(date +%s%N)
    timeout 3 $cmd > /dev/null 2>&1
    local end=$(date +%s%N)
    local duration_ms=$(( (end - start) / 1000000 ))

    if [ $duration_ms -le $threshold ]; then
        echo -e "${GREEN}${duration_ms}ms ✓${NC}"
    elif [ $duration_ms -le $((threshold * 2)) ]; then
        echo -e "${YELLOW}${duration_ms}ms (slow)${NC}"
    else
        echo -e "${RED}${duration_ms}ms (TOO SLOW!)${NC}"
    fi
}

# Build
echo "Building..."
make build > /dev/null 2>&1

echo
echo "Testing basic operations:"
time_operation "Simple RETURN" "./zig-out/bin/geodec 'RETURN 1 AS x' --insecure" 500
time_operation "CREATE node" "./zig-out/bin/geodec 'CREATE (n:Test {id: 1})' --insecure" 600
time_operation "MATCH count" "./zig-out/bin/geodec 'MATCH (n) RETURN count(n)' --insecure" 700
time_operation "Property query" "./zig-out/bin/geodec 'MATCH (n:Test) WHERE n.id = 1 RETURN n' --insecure" 800

echo
echo "Creating test data..."
for i in {1..100}; do
    ./zig-out/bin/geodec "CREATE (p:Person {id: $i, name: 'Person$i', age: $((20 + i % 50))})" --insecure 2>/dev/null
done
echo "Created 100 test nodes"

echo
echo "Testing query performance:"
time_operation "Count all" "./zig-out/bin/geodec 'MATCH (p:Person) RETURN count(p)' --insecure" 800
time_operation "Range query" "./zig-out/bin/geodec 'MATCH (p:Person) WHERE p.age > 30 RETURN count(p)' --insecure" 1000
time_operation "ORDER BY" "./zig-out/bin/geodec 'MATCH (p:Person) RETURN p.name ORDER BY p.age LIMIT 10' --insecure" 1200
time_operation "Aggregation" "./zig-out/bin/geodec 'MATCH (p:Person) RETURN avg(p.age) AS avg' --insecure" 1000

echo
echo "Testing string literals (critical issue):"
echo -n "Single quotes: "
start=$(date +%s%N)
./zig-out/bin/geodec "CREATE (n {name: 'test'})" --insecure > /dev/null 2>&1
end=$(date +%s%N)
duration_ms=$(( (end - start) / 1000000 ))
echo -e "${GREEN}${duration_ms}ms ✓${NC}"

echo -n "Double quotes (should timeout): "
start=$(date +%s%N)
timeout 2 ./zig-out/bin/geodec 'CREATE (n {name: "test"})' --insecure > /dev/null 2>&1 || true
end=$(date +%s%N)
duration_ms=$(( (end - start) / 1000000 ))
if [ $duration_ms -ge 1900 ]; then
    echo -e "${RED}HANGS (parser bug confirmed)${NC}"
else
    echo -e "${GREEN}Fixed? (${duration_ms}ms)${NC}"
fi

echo
echo "Performance Summary:"
echo "✓ Operations under 1 second are acceptable"
echo "⚠ Operations 1-2 seconds need optimization"
echo "✗ Operations over 2 seconds are critical"
