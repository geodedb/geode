#!/bin/bash
set -euo pipefail

# Backup and Restore Operations Regression Test Suite
# Tests BACKUP TO and RESTORE FROM functionality

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
./zig-out/bin/geode query "CREATE (n:Person {name: 'Alice', age: 30})" --insecure >/dev/null 2>&1
./zig-out/bin/geode query "CREATE (n:Person {name: 'Bob', age: 25})" --insecure >/dev/null 2>&1
./zig-out/bin/geode query "CREATE (n:Company {name: 'TechCorp', employees: 100})" --insecure >/dev/null 2>&1
./zig-out/bin/geode query "MATCH (p:Person {name: 'Alice'}), (c:Company {name: 'TechCorp'}) CREATE (p)-[:WORKS_AT]->(c)" --insecure >/dev/null 2>&1

echo -e "\n${YELLOW}Running backup/restore regression tests...${NC}"

# Test 1: Basic backup
run_test "Basic backup" \
    "BACKUP TO './backup_test_1.bak'" \
    "Backup completed"

# Test 2: Verify backup file exists
if [ -f "./backup_test_1.bak" ]; then
    echo -e "Backup file creation... ${GREEN}PASSED${NC}"
else
    echo -e "Backup file creation... ${RED}FAILED${NC}"
fi

# Test 3: Backup to nested directory
mkdir -p ./backups/nested
run_test "Backup to nested directory" \
    "BACKUP TO './backups/nested/backup_test_2.bak'" \
    "Backup completed"

# Test 4: Backup with special characters in path
run_test "Backup with special path" \
    "BACKUP TO './backup_test_$(date +%Y%m%d).bak'" \
    "Backup completed"

# Test 5: Query data before restore
original_count=$(./zig-out/bin/geode query "MATCH (n) RETURN count(n) AS count" --insecure 2>&1 | grep -o '[0-9]*' | head -1)
echo "Original node count: $original_count"

# Test 6: Delete some data
./zig-out/bin/geode query "MATCH (n:Person {name: 'Bob'}) DELETE n" --insecure >/dev/null 2>&1

# Test 7: Verify data was deleted
new_count=$(./zig-out/bin/geode query "MATCH (n) RETURN count(n) AS count" --insecure 2>&1 | grep -o '[0-9]*' | head -1)
if [ "$new_count" -lt "$original_count" ]; then
    echo -e "Data deletion verified... ${GREEN}PASSED${NC}"
else
    echo -e "Data deletion verified... ${RED}FAILED${NC}"
fi

# Test 8: Basic restore
run_test "Basic restore" \
    "RESTORE FROM './backup_test_1.bak'" \
    "Restore completed"

# Test 9: Verify data was restored
restored_count=$(./zig-out/bin/geode query "MATCH (n) RETURN count(n) AS count" --insecure 2>&1 | grep -o '[0-9]*' | head -1)
if [ "$restored_count" -eq "$original_count" ]; then
    echo -e "Data restoration verified... ${GREEN}PASSED${NC}"
else
    echo -e "Data restoration verified... ${RED}FAILED${NC}"
    echo "  Expected: $original_count, Got: $restored_count"
fi

# Test 10: Restore from nested directory
run_test "Restore from nested directory" \
    "RESTORE FROM './backups/nested/backup_test_2.bak'" \
    "Restore completed"

# Test 11: Verify only (without actual restore)
run_test "Verify backup without restore" \
    "RESTORE FROM './backup_test_1.bak' VERIFY ONLY" \
    "Backup verified"

# Test 12: Restore with timestamp (if supported)
current_time=$(date +%s)
run_test "Restore with timestamp" \
    "RESTORE FROM './backup_test_1.bak' TIMESTAMP '$current_time'" \
    "Restore completed\|timestamp"

# Test 13: Backup after creating index
./zig-out/bin/geode query "CREATE INDEX person_name_idx ON Person(name)" --insecure >/dev/null 2>&1
run_test "Backup with indexes" \
    "BACKUP TO './backup_with_index.bak'" \
    "Backup completed"

# Test 14: Drop index and restore
./zig-out/bin/geode query "DROP INDEX person_name_idx" --insecure >/dev/null 2>&1
run_test "Restore with indexes" \
    "RESTORE FROM './backup_with_index.bak'" \
    "Restore completed"

# Test 15: Verify index was restored
index_exists=$(./zig-out/bin/geode query "SHOW INDEXES" --insecure 2>&1 | grep -c "person_name_idx" || true)
if [ "$index_exists" -gt 0 ]; then
    echo -e "Index restoration... ${GREEN}PASSED${NC}"
else
    echo -e "Index restoration... ${RED}FAILED${NC}"
fi

# Test 16: Backup empty database
./zig-out/bin/geode query "MATCH (n) DETACH DELETE n" --insecure >/dev/null 2>&1
run_test "Backup empty database" \
    "BACKUP TO './empty_backup.bak'" \
    "Backup completed"

# Test 17: Restore empty backup
./zig-out/bin/geode query "CREATE (n:Test {value: 1})" --insecure >/dev/null 2>&1
run_test "Restore empty backup" \
    "RESTORE FROM './empty_backup.bak'" \
    "Restore completed"

# Test 18: Verify empty restore
empty_count=$(./zig-out/bin/geode query "MATCH (n) RETURN count(n) AS count" --insecure 2>&1 | grep -o '[0-9]*' | head -1)
if [ "$empty_count" -eq 0 ]; then
    echo -e "Empty database restoration... ${GREEN}PASSED${NC}"
else
    echo -e "Empty database restoration... ${RED}FAILED${NC}"
fi

# Test 19: Restore non-existent file
run_test "Restore non-existent file" \
    "RESTORE FROM './nonexistent.bak'" \
    "error\|not found\|failed"

# Test 20: Large backup test
echo -e "\n${YELLOW}Creating large dataset for backup test...${NC}"
for i in {1..100}; do
    ./zig-out/bin/geode query "CREATE (n:Node {id: $i, data: 'test_data_$i'})" --insecure >/dev/null 2>&1
done

run_test "Large backup" \
    "BACKUP TO './large_backup.bak'" \
    "Backup completed"

# Verify large backup file size
if [ -f "./large_backup.bak" ]; then
    file_size=$(stat -f%z "./large_backup.bak" 2>/dev/null || stat -c%s "./large_backup.bak" 2>/dev/null)
    if [ "$file_size" -gt 1000 ]; then
        echo -e "Large backup file size... ${GREEN}PASSED${NC} (Size: $file_size bytes)"
    else
        echo -e "Large backup file size... ${RED}FAILED${NC} (Size too small: $file_size bytes)"
    fi
fi

# Cleanup
echo -e "\n${YELLOW}Cleaning up...${NC}"
rm -f *.bak
rm -rf ./backups
kill $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true
rm -rf ./test_data

echo -e "\n${GREEN}Backup/Restore regression tests completed!${NC}"
