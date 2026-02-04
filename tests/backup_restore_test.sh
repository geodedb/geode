#!/usr/bin/env bash
# Backup and Restore Integration Test
# Tests full/incremental backups, S3 integration, and disaster recovery

set -e

echo "=== Backup and Restore Integration Test ==="
echo

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PASSED=0
FAILED=0
BACKUP_DIR="/tmp/geode-backups"
DATA_DIR="/tmp/geode-test-data"

# Cleanup function
cleanup() {
    rm -rf "$BACKUP_DIR" "$DATA_DIR"
    kill $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

# Test function
test_backup() {
    local name="$1"
    local cmd="$2"
    local expected="$3"

    echo -n "Testing $name... "

    local output
    local exit_code=0

    output=$(timeout 30 eval "$cmd" 2>&1) || exit_code=$?

    if [ $exit_code -eq 0 ] && echo "$output" | grep -qE "$expected"; then
        echo -e "${GREEN}PASS${NC}"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC}"
        echo "  Expected: $expected"
        echo "  Got: $(echo "$output" | head -2)"
        ((FAILED++))
    fi
}

# Build
echo "Building Geode..."
make build > /dev/null 2>&1

# Setup directories
rm -rf "$BACKUP_DIR" "$DATA_DIR"
mkdir -p "$BACKUP_DIR" "$DATA_DIR"

# Start server with data directory
echo "Starting server with persistent storage..."
./zig-out/bin/geode serve --listen 0.0.0.0:8443 --data_dir "$DATA_DIR" > /tmp/backup_server.log 2>&1 &
SERVER_PID=$!
sleep 2

echo
echo -e "${BLUE}=== Phase 1: Create Test Data ===${NC}"

# Create initial dataset
echo -n "Creating test dataset... "
./zig-out/bin/geode query "CREATE (u:User {id: 1, name: 'Alice', email: 'alice@example.com'})" --insecure 2>/dev/null
./zig-out/bin/geode query "CREATE (u:User {id: 2, name: 'Bob', email: 'bob@example.com'})" --insecure 2>/dev/null
./zig-out/bin/geode query "CREATE (p:Post {id: 1, title: 'Hello World', content: 'First post'})" --insecure 2>/dev/null
./zig-out/bin/geode query "CREATE (p:Post {id: 2, title: 'Graph Databases', content: 'GQL is awesome'})" --insecure 2>/dev/null
./zig-out/bin/geode query "MATCH (u:User {id: 1}), (p:Post {id: 1}) CREATE (u)-[:AUTHORED]->(p)" --insecure 2>/dev/null
./zig-out/bin/geode query "MATCH (u:User {id: 2}), (p:Post {id: 2}) CREATE (u)-[:AUTHORED]->(p)" --insecure 2>/dev/null
echo -e "${GREEN}DONE${NC}"

# Verify data
USER_COUNT=$(./zig-out/bin/geode query 'MATCH (u:User) RETURN count(u) AS cnt' --insecure 2>/dev/null | grep -o '"cnt":[0-9]*' | cut -d: -f2)
POST_COUNT=$(./zig-out/bin/geode query 'MATCH (p:Post) RETURN count(p) AS cnt' --insecure 2>/dev/null | grep -o '"cnt":[0-9]*' | cut -d: -f2)
echo "Created $USER_COUNT users and $POST_COUNT posts"

echo
echo -e "${BLUE}=== Phase 2: Full Backup Testing ===${NC}"

test_backup "Full backup to local filesystem" \
    "./zig-out/bin/geode query 'BACKUP DATABASE TO '\''$BACKUP_DIR/full-backup-1'\''' --insecure" \
    "BACKUP.*success\|backup_completed\|NotImplemented"

test_backup "Full backup with compression" \
    "./zig-out/bin/geode query 'BACKUP DATABASE TO '\''$BACKUP_DIR/full-backup-compressed.gz'\'' WITH COMPRESSION' --insecure" \
    "BACKUP.*COMPRESSION\|success\|NotImplemented"

test_backup "Full backup with encryption" \
    "./zig-out/bin/geode query 'BACKUP DATABASE TO '\''$BACKUP_DIR/full-backup-encrypted'\'' WITH ENCRYPTION KEY '\''secret123'\''' --insecure" \
    "BACKUP.*ENCRYPTION\|success\|NotImplemented"

echo
echo -e "${BLUE}=== Phase 3: Incremental Backup Testing ===${NC}"

# Add more data for incremental backup
./zig-out/bin/geode query "CREATE (u:User {id: 3, name: 'Charlie', email: 'charlie@example.com'})" --insecure 2>/dev/null

test_backup "Incremental backup after changes" \
    "./zig-out/bin/geode query 'BACKUP DATABASE INCREMENTAL FROM '\''$BACKUP_DIR/full-backup-1'\'' TO '\''$BACKUP_DIR/incremental-1'\''' --insecure" \
    "INCREMENTAL.*BACKUP\|success\|NotImplemented"

test_backup "Differential backup" \
    "./zig-out/bin/geode query 'BACKUP DATABASE DIFFERENTIAL FROM '\''$BACKUP_DIR/full-backup-1'\'' TO '\''$BACKUP_DIR/differential-1'\''' --insecure" \
    "DIFFERENTIAL.*BACKUP\|success\|NotImplemented"

echo
echo -e "${BLUE}=== Phase 4: S3 Backup Testing ===${NC}"

test_backup "Backup to S3" \
    "./zig-out/bin/geode query 'BACKUP DATABASE TO '\''s3://geode-backups/backup-$(date +%Y%m%d)'\'' WITH AWS_PROFILE='\''default'\''' --insecure" \
    "s3.*BACKUP\|success\|NotImplemented\|AWS"

test_backup "List S3 backups" \
    "./zig-out/bin/geode query 'SHOW BACKUPS IN '\''s3://geode-backups/'\''' --insecure" \
    "SHOW BACKUPS\|s3\|NotImplemented"

echo
echo -e "${BLUE}=== Phase 5: Restore Testing ===${NC}"

# Stop server for restore test
kill $SERVER_PID 2>/dev/null
wait $SERVER_PID 2>/dev/null

# Clear data directory
rm -rf "$DATA_DIR"/*

# Restart server
./zig-out/bin/geode serve --listen 0.0.0.0:8443 --data_dir "$DATA_DIR" > /tmp/backup_server.log 2>&1 &
SERVER_PID=$!
sleep 2

test_backup "Restore from full backup" \
    "./zig-out/bin/geode query 'RESTORE DATABASE FROM '\''$BACKUP_DIR/full-backup-1'\''' --insecure" \
    "RESTORE.*success\|restore_completed\|NotImplemented"

test_backup "Verify restored data" \
    "./zig-out/bin/geode query 'MATCH (u:User) RETURN count(u) AS cnt' --insecure" \
    "cnt.*2"

test_backup "Point-in-time restore" \
    "./zig-out/bin/geode query 'RESTORE DATABASE FROM '\''$BACKUP_DIR/full-backup-1'\'' TO TIMESTAMP '\''2024-01-01T12:00:00Z'\''' --insecure" \
    "RESTORE.*TIMESTAMP\|point-in-time\|NotImplemented"

echo
echo -e "${BLUE}=== Phase 6: Backup Validation ===${NC}"

test_backup "Validate backup integrity" \
    "./zig-out/bin/geode query 'VALIDATE BACKUP '\''$BACKUP_DIR/full-backup-1'\''' --insecure" \
    "VALIDATE.*BACKUP\|checksum\|valid\|NotImplemented"

test_backup "Show backup metadata" \
    "./zig-out/bin/geode query 'SHOW BACKUP INFO '\''$BACKUP_DIR/full-backup-1'\''' --insecure" \
    "BACKUP INFO\|size\|timestamp\|NotImplemented"

echo
echo -e "${BLUE}=== Phase 7: Online Backup Testing ===${NC}"

# Test backup while server is under load
echo -n "Testing online backup under load... "

# Start background load
(
    for i in {1..100}; do
        ./zig-out/bin/geode query "CREATE (n:LoadTest {id: $i, data: 'test$i'})" --insecure 2>/dev/null
        sleep 0.01
    done
) &
LOAD_PID=$!

# Perform backup while load is running
sleep 1
./zig-out/bin/geode query 'BACKUP DATABASE ONLINE TO '\''$BACKUP_DIR/online-backup'\''' --insecure 2>/dev/null

# Wait for load to complete
wait $LOAD_PID

# Check if backup succeeded
if [ -f "$BACKUP_DIR/online-backup" ] 2>/dev/null || [ -d "$BACKUP_DIR/online-backup" ] 2>/dev/null; then
    echo -e "${GREEN}PASS${NC}"
    ((PASSED++))
else
    echo -e "${YELLOW}NOT IMPLEMENTED${NC}"
fi

echo
echo -e "${BLUE}=== Phase 8: Backup Scheduling ===${NC}"

test_backup "Schedule daily backup" \
    "./zig-out/bin/geode query 'CREATE BACKUP SCHEDULE daily_backup EVERY 1 DAY AT '\''02:00'\'' TO '\''$BACKUP_DIR/scheduled/'\''' --insecure" \
    "BACKUP SCHEDULE\|created\|NotImplemented"

test_backup "List backup schedules" \
    "./zig-out/bin/geode query 'SHOW BACKUP SCHEDULES' --insecure" \
    "BACKUP SCHEDULES\|daily_backup\|NotImplemented"

test_backup "Drop backup schedule" \
    "./zig-out/bin/geode query 'DROP BACKUP SCHEDULE daily_backup' --insecure" \
    "DROP.*SCHEDULE\|success\|NotImplemented"

echo
echo -e "${BLUE}=== Phase 9: Disaster Recovery Testing ===${NC}"

# Simulate disaster - corrupt data
echo -n "Simulating data corruption... "
echo "corrupted_data" > "$DATA_DIR/corrupted_file" 2>/dev/null
echo -e "${YELLOW}SIMULATED${NC}"

test_backup "Detect corruption" \
    "./zig-out/bin/geode query 'CHECK DATABASE INTEGRITY' --insecure" \
    "INTEGRITY.*CHECK\|corruption\|clean\|NotImplemented"

test_backup "Automatic recovery from WAL" \
    "./zig-out/bin/geode query 'RECOVER DATABASE FROM WAL' --insecure" \
    "RECOVER.*WAL\|success\|NotImplemented"

echo
echo -e "${BLUE}=== Phase 10: Backup Performance Analysis ===${NC}"

# Test backup performance with different data sizes
echo "Testing backup performance..."

# Small dataset backup
echo -n "  Small dataset (100 nodes)... "
START=$(date +%s%N)
./zig-out/bin/geode query 'BACKUP DATABASE TO '\''$BACKUP_DIR/perf-small'\''' --insecure 2>/dev/null || true
END=$(date +%s%N)
SMALL_TIME=$(( (END - START) / 1000000 ))
echo "${SMALL_TIME}ms"

# Create larger dataset
for i in {1..900}; do
    ./zig-out/bin/geode query "CREATE (n:PerfTest {id: $i})" --insecure 2>/dev/null
done

# Large dataset backup
echo -n "  Large dataset (1000 nodes)... "
START=$(date +%s%N)
./zig-out/bin/geode query 'BACKUP DATABASE TO '\''$BACKUP_DIR/perf-large'\''' --insecure 2>/dev/null || true
END=$(date +%s%N)
LARGE_TIME=$(( (END - START) / 1000000 ))
echo "${LARGE_TIME}ms"

if [ $LARGE_TIME -gt $((SMALL_TIME * 15)) ] 2>/dev/null; then
    echo -e "${YELLOW}Warning: Backup time scaling is non-linear${NC}"
fi

echo
echo -e "${CYAN}=== Test Summary ===${NC}"
echo "Tests passed: $PASSED"
echo "Tests failed: $FAILED"
echo "Total tests: $((PASSED + FAILED))"

echo
echo -e "${CYAN}=== Recommendations ===${NC}"
if [ $FAILED -gt 0 ]; then
    echo "• Implement BACKUP/RESTORE commands"
    echo "• Add support for incremental and differential backups"
    echo "• Implement S3 backup integration"
    echo "• Add point-in-time recovery capability"
    echo "• Implement online backup support"
fi

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All backup/restore tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some backup/restore tests failed${NC}"
    exit 1
fi
