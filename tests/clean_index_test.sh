#!/usr/bin/env bash
# Clean test for index operations

set -e

echo "=== Index Operations Test ==="
echo

# Start server quietly
echo "Starting server..."
./zig-out/bin/geode serve --data_dir /tmp/idx_test_$$ --insecure > /tmp/server_$$.log 2>&1 &
SERVER_PID=$!
sleep 2

cleanup() {
    echo "Cleaning up..."
    kill $SERVER_PID 2>/dev/null || true
    rm -rf /tmp/idx_test_$$ /tmp/server_$$.log
}
trap cleanup EXIT

# Filter out debug logs and extract only the actual response
run_query() {
    local query="$1"
    local result=$(./zig-out/bin/geode query "$query" --insecure 2>/dev/null | grep -v '"level":' | grep -v '"component":' | tail -1)
    echo "$result"
}

echo "1. Testing CREATE INDEX..."
RESULT=$(run_query "CREATE INDEX person_name_idx ON Person(name)")
echo "   Response: $RESULT"

echo
echo "2. Testing CREATE UNIQUE INDEX..."
RESULT=$(run_query "CREATE UNIQUE INDEX person_id_idx ON Person(id)")
echo "   Response: $RESULT"

echo
echo "3. Testing CREATE INDEX IF NOT EXISTS (duplicate)..."
RESULT=$(run_query "CREATE INDEX IF NOT EXISTS person_name_idx ON Person(name)")
echo "   Response: $RESULT"

echo
echo "4. Testing DROP INDEX..."
RESULT=$(run_query "DROP INDEX person_name_idx")
echo "   Response: $RESULT"

echo
echo "5. Testing DROP INDEX IF EXISTS (non-existent)..."
RESULT=$(run_query "DROP INDEX IF EXISTS non_existent_idx")
echo "   Response: $RESULT"

echo
echo "6. Testing CREATE INDEX with USING clause..."
RESULT=$(run_query "CREATE INDEX hash_idx ON Person(email) USING hash")
echo "   Response: $RESULT"

echo
echo "=== Test Complete ==="
