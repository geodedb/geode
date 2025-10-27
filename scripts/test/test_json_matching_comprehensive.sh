#!/bin/sh

echo "===== Comprehensive JSON Matching Test ====="
echo ""

rm -f /tmp/geode_catalog.dat

echo "Test 1: Simple count query"
echo "RETURN 1 AS count" | ./zig-out/bin/geode query --no-quic --format json -
echo ""

echo "Test 2: Multiple values"
echo "RETURN 1 AS a, 2 AS b, 3 AS c" | ./zig-out/bin/geode query --no-quic --format json -
echo ""

echo "Test 3: String values"
echo "RETURN 'Alice' AS name, 30 AS age" | ./zig-out/bin/geode query --no-quic --format json -
echo ""

echo "Test 4: batch-update-properties simulation"
./zig-out/bin/geode query --no-quic "MATCH (n) DELETE n"
./zig-out/bin/geode query --no-quic "CREATE (:User {name: 'Alice'}), (:User {name: 'Bob', age: 25})"
./zig-out/bin/geode query --no-quic --format json "MATCH (u:User) WHERE u.age IS NULL SET u.age = 0 RETURN count(u)"
echo ""

echo "Test 5: Multiple rows"
./zig-out/bin/geode query --no-quic --format json "MATCH (u:User) RETURN u.name AS name, u.age AS age"
echo ""

echo "===== All tests completed ====="
