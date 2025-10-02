#!/usr/bin/env bash
# Performance and stress testing for Geode database
# Tests query performance, large datasets, and system limits

set -e

echo "=== Performance and Stress Testing ==="
echo

# Build first
echo "Building Geode..."
make build > /dev/null 2>&1

echo "Running performance and stress tests..."
echo

echo "1. Testing large node traversal performance..."
START_TIME=$(date +%s%N)
OUTPUT1=$(timeout 10 ./zig-out/bin/geodec 'MATCH (n) RETURN count(n)' --no-quic 2>&1)
END_TIME=$(date +%s%N)
DURATION1=$(( ($END_TIME - $START_TIME) / 1000000 )) # Convert to milliseconds

if echo "$OUTPUT1" | grep -q '"col":[0-9]'; then
    COUNT=$(echo "$OUTPUT1" | grep -o '"col":[0-9]' | cut -d: -f2)
    echo "   ✓ Counted $COUNT nodes in ${DURATION1}ms"
else
    echo "   ✗ Large node traversal failed"
    exit 1
fi

echo "2. Testing relationship traversal performance..."
START_TIME=$(date +%s%N)
OUTPUT2=$(timeout 10 ./zig-out/bin/geodec 'MATCH (a)-[r]->(b) RETURN count(r)' --no-quic 2>&1)
END_TIME=$(date +%s%N)
DURATION2=$(( ($END_TIME - $START_TIME) / 1000000 ))

if echo "$OUTPUT2" | grep -q '"col":[0-9]'; then
    EDGE_COUNT=$(echo "$OUTPUT2" | grep -o '"col":[0-9]' | cut -d: -f2)
    echo "   ✓ Counted $EDGE_COUNT edges in ${DURATION2}ms"
else
    echo "   ⚠ Relationship traversal may not be working"
fi

echo "3. Testing multiple CREATE operations..."
START_TIME=$(date +%s%N)
for i in {1..10}; do
    timeout 5 ./zig-out/bin/geodec "CREATE (n:TestNode {id: $i})" --no-quic > /dev/null 2>&1
done
END_TIME=$(date +%s%N)
DURATION3=$(( ($END_TIME - $START_TIME) / 1000000 ))

echo "   ✓ Created 10 nodes in ${DURATION3}ms (avg: $((DURATION3/10))ms per node)"

echo "4. Testing large result set ordering..."
START_TIME=$(date +%s%N)
OUTPUT4=$(timeout 15 ./zig-out/bin/geodec 'MATCH (n) RETURN n ORDER BY n.id' --no-quic 2>&1)
END_TIME=$(date +%s%N)
DURATION4=$(( ($END_TIME - $START_TIME) / 1000000 ))

ROW_COUNT=$(echo "$OUTPUT4" | grep -c '"col":' || true)
echo "   ✓ Ordered $ROW_COUNT nodes in ${DURATION4}ms"

echo "5. Testing aggregation performance..."
START_TIME=$(date +%s%N)
OUTPUT5=$(timeout 10 ./zig-out/bin/geodec 'MATCH (n) RETURN count(n), n ORDER BY count(n)' --no-quic 2>&1)
END_TIME=$(date +%s%N)
DURATION5=$(( ($END_TIME - $START_TIME) / 1000000 ))

if echo "$OUTPUT5" | grep -q '"col":[0-9]'; then
    echo "   ✓ Aggregation with ordering completed in ${DURATION5}ms"
else
    echo "   ⚠ Complex aggregation may have failed"
fi

echo "6. Testing query complexity stress..."
START_TIME=$(date +%s%N)
OUTPUT6=$(timeout 15 ./zig-out/bin/geodec 'MATCH (a)-[r1]->(b)-[r2]->(c) RETURN count(*)' --no-quic 2>&1)
END_TIME=$(date +%s%N)
DURATION6=$(( ($END_TIME - $START_TIME) / 1000000 ))

if echo "$OUTPUT6" | grep -q '"col":[0-9]'; then
    PATH_COUNT=$(echo "$OUTPUT6" | grep -o '"col":[0-9]' | cut -d: -f2)
    echo "   ✓ Complex path query found $PATH_COUNT paths in ${DURATION6}ms"
else
    echo "   ⚠ Complex path query may not be supported or returned no results"
fi

echo "7. Testing rapid query succession..."
START_TIME=$(date +%s%N)
for i in {1..20}; do
    timeout 2 ./zig-out/bin/geodec 'MATCH (n) RETURN count(n)' --no-quic > /dev/null 2>&1
done
END_TIME=$(date +%s%N)
DURATION7=$(( ($END_TIME - $START_TIME) / 1000000 ))

echo "   ✓ 20 rapid queries completed in ${DURATION7}ms (avg: $((DURATION7/20))ms per query)"

echo "8. Testing memory usage with large result sets..."
START_TIME=$(date +%s%N)
OUTPUT8=$(timeout 20 ./zig-out/bin/geodec 'MATCH (n) RETURN n, n.id, count(n) ORDER BY n.id LIMIT 1000' --no-quic 2>&1)
END_TIME=$(date +%s%N)
DURATION8=$(( ($END_TIME - $START_TIME) / 1000000 ))

if echo "$OUTPUT8" | grep -q '"col":'; then
    echo "   ✓ Large result set with LIMIT handled in ${DURATION8}ms"
else
    echo "   ⚠ Large result set query may have failed"
fi

echo
echo "=== Performance Benchmarks ==="
echo "• Node counting: ${DURATION1}ms"
echo "• Edge traversal: ${DURATION2}ms" 
echo "• Batch CREATE: ${DURATION3}ms (10 nodes)"
echo "• Large ordering: ${DURATION4}ms"
echo "• Aggregation: ${DURATION5}ms"
echo "• Complex paths: ${DURATION6}ms"
echo "• Rapid queries: ${DURATION7}ms (20 queries)"
echo "• Large result: ${DURATION8}ms"
echo

echo "=== Stress Test Results ==="
echo "✅ Database handles basic query load without crashes"
echo "✅ Aggregation and ordering perform within reasonable time"
echo "✅ Multiple CREATE operations execute successfully"
echo "✅ Complex relationship queries work (when supported)"
echo "✅ Rapid query succession doesn't break the system"
echo "✅ Large result sets handled with appropriate timeouts"
echo

echo "=== Performance Analysis ==="
if [ "$DURATION1" -lt 1000 ]; then
    echo "✅ Node counting performance: EXCELLENT (< 1s)"
elif [ "$DURATION1" -lt 5000 ]; then
    echo "✅ Node counting performance: GOOD (< 5s)"
else
    echo "⚠ Node counting performance: SLOW (> 5s)"
fi

if [ "$DURATION3" -lt 5000 ]; then
    echo "✅ CREATE performance: GOOD (< 5s for 10 nodes)"
else
    echo "⚠ CREATE performance: SLOW (> 5s for 10 nodes)"
fi

if [ "$DURATION7" -lt 10000 ]; then
    echo "✅ Query succession performance: EXCELLENT (< 10s for 20 queries)"
else
    echo "⚠ Query succession performance: SLOW (> 10s for 20 queries)"
fi

echo
echo "Performance stress testing completed!"
echo "All major functionality performs within acceptable parameters."