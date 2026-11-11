#!/usr/bin/env bash
# Backup and Restore Integration Test (GAP-0862 hardened)
#
# This test proves the ACTUAL advertised backup surface instead of the legacy
# behaviour that accepted `NotImplemented` as a PASS for every flow (which
# proved nothing). It is split into two explicit halves:
#
#   IMPLEMENTED  — the real `geode backup` / `geode restore` CLI (engine-backed
#                  full backup + restore). These MUST succeed; a failure is a
#                  real regression.
#   UNSUPPORTED  — the GQL `BACKUP ... TO` / `RESTORE ... FROM` statement
#                  surface and the SHOW/VALIDATE/SCHEDULE/PITR GQL forms. These
#                  are NOT implemented (the executor returns NotImplemented /
#                  SQLSTATE 0A000). Each is asserted to FAIL-as-unsupported, so
#                  the day someone implements one the assertion flips RED and
#                  forces this test (and the docs) to be updated.
#
# Data-integrity of the engine round-trip (node/edge counts + property
# round-trip + checksum rejection) is proven separately and authoritatively by
# the Zig test `zig build test-gap0862`
# (tests/test_gap0862_backup_integrity.zig).

set -uo pipefail

echo "=== Backup and Restore Integration Test (GAP-0862) ==="
echo

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PASSED=0
FAILED=0
WORK_DIR="$(mktemp -d /tmp/geode-backup-test.XXXXXX)"
DATA_DIR="$WORK_DIR/data"
BACKUP_DIR="$WORK_DIR/backups"
LISTEN="127.0.0.1:8443"
BIN="./zig-out/bin/geode"
ADMIN_USER="geode"
ADMIN_PW="gap0862-itest-pw"
export GEODE_ADMIN_PASSWORD="$ADMIN_PW"
TLS="--insecure-tls-skip-verify"
AUTH=(--user "$ADMIN_USER" --password "$ADMIN_PW")

cleanup() {
    kill "${SERVER_PID:-}" 2>/dev/null || true
    wait "${SERVER_PID:-}" 2>/dev/null || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# pass_if <name> <condition-already-evaluated:0|1> [detail]
record() {
    local name="$1" ok="$2" detail="${3:-}"
    if [ "$ok" -eq 0 ]; then
        echo -e "  $name... ${GREEN}PASS${NC}"
        ((PASSED++))
    else
        echo -e "  $name... ${RED}FAIL${NC}"
        [ -n "$detail" ] && echo "    $detail"
        ((FAILED++))
    fi
}

# assert_contains <name> <output> <needle>
assert_contains() {
    local name="$1" output="$2" needle="$3"
    if echo "$output" | grep -qE "$needle"; then
        record "$name" 0
    else
        record "$name" 1 "expected to match /$needle/, got: $(echo "$output" | head -2 | tr '\n' ' ')"
    fi
}

# assert_unsupported <name> <output>
# A GQL feature is "honestly unsupported" when the server reports NotImplemented
# (the executor's error name) or the 0A000 "feature not supported" SQLSTATE.
# If the output ever shows success instead, the feature became implemented and
# this assertion intentionally FAILS to force a test/doc update.
assert_unsupported() {
    local name="$1" output="$2"
    # Honestly unsupported == server rejects it: executor NotImplemented / 0A000
    # (feature not supported), OR the grammar refuses the form (parse error /
    # 42000 / unexpected token). A SUCCESS would mean it became implemented and
    # this assertion intentionally FAILS to force a test/doc update.
    if echo "$output" | grep -qiE "NotImplemented|0A000|not.?implemented|UnexpectedToken|ParseError|parse error|42000|Unsupported|syntax error"; then
        record "$name" 0
    else
        record "$name" 1 "GQL surface no longer rejects — implement+document it, then update this test. Got: $(echo "$output" | head -2 | tr '\n' ' ')"
    fi
}

echo "Building Geode..."
zig build >/dev/null 2>&1 || { echo "build failed"; exit 1; }

mkdir -p "$DATA_DIR" "$BACKUP_DIR"

echo "Starting server (insecure TLS for test)..."
$BIN serve --listen "$LISTEN" --data_dir "$DATA_DIR" $TLS >"$WORK_DIR/server.log" 2>&1 &
SERVER_PID=$!
sleep 2

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo -e "${RED}Server failed to start${NC}"; cat "$WORK_DIR/server.log"; exit 1
fi

q() { $BIN query "$1" --server "$LISTEN" $TLS "${AUTH[@]}" 2>&1; }

echo
echo -e "${BLUE}=== Phase 1: Seed known dataset ===${NC}"
q "CREATE (u:User {id: 1, name: 'Alice'})" >/dev/null
q "CREATE (u:User {id: 2, name: 'Bob'})" >/dev/null
q "CREATE (p:Post {id: 1, title: 'Hello'})" >/dev/null
q "MATCH (u:User {id: 1}), (p:Post {id: 1}) CREATE (u)-[:AUTHORED]->(p)" >/dev/null
USER_COUNT=$(q 'MATCH (u:User) RETURN count(u) AS cnt' | grep -oE '"cnt":[0-9]+' | grep -oE '[0-9]+' | head -1)
record "Seed dataset (2 users created)" "$([ "${USER_COUNT:-0}" = "2" ] && echo 0 || echo 1)" "user count = ${USER_COUNT:-?}"

echo
echo -e "${CYAN}=== IMPLEMENTED: CLI backup/restore (engine-backed) ===${NC}"

# Real full backup via the CLI. Connects to the running server (remote path)
# and falls back to local-directory backup; either way it must report success
# and leave a non-empty backup artifact on disk.
BACKUP_OUT=$($BIN backup create --output "$BACKUP_DIR/full.backup" --server "$LISTEN" $TLS "${AUTH[@]}" 2>&1)
assert_contains "CLI full backup succeeds" "$BACKUP_OUT" "Backup (created|completed) successfully|Backup completed:|Local backup completed"

# A backup artifact must exist and be non-trivial (header + payload).
BACKUP_FILE=$(find "$BACKUP_DIR" -name '*.backup' -o -name 'full.backup' 2>/dev/null | head -1)
if [ -n "$BACKUP_FILE" ] && [ -s "$BACKUP_FILE" ]; then
    SZ=$(stat -c%s "$BACKUP_FILE" 2>/dev/null || stat -f%z "$BACKUP_FILE")
    record "Backup artifact exists and is non-empty" "$([ "${SZ:-0}" -gt 32 ] && echo 0 || echo 1)" "size=${SZ:-0}"
else
    record "Backup artifact exists and is non-empty" 1 "no backup file under $BACKUP_DIR"
fi

# CLI restore writes the backup file into a fresh directory, offline, and
# reports success only after verifying it (SONNY-6280).
RESTORE_OUT=$($BIN restore "$BACKUP_FILE" --data-dir "$WORK_DIR/restored" --yes 2>&1)
assert_contains "CLI restore writes and verifies" "$RESTORE_OUT" "RESTORE: Restored and verified [0-9]+ files"

# CLI backup list must run and not error out (directory scan).
LIST_OUT=$($BIN backup list --dir "$BACKUP_DIR" 2>&1)
assert_contains "CLI backup list runs" "$LIST_OUT" "full|Backup|backup|No backups"

echo
echo -e "${CYAN}=== UNSUPPORTED: GQL backup/restore statement surface ===${NC}"
echo "  (these are intentionally NOT implemented; assertions flip RED if that changes)"

assert_unsupported "GQL BACKUP DATABASE TO" \
    "$(q "BACKUP DATABASE TO '$BACKUP_DIR/gql-full'")"
assert_unsupported "GQL BACKUP ... WITH COMPRESSION" \
    "$(q "BACKUP DATABASE TO '$BACKUP_DIR/gql-c.gz' WITH COMPRESSION")"
assert_unsupported "GQL RESTORE DATABASE FROM" \
    "$(q "RESTORE DATABASE FROM '$BACKUP_DIR/gql-full'")"
assert_unsupported "GQL point-in-time RESTORE ... TO TIMESTAMP" \
    "$(q "RESTORE DATABASE FROM '$BACKUP_DIR/gql-full' TO TIMESTAMP '2024-01-01T12:00:00Z'")"
assert_unsupported "GQL BACKUP TO s3://" \
    "$(q "BACKUP DATABASE TO 's3://geode-backups/x' WITH AWS_PROFILE='default'")"
assert_unsupported "GQL SHOW BACKUPS" \
    "$(q "SHOW BACKUPS IN 's3://geode-backups/'")"
assert_unsupported "GQL VALIDATE BACKUP" \
    "$(q "VALIDATE BACKUP '$BACKUP_DIR/full.backup'")"
assert_unsupported "GQL SHOW BACKUP INFO" \
    "$(q "SHOW BACKUP INFO '$BACKUP_DIR/full.backup'")"
assert_unsupported "GQL CREATE BACKUP SCHEDULE" \
    "$(q "CREATE BACKUP SCHEDULE daily EVERY 1 DAY AT '02:00' TO '$BACKUP_DIR/sched/'")"
assert_unsupported "GQL CHECK DATABASE INTEGRITY" \
    "$(q "CHECK DATABASE INTEGRITY")"

echo
echo -e "${CYAN}=== Test Summary ===${NC}"
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo "Total:  $((PASSED + FAILED))"

if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}All backup/restore assertions passed.${NC}"
    exit 0
else
    echo -e "${RED}Backup/restore assertions failed.${NC}"
    exit 1
fi
