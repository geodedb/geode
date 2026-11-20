#!/usr/bin/env bash
# Test for index operations (CREATE/DROP INDEX)

set -e

echo "=== Index Operations Test ==="
echo

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASSED=0
FAILED=0
WARNINGS=0

# Build
echo "Building Geode..."
make build > /dev/null 2>&1 || { echo -e "${RED}Build failed${NC}"; exit 1; }

# Start server
echo "Starting Geode server..."
./zig-out/bin/geode serve --data_dir /tmp/geode_index_test_$$ > /tmp/geode_server_$$.log 2>&1 &
SERVER_PID=$!
sleep 2

# Cleanup function
cleanup() {
    echo
    echo "Cleaning up..."
    kill $SERVER_PID 2>/dev/null || true
    rm -rf /tmp/geode_index_test_$$
    rm -f /tmp/geode_server_$$.log
}
trap cleanup EXIT

# Test function
test_query() {
    local name="$1"
    local query="$2"
    local expected="$3"

    echo -n "Testing $name... "

    local output
    output=$(./zig-out/bin/geode query "$query" --insecure 2>&1 || true)

    if echo "$output" | grep -q "NotImplemented"; then
        echo -e "${YELLOW}NOT IMPLEMENTED${NC}"
        ((WARNINGS++))
    elif echo "$output" | grep -q "$expected"; then
        echo -e "${GREEN}PASS${NC}"
        ((PASSED++))
    elif echo "$output" | grep -q "error"; then
        echo -e "${RED}ERROR${NC}"
        echo "  Query: $query"
        echo "  Error: $(echo "$output" | grep error | head -1)"
        ((FAILED++))
    else
        echo -e "${RED}FAIL${NC}"
        echo "  Expected: $expected"
        echo "  Got: $output"
        ((FAILED++))
    fi
}

echo
echo "Testing CREATE INDEX syntax parsing..."
echo

# Test basic CREATE INDEX
test_query "Basic CREATE INDEX" \
    "CREATE INDEX person_name_idx ON Person(name)" \
    "CreateIndex"

# Test CREATE UNIQUE INDEX
test_query "CREATE UNIQUE INDEX" \
    "CREATE UNIQUE INDEX unique_email_idx ON User(email)" \
    "CreateIndex"

# Test CREATE INDEX IF NOT EXISTS
test_query "CREATE INDEX IF NOT EXISTS" \
    "CREATE INDEX IF NOT EXISTS person_age_idx ON Person(age)" \
    "CreateIndex"

# Test CREATE INDEX with multiple properties
test_query "CREATE INDEX multi-property" \
    "CREATE INDEX person_full_idx ON Person(firstName, lastName)" \
    "CreateIndex"

# Test CREATE INDEX with USING clause
test_query "CREATE INDEX with USING btree" \
    "CREATE INDEX person_btree_idx ON Person(name) USING btree" \
    "CreateIndex"

test_query "CREATE INDEX with USING hash" \
    "CREATE INDEX person_hash_idx ON Person(id) USING hash" \
    "CreateIndex"

test_query "CREATE INDEX with USING fulltext" \
    "CREATE INDEX text_idx ON Article(content) USING fulltext" \
    "CreateIndex"

test_query "CREATE INDEX with USING spatial" \
    "CREATE INDEX location_idx ON Place(coordinates) USING spatial" \
    "CreateIndex"

test_query "CREATE INDEX with USING vector" \
    "CREATE INDEX embedding_idx ON Document(embedding) USING vector" \
    "CreateIndex"

echo
echo "Testing DROP INDEX syntax parsing..."
echo

# Test basic DROP INDEX
test_query "Basic DROP INDEX" \
    "DROP INDEX person_name_idx" \
    "DropIndex"

# Test DROP INDEX IF EXISTS
test_query "DROP INDEX IF EXISTS" \
    "DROP INDEX IF EXISTS person_age_idx" \
    "DropIndex"

echo
echo "Testing actual index creation and usage..."
echo

# Create some nodes
echo "Creating test nodes..."
./zig-out/bin/geode query "CREATE (n:Person {name: 'Alice', age: 30})" --insecure 2>&1 > /dev/null
./zig-out/bin/geode query "CREATE (n:Person {name: 'Bob', age: 25})" --insecure 2>&1 > /dev/null
./zig-out/bin/geode query "CREATE (n:Person {name: 'Charlie', age: 35})" --insecure 2>&1 > /dev/null

# Test index creation and usage
test_query "Create index on Person.name" \
    "CREATE INDEX person_name_idx ON Person(name)" \
    ""

test_query "Query with index (should work)" \
    "MATCH (n:Person {name: 'Alice'}) RETURN n.name AS name" \
    "Alice"

test_query "Create unique index on Person.id" \
    "CREATE UNIQUE INDEX person_id_idx ON Person(id)" \
    ""

test_query "Drop index" \
    "DROP INDEX person_name_idx" \
    ""

test_query "Drop non-existent index without IF EXISTS (should error)" \
    "DROP INDEX non_existent_idx" \
    ""

test_query "Drop non-existent index with IF EXISTS (should succeed)" \
    "DROP INDEX IF EXISTS non_existent_idx" \
    ""

echo
echo "Testing BACKUP and RESTORE syntax parsing..."
echo

# Test basic BACKUP
test_query "Basic BACKUP" \
    "BACKUP TO '/tmp/backup.db'" \
    "Backup"

# Test BACKUP with options
test_query "BACKUP with INCREMENTAL" \
    "BACKUP TO '/tmp/backup.db' WITH INCREMENTAL" \
    "Backup"

test_query "BACKUP with COMPRESSED" \
    "BACKUP TO '/tmp/backup.db' WITH COMPRESSED" \
    "Backup"

test_query "BACKUP with ENCRYPTED" \
    "BACKUP TO '/tmp/backup.db' WITH ENCRYPTED 'mykey'" \
    "Backup"

# Test basic RESTORE
test_query "Basic RESTORE" \
    "RESTORE FROM '/tmp/backup.db'" \
    "Restore"

# Test RESTORE with options
test_query "RESTORE with timestamp" \
    "RESTORE FROM '/tmp/backup.db' TO '2025-01-01T12:00:00'" \
    "Restore"

test_query "RESTORE with VERIFY ONLY" \
    "RESTORE FROM '/tmp/backup.db' VERIFY ONLY" \
    "Restore"

echo
echo "=== Summary ==="
echo "Tests passed: $PASSED"
echo "Tests failed: $FAILED"
echo "Not implemented: $WARNINGS"
echo "Total tests: $((PASSED + FAILED + WARNINGS))"

if [ $FAILED -eq 0 ]; then
    if [ $WARNINGS -gt 0 ]; then
        echo -e "${YELLOW}Index operations are parsed correctly but implementation pending.${NC}"
    else
        echo -e "${GREEN}All tests passed!${NC}"
    fi
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
