#!/bin/sh

rm -f /tmp/geode_catalog.dat

echo "Testing DROP INDEX with scoped keys..."
echo ""

echo "5. DROP INDEX idx (should remove Person:idx):"
./zig-out/bin/geode query --no-quic "DROP INDEX idx"
exitcode5=$?
echo "Exit code: $exitcode5"
echo ""

echo "6. Try to create idx on :Person(age) again - SHOULD SUCCEED (Person:idx was dropped):"
./zig-out/bin/geode query --no-quic "CREATE INDEX idx ON :Person (age)"
exitcode6=$?
echo "Exit code: $exitcode6"
echo ""

echo "7. SHOW INDEXES to verify state:"
./zig-out/bin/geode query --no-quic --format json "SHOW INDEXES"
echo ""

echo "8. DROP INDEX idx again (should now remove Person:idx on age property):"
./zig-out/bin/geode query --no-quic "DROP INDEX idx"
exitcode8=$?
echo "Exit code: $exitcode8"
