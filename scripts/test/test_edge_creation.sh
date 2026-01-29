#!/usr/bin/env bash
# Test edge creation and querying

set -e

echo "=== Testing Edge Creation and Querying ==="
echo

# Build first
echo "Building Geode..."
make build > /dev/null 2>&1

echo "1. Creating simple nodes..."
timeout 3 ./zig-out/bin/geodec 'CREATE (a), (b)' --server 127.0.0.1:3141 --insecure
echo "   Status: Success"

echo "2. Creating nodes with labels..."
timeout 3 ./zig-out/bin/geodec 'CREATE (p:Person), (c:Company)' --server 127.0.0.1:3141 --insecure
echo "   Status: Success"

echo "3. Creating nodes with properties..."
timeout 3 ./zig-out/bin/geodec 'CREATE (p {age: 30}), (q {score: 95})' --server 127.0.0.1:3141 --insecure
echo "   Status: Success"

echo "4. Creating simple edge..."
timeout 3 ./zig-out/bin/geodec 'CREATE (a)-[:KNOWS]->(b)' --server 127.0.0.1:3141 --insecure
echo "   Status: Success"

echo "5. Creating edge with properties..."
timeout 3 ./zig-out/bin/geodec 'CREATE (x)-[:WORKS_AT {since: 2020}]->(y)' --server 127.0.0.1:3141 --insecure
echo "   Status: Success"

echo "6. Creating complex pattern..."
timeout 3 ./zig-out/bin/geodec 'CREATE (alice:Person {age: 25})-[:WORKS_AT {since: 2020}]->(tech:Company {size: 100})' --server 127.0.0.1:3141 --insecure
echo "   Status: Success"

echo
echo "=== Querying Created Graph ==="

echo "7. Counting all nodes..."
timeout 3 ./zig-out/bin/geodec 'MATCH (n) RETURN count(n) AS node_count' --server 127.0.0.1:3141 --insecure | grep node_count
echo

echo "8. Counting all edges..."
timeout 3 ./zig-out/bin/geodec 'MATCH ()-[r]->() RETURN count(r) AS edge_count' --server 127.0.0.1:3141 --insecure | grep edge_count
echo

echo "9. Finding KNOWS relationships..."
timeout 3 ./zig-out/bin/geodec 'MATCH (a)-[r:KNOWS]->(b) RETURN count(r) AS knows_count' --server 127.0.0.1:3141 --insecure | grep knows_count
echo

echo "10. Finding WORKS_AT relationships..."
timeout 3 ./zig-out/bin/geodec 'MATCH (a)-[r:WORKS_AT]->(b) RETURN count(r) AS works_count' --server 127.0.0.1:3141 --insecure | grep works_count
echo

echo "=== Edge Creation Test Complete ==="
