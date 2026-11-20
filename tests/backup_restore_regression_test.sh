#!/bin/bash
# Backup / Restore regression suite (GAP-0862 hardened)
#
# Previously this suite issued GQL `BACKUP TO '...'` / `RESTORE FROM '...'`
# statements and grepped for "Backup completed" — but that GQL surface is NOT
# implemented (the executor returns NotImplemented / SQLSTATE 0A000), so the
# suite could never pass and proved nothing. It is rewritten to:
#
#   * exercise the REAL implemented surface — the `geode backup` / `geode
#     restore` CLI (engine-backed) — with hard success assertions, AND
#   * assert the GQL statement surface is HONESTLY unsupported, so the suite
#     turns RED (forcing a test+doc update) the day it gets implemented.
#
# Engine-level data-integrity (node/edge counts, property round-trip, checksum
# rejection) is proven authoritatively by `zig build test-gap0862`
# (tests/test_gap0862_backup_integrity.zig).

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
WORK_DIR="$(mktemp -d /tmp/geode-backup-regression.XXXXXX)"
DATA_DIR="$WORK_DIR/data"
BACKUP_DIR="$WORK_DIR/backups"
LISTEN="127.0.0.1:8443"
BIN="./zig-out/bin/geode"
ADMIN_USER="geode"
ADMIN_PW="Gap Backup Restore Regression Passphrase"
export GEODE_ADMIN_PASSWORD="$ADMIN_PW"
TLS="--insecure-tls-skip-verify"
AUTH=(--user "$ADMIN_USER" --password "$ADMIN_PW")

cleanup() {
    kill "${SERVER_PID:-}" 2>/dev/null || true
    wait "${SERVER_PID:-}" 2>/dev/null || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

ok()   { echo -e "$1... ${GREEN}PASSED${NC}"; ((PASS++)); }
bad()  { echo -e "$1... ${RED}FAILED${NC}"; [ -n "${2:-}" ] && echo "  $2"; ((FAIL++)); }

assert_match() { # name output regex
    if echo "$2" | grep -qE "$3"; then ok "$1"; else bad "$1" "expected /$3/, got: $(echo "$2" | head -2 | tr '\n' ' ')"; fi
}
assert_unsupported() { # name output
    # Honestly unsupported == the server rejects it: executor NotImplemented /
    # 0A000 (feature not supported), OR the GQL grammar refuses the statement
    # form (parse error / 42000 / unexpected token). Any of these is a truthful
    # "we don't support that". A SUCCESS response would mean the surface became
    # implemented — the assertion then fails on purpose to force a test+doc fix.
    if echo "$2" | grep -qiE "NotImplemented|0A000|not.?implemented|UnexpectedToken|ParseError|parse error|42000|Unsupported|syntax error"; then
        ok "$1 (honestly unsupported)"
    else
        bad "$1" "GQL surface no longer rejects — implement+document, then update this test. Got: $(echo "$2" | head -2 | tr '\n' ' ')"
    fi
}

q() { $BIN query "$1" --server "$LISTEN" $TLS "${AUTH[@]}" 2>&1; }

echo -e "${YELLOW}Building Geode...${NC}"
zig build >/dev/null 2>&1 || { echo "build failed"; exit 1; }

mkdir -p "$DATA_DIR" "$BACKUP_DIR"
HAD_DATA=0; [ -e "./data" ] && HAD_DATA=1
HAD_LEGACY=0; [ -e "./server_backups/metadata.json" ] && HAD_LEGACY=1

echo -e "${YELLOW}Starting Geode server (insecure TLS for test)...${NC}"
$BIN serve --listen "$LISTEN" --data_dir "$DATA_DIR" $TLS >"$WORK_DIR/server.log" 2>&1 &
SERVER_PID=$!
sleep 2
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo -e "${RED}Server failed to start${NC}"; cat "$WORK_DIR/server.log"; exit 1
fi

echo -e "${YELLOW}Creating test data...${NC}"
q "CREATE (n:Person {name: 'Alice', age: 30})" >/dev/null
q "CREATE (n:Person {name: 'Bob', age: 25})" >/dev/null
q "CREATE (n:Company {name: 'TechCorp', employees: 100})" >/dev/null
q "MATCH (p:Person {name: 'Alice'}), (c:Company {name: 'TechCorp'}) CREATE (p)-[:WORKS_AT]->(c)" >/dev/null

# Extract the count value from the JSON column (avoid matching SQLSTATE 00000).
NODE_COUNT=$(q "MATCH (n) RETURN count(n) AS cnt" | grep -oE '"cnt":[0-9]+' | grep -oE '[0-9]+' | head -1)
assert_match "Seed data created (3 nodes)" "${NODE_COUNT:-0}" "^3$"

echo -e "\n${YELLOW}IMPLEMENTED: CLI backup/restore${NC}"

# Test 1: CLI full backup
BACKUP_OUT=$($BIN backup create --output "$BACKUP_DIR/regression.backup" --server "$LISTEN" $TLS "${AUTH[@]}" 2>&1)
assert_match "CLI backup create" "$BACKUP_OUT" "Backup (created|completed) successfully|Backup completed:|Local backup completed"

# Test 2: backup artifact present and non-trivial
BACKUP_FILE=$(find "$BACKUP_DIR" -name '*.backup' 2>/dev/null | head -1)
if [ -n "$BACKUP_FILE" ] && [ -s "$BACKUP_FILE" ]; then
    SZ=$(stat -c%s "$BACKUP_FILE" 2>/dev/null || stat -f%z "$BACKUP_FILE")
    if [ "${SZ:-0}" -gt 32 ]; then ok "Backup file present (${SZ} bytes)"; else bad "Backup file present" "too small: ${SZ}"; fi
else
    bad "Backup file present" "no .backup file under $BACKUP_DIR"
fi

# Test 2b (SONNY-6299): the backup holds no key material or lock file, and
# the server keeps its own backups under its data directory, not in
# ./server_backups of its working directory.
if [ -n "$BACKUP_FILE" ] && grep -qaE 'server\.key|\.geode_hmac_key|\.geode_admin_password|\.geode\.lock' "$BACKUP_FILE"; then
    bad "Backup holds no key material or lock file" "found a key/lock entry name in $BACKUP_FILE"
else
    ok "Backup holds no key material or lock file"
fi
if ls "$DATA_DIR"/backups/full_*.backup >/dev/null 2>&1 && [ ! -e "./server_backups/metadata.json" -o "$HAD_LEGACY" = 1 ]; then
    ok "Server backups live under the data directory"
else
    bad "Server backups live under the data directory" "no $DATA_DIR/backups/full_*.backup (or a new ./server_backups)"
fi

# Test 3: CLI restore of the backup file into a fresh directory (offline;
# SONNY-6280: it used to write nothing and still report success). The
# backup holds auth records, and (SONNY-6299) not the HMAC key: without it
# the restore refuses; with the source's key file it verifies and restores.
NOKEY_OUT=$($BIN restore "$BACKUP_FILE" --data-dir "$WORK_DIR/restored-nokey" --yes 2>&1 || true)
assert_match "CLI restore without the HMAC key refuses" "$NOKEY_OUT" "HmacKeyRequired"
RESTORE_OUT=$($BIN restore "$BACKUP_FILE" --data-dir "$WORK_DIR/restored" --yes --hmac-key-file "$DATA_DIR/.geode_hmac_key" 2>&1)
assert_match "CLI restore" "$RESTORE_OUT" "RESTORE: Restored and verified [0-9]+ files"
assert_match "CLI restore verifies the auth chain" "$RESTORE_OUT" "HMAC chain verified"

# Test 3b: server restore (SONNY-6288). The server restores its newest
# server-side backup into a NEW directory beside its --data-dir and reports
# it; it never writes into its data directory or into ./data in its working
# directory (it used to, and answered "Restore completed" while serving the
# old data). The running server keeps serving its current data.
SERVER_BACKUP_OUT=$($BIN backup create --output "$BACKUP_DIR/server-side.backup" --server "$LISTEN" $TLS "${AUTH[@]}" 2>&1)
assert_match "CLI backup create (server-side copy for restore)" "$SERVER_BACKUP_OUT" "Backup (created|completed) successfully|Backup completed:"
SERVER_RESTORE_OUT=$($BIN restore --server "$LISTEN" $TLS "${AUTH[@]}" --yes 2>&1)
assert_match "Server restore reports a new directory beside --data-dir" "$SERVER_RESTORE_OUT" "Restored into: ${DATA_DIR}\.restored-"
assert_match "Server restore says the server still serves its data" "$SERVER_RESTORE_OUT" "still serves"
if [ "$HAD_DATA" = 0 ] && [ -e "./data" ]; then
    bad "Server restore wrote nothing into ./data" "./data exists in the server's working directory"
else
    ok "Server restore wrote nothing into ./data"
fi
AFTER_COUNT=$(q "MATCH (n) RETURN count(n) AS cnt" | grep -oE '"cnt":[0-9]+' | grep -oE '[0-9]+' | head -1)
assert_match "Server keeps serving its data after a server restore (3 nodes)" "${AFTER_COUNT:-0}" "^3$"

# Test 4: CLI restore of a non-existent file fails (negative)
MISSING_OUT=$($BIN restore "$BACKUP_DIR/does-not-exist.backup" --data-dir "$WORK_DIR/restored-missing" --yes 2>&1 || true)
assert_match "CLI restore of missing file fails" "$MISSING_OUT" "[Ee]rror|not found|FileNotFound|failed|No backup"

echo -e "\n${YELLOW}UNSUPPORTED: GQL statement surface (must reject)${NC}"
assert_unsupported "GQL BACKUP TO" "$(q "BACKUP TO '$BACKUP_DIR/gql.bak'")"
assert_unsupported "GQL RESTORE FROM" "$(q "RESTORE FROM '$BACKUP_DIR/gql.bak'")"
assert_unsupported "GQL RESTORE ... VERIFY ONLY" "$(q "RESTORE FROM '$BACKUP_DIR/gql.bak' VERIFY ONLY")"
assert_unsupported "GQL RESTORE ... TIMESTAMP" "$(q "RESTORE FROM '$BACKUP_DIR/gql.bak' TO TIMESTAMP '2024-01-01T00:00:00Z'")"

echo -e "\n${YELLOW}Summary${NC}: passed=$PASS failed=$FAIL"
if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}Backup/Restore regression tests passed.${NC}"
    exit 0
else
    echo -e "${RED}Backup/Restore regression tests failed.${NC}"
    exit 1
fi
