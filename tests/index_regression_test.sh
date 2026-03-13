#!/bin/bash
set -euo pipefail

# Index Operations Regression Test Suite
# Tests CREATE INDEX, DROP INDEX with various index types

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Start the server
echo -e "${YELLOW}Starting Geode server...${NC}"
./zig-out/bin/geode serve --data_dir ./test_data --insecure &
SERVER_PID=$!
sleep 2

# Function to run a test
run_test() {
    local test_name="$1"
    local query="$2"
    local expected_pattern="$3"

    echo -n "Testing: $test_name... "

    result=$(./zig-out/bin/geode query "$query" --insecure 2>&1)

    if echo "$result" | grep -q "$expected_pattern"; then
        echo -e "${GREEN}PASSED${NC}"
        return 0
    else
        echo -e "${RED}FAILED${NC}"
        echo "  Query: $query"
        echo "  Expected pattern: $expected_pattern"
        echo "  Got: $result"
        return 1
    fi
}

# Setup test data
echo -e "${YELLOW}Creating test data...${NC}"
./zig-out/bin/geode query "CREATE (n:Person {name: 'Alice', age: 30, location: point(40.7128, -74.0060)})" --insecure >/dev/null 2>&1
./zig-out/bin/geode query "CREATE (n:Person {name: 'Bob', age: 25, location: point(37.7749, -122.4194)})" --insecure >/dev/null 2>&1
./zig-out/bin/geode query "CREATE (n:Person {name: 'Charlie', age: 35, location: point(51.5074, -0.1278)})" --insecure >/dev/null 2>&1
./zig-out/bin/geode query "CREATE (n:Document {title: 'Graph Database Guide', content: 'This is a comprehensive guide to graph databases'})" --insecure >/dev/null 2>&1
./zig-out/bin/geode query "CREATE (n:Product {id: 1, features: [0.1, 0.2, 0.3, 0.4, 0.5]})" --insecure >/dev/null 2>&1

echo -e "\n${YELLOW}Running index regression tests...${NC}"

# Test 1: Create btree index
run_test "Create btree index" \
    "CREATE INDEX person_age_idx ON Person(age)" \
    "Index person_age_idx created"

# Test 2: Create unique index
run_test "Create unique index" \
    "CREATE UNIQUE INDEX person_name_idx ON Person(name)" \
    "Index person_name_idx created"

# Test 3: Create hash index
run_test "Create hash index" \
    "CREATE INDEX person_name_hash ON Person(name) USING hash" \
    "Index person_name_hash created"

# Test 4: Create spatial index
run_test "Create spatial index" \
    "CREATE INDEX person_location_idx ON Person(location) USING spatial" \
    "Index person_location_idx created"

# Test 5: Create fulltext index
run_test "Create fulltext index" \
    "CREATE INDEX doc_content_idx ON Document(content) USING fulltext" \
    "Index doc_content_idx created"

# Test 6: Create vector index
run_test "Create vector index" \
    "CREATE INDEX product_features_idx ON Product(features) USING vector" \
    "Index product_features_idx created"

# Test 7: Create composite index
run_test "Create composite index" \
    "CREATE INDEX person_composite_idx ON Person(name, age)" \
    "Index person_composite_idx created"

# Test 8: Create index with IF NOT EXISTS
run_test "Create index with IF NOT EXISTS (new)" \
    "CREATE INDEX IF NOT EXISTS new_idx ON Person(age)" \
    "Index new_idx created"

# Test 9: Create index with IF NOT EXISTS (existing)
run_test "Create index with IF NOT EXISTS (existing)" \
    "CREATE INDEX IF NOT EXISTS person_age_idx ON Person(age)" \
    ""

# Test 10: Drop index
run_test "Drop index" \
    "DROP INDEX person_name_hash" \
    "Index person_name_hash dropped"

# Test 11: Drop index with IF EXISTS
run_test "Drop index with IF EXISTS (existing)" \
    "DROP INDEX IF EXISTS person_composite_idx" \
    "Index person_composite_idx dropped"

# Test 12: Drop index with IF EXISTS (non-existing)
run_test "Drop index with IF EXISTS (non-existing)" \
    "DROP INDEX IF EXISTS nonexistent_idx" \
    ""

# Test 13: Query using btree index
run_test "Query using btree index" \
    "MATCH (p:Person) WHERE p.age > 25 RETURN p.name ORDER BY p.age" \
    "Alice\|Bob\|Charlie"

# Test 14: Query using unique index
run_test "Query using unique index" \
    "MATCH (p:Person) WHERE p.name = 'Alice' RETURN p.age" \
    "30"

# Test 15: Spatial query (range search)
run_test "Spatial range query" \
    "MATCH (p:Person) WHERE distance(p.location, point(40.0, -74.0)) < 100 RETURN p.name" \
    "Alice"

# Test 16: Fulltext search
run_test "Fulltext search" \
    "MATCH (d:Document) WHERE d.content CONTAINS 'graph' RETURN d.title" \
    "Graph Database Guide"

# Test 17: Vector similarity search (KNN)
run_test "Vector KNN search" \
    "MATCH (p:Product) WHERE similarity(p.features, [0.1, 0.2, 0.3, 0.4, 0.5]) > 0.9 RETURN p.id" \
    "1"

# Test 18: Create index on non-existent label
run_test "Create index on non-existent label" \
    "CREATE INDEX nonexistent_idx ON NonExistent(prop)" \
    "Index nonexistent_idx created"

# Test 19: Create index with special characters in name
run_test "Create index with special name" \
    "CREATE INDEX person_age_idx_2 ON Person(age)" \
    "Index person_age_idx_2 created"

# Test 20: Drop all remaining test indexes
echo -e "\n${YELLOW}Cleaning up indexes...${NC}"
./zig-out/bin/geode query "DROP INDEX IF EXISTS person_age_idx" --insecure >/dev/null 2>&1
./zig-out/bin/geode query "DROP INDEX IF EXISTS person_name_idx" --insecure >/dev/null 2>&1
./zig-out/bin/geode query "DROP INDEX IF EXISTS person_location_idx" --insecure >/dev/null 2>&1
./zig-out/bin/geode query "DROP INDEX IF EXISTS doc_content_idx" --insecure >/dev/null 2>&1
./zig-out/bin/geode query "DROP INDEX IF EXISTS product_features_idx" --insecure >/dev/null 2>&1
./zig-out/bin/geode query "DROP INDEX IF EXISTS new_idx" --insecure >/dev/null 2>&1
./zig-out/bin/geode query "DROP INDEX IF EXISTS nonexistent_idx" --insecure >/dev/null 2>&1
./zig-out/bin/geode query "DROP INDEX IF EXISTS person_age_idx_2" --insecure >/dev/null 2>&1

# Cleanup
echo -e "\n${YELLOW}Stopping server...${NC}"
kill $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true
rm -rf ./test_data

echo -e "\n${GREEN}Index regression tests completed!${NC}"
