#!/bin/sh

echo "===== Full Scoped Index Test ====="
echo "Removing old catalog..."
rm -f /tmp/geode_catalog.dat
echo ""

echo "1. Create index 'test_idx' on :Person(name):"
./zig-out/bin/geode query --server 127.0.0.1:3141 --insecure "CREATE INDEX test_idx ON :Person (name)" 2>&1
exitcode1=$?
echo "Exit code: $exitcode1"
echo ""

echo "2. Create index 'test_idx' on :Company(name) - SHOULD SUCCEED (different label):"
./zig-out/bin/geode query --server 127.0.0.1:3141 --insecure "CREATE INDEX test_idx ON :Company (name)" 2>&1
exitcode2=$?
echo "Exit code: $exitcode2"
echo ""

echo "3. Create index 'test_idx' on :Person(age) - SHOULD FAIL (duplicate on same label):"
./zig-out/bin/geode query --server 127.0.0.1:3141 --insecure "CREATE INDEX test_idx ON :Person (age)" 2>&1
exitcode3=$?
echo "Exit code: $exitcode3"
echo ""

echo "4. SHOW INDEXES - should see 2 indexes both named 'test_idx':"
./zig-out/bin/geode query --server 127.0.0.1:3141 --insecure --format json "SHOW INDEXES" 2>&1
echo ""

echo "5. DROP INDEX test_idx (will remove first one found - Person:test_idx):"
./zig-out/bin/geode query --server 127.0.0.1:3141 --insecure "DROP INDEX test_idx" 2>&1
exitcode5=$?
echo "Exit code: $exitcode5"
echo ""

echo "6. SHOW INDEXES - should see only 1 index remaining (Company:test_idx):"
./zig-out/bin/geode query --server 127.0.0.1:3141 --insecure --format json "SHOW INDEXES" 2>&1
echo ""

echo "7. Try to create test_idx on :Person(age) again - SHOULD SUCCEED now:"
./zig-out/bin/geode query --server 127.0.0.1:3141 --insecure "CREATE INDEX test_idx ON :Person (age)" 2>&1
exitcode7=$?
echo "Exit code: $exitcode7"
echo ""

echo "8. SHOW INDEXES - should see 2 indexes again:"
./zig-out/bin/geode query --server 127.0.0.1:3141 --insecure --format json "SHOW INDEXES" 2>&1
echo ""

echo "===== Summary ====="
echo "Test 1 (Create Person:test_idx): Exit $exitcode1 (expected: 0)"
echo "Test 2 (Create Company:test_idx): Exit $exitcode2 (expected: 0)"
echo "Test 3 (Duplicate Person:test_idx): Exit $exitcode3 (expected: 1)"
echo "Test 5 (Drop test_idx): Exit $exitcode5 (expected: 0)"
echo "Test 7 (Recreate Person:test_idx): Exit $exitcode7 (expected: 0)"
