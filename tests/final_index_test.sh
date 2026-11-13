#!/usr/bin/env bash
# Final test for index operations

set -e

echo "=== Final Index Operations Test ==="
echo

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Start server
echo "Starting server..."
./zig-out/bin/geode serve --data_dir /tmp/idx_test_$$ > /tmp/server_$$.log 2>&1 &
SERVER_PID=$!
sleep 2

cleanup() {
    echo "Cleaning up..."
    kill $SERVER_PID 2>/dev/null || true
    rm -rf /tmp/idx_test_$$ /tmp/server_$$.log
}
trap cleanup EXIT

echo
echo "Testing CREATE INDEX..."
OUTPUT=$(./zig-out/bin/geode query "CREATE INDEX person_name_idx ON Person(name)" --insecure 2>&1)
echo "Result: $OUTPUT"

if echo "$OUTPUT" | grep -q "Index person_name_idx created successfully"; then
    echo -e "${GREEN}✓ CREATE INDEX successful${NC}"
elif echo "$OUTPUT" | grep -q "NotImplemented"; then
    echo -e "${RED}✗ CREATE INDEX not implemented${NC}"
else
    echo "Output: $OUTPUT"
fi

echo
echo "Testing CREATE UNIQUE INDEX..."
OUTPUT=$(./zig-out/bin/geode query "CREATE UNIQUE INDEX person_id_idx ON Person(id)" --insecure 2>&1)
echo "Result: $OUTPUT"

echo
echo "Testing CREATE INDEX IF NOT EXISTS..."
OUTPUT=$(./zig-out/bin/geode query "CREATE INDEX IF NOT EXISTS person_name_idx ON Person(name)" --insecure 2>&1)
echo "Result: $OUTPUT"

echo
echo "Testing DROP INDEX..."
OUTPUT=$(./zig-out/bin/geode query "DROP INDEX person_name_idx" --insecure 2>&1)
echo "Result: $OUTPUT"

if echo "$OUTPUT" | grep -q "Index person_name_idx dropped successfully"; then
    echo -e "${GREEN}✓ DROP INDEX successful${NC}"
elif echo "$OUTPUT" | grep -q "NotImplemented"; then
    echo -e "${RED}✗ DROP INDEX not implemented${NC}"
fi

echo
echo "Testing DROP INDEX IF EXISTS..."
OUTPUT=$(./zig-out/bin/geode query "DROP INDEX IF EXISTS non_existent_idx" --insecure 2>&1)
echo "Result: $OUTPUT"

echo
echo "Testing BACKUP..."
OUTPUT=$(./zig-out/bin/geode query "BACKUP TO '/tmp/backup.db'" --insecure 2>&1)
echo "Result: $OUTPUT"

echo
echo "Testing RESTORE..."
OUTPUT=$(./zig-out/bin/geode query "RESTORE FROM '/tmp/backup.db'" --insecure 2>&1)
echo "Result: $OUTPUT"

echo
echo "=== Test Complete ===="
