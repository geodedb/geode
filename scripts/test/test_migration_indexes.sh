#!/bin/sh
set -eu

cd /home/benji/src/spyder/geode
rm -f /tmp/geode_catalog.dat

echo "Testing migration index creation tests..."
echo ""

echo "Test 1: create-btree-index"
./zig-out/bin/geode query --server 127.0.0.1:3141 --insecure --format json "CREATE INDEX person_name_idx ON :Person(name) USING BTREE"
exitcode1=$?
echo "Exit code: $exitcode1"
echo ""

echo "Test 2: create-hash-index"
./zig-out/bin/geode query --server 127.0.0.1:3141 --insecure --format json "CREATE INDEX person_email_idx ON :Person(email) USING HASH"
exitcode2=$?
echo "Exit code: $exitcode2"
echo ""

echo "Test 3: create-composite-index"
./zig-out/bin/geode query --server 127.0.0.1:3141 --insecure --format json "CREATE INDEX person_composite_idx ON :Person(name, age)"
exitcode3=$?
echo "Exit code: $exitcode3"
echo ""

echo "Test 4: drop-index"
./zig-out/bin/geode query --server 127.0.0.1:3141 --insecure --format json "DROP INDEX person_email_idx"
exitcode4=$?
echo "Exit code: $exitcode4"
echo ""

echo "Test 5: SHOW INDEXES"
./zig-out/bin/geode query --server 127.0.0.1:3141 --insecure --format json "SHOW INDEXES"
echo ""

echo "===== Summary ====="
[ $exitcode1 -eq 0 ] && echo "✓ create-btree-index: PASSED" || echo "✗ create-btree-index: FAILED (exit $exitcode1)"
[ $exitcode2 -eq 0 ] && echo "✓ create-hash-index: PASSED" || echo "✗ create-hash-index: FAILED (exit $exitcode2)"
[ $exitcode3 -eq 0 ] && echo "✓ create-composite-index: PASSED" || echo "✗ create-composite-index: FAILED (exit $exitcode3)"
[ $exitcode4 -eq 0 ] && echo "✓ drop-index: PASSED" || echo "✗ drop-index: FAILED (exit $exitcode4)"
