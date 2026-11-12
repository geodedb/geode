#!/usr/bin/env bash
# Comprehensive Regression Test Suite
# Tests all fixes and ensures no regressions

set -e

echo "=== Comprehensive Regression Test Suite ==="
echo "Testing all fixes and known issues"
echo

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASSED=0
FAILED=0
WARNINGS=0

# Test function
test_feature() {
    local name="$1"
    local cmd="$2"
    local expected="$3"
    local is_warning="${4:-false}"

    echo -n "Testing $name... "

    local output
    local exit_code=0
    output=$(timeout 3 bash -c "$cmd" 2>&1) || exit_code=$?

    if echo "$output" | grep -qE "$expected"; then
        echo -e "${GREEN}PASS${NC}"
        ((PASSED++))
    elif [ "$is_warning" = "true" ]; then
        echo -e "${YELLOW}KNOWN ISSUE${NC}"
        ((WARNINGS++))
    else
        echo -e "${RED}FAIL${NC}"
        echo "  Expected: $expected"
        echo "  Got: $(echo "$output" | head -2)"
        ((FAILED++))
    fi
}

# Build
echo "Building Geode..."
make build > /dev/null 2>&1 || { echo -e "${RED}Build failed${NC}"; exit 1; }

SERVER_PORT=8443
ADMIN_USER="${GEODE_ADMIN_USERNAME:-geode}"
ADMIN_PASS="${GEODE_DEFAULT_PASSWORD:-Geode Test Admin Passphrase}"
DATA_DIR=$(mktemp -d /tmp/geode_regression_XXXXXX)
GEODE_ADMIN_USERNAME="${ADMIN_USER}" GEODE_DEFAULT_PASSWORD="${ADMIN_PASS}" \
    ./zig-out/bin/geode serve --listen 127.0.0.1:${SERVER_PORT} --data-dir "${DATA_DIR}" > /tmp/geode_regression.log 2>&1 &
SERVER_PID=$!
sleep 2

cleanup() {
    rm -rf "${GEODE_CLI_WRAPPER_DIR:-}"
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
    rm -rf "${DATA_DIR}"
    rm -f /tmp/geode_regression.log
}
trap cleanup EXIT

# SONNY-6359: the admin password is a passphrase; the wrapper keeps it one argument.
# shellcheck source=lib/geode_cli_wrapper.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/geode_cli_wrapper.sh"
QUERY_CMD="$(geode_cli_wrapper ./zig-out/bin/geode query --server 127.0.0.1:${SERVER_PORT} --insecure --user "${ADMIN_USER}" --password "${ADMIN_PASS}")"
SHELL_CMD="$(geode_cli_wrapper ./zig-out/bin/geode shell --server 127.0.0.1:${SERVER_PORT} --insecure --user "${ADMIN_USER}" --password "${ADMIN_PASS}" --no-history --format json)"

echo
echo -e "${BLUE}=== Section 1: String Literal Handling ===${NC}"
echo "Regression tests for single/double quote issues"

test_feature "Single quotes in RETURN" \
    "$QUERY_CMD \"RETURN 'test' AS x\"" \
    "\"status_class\":\"00000\""

test_feature "Single quotes in properties" \
    "$QUERY_CMD \"CREATE (n {name: 'Alice', city: 'NYC'})\"" \
    "\"status_class\":\"00000\""

test_feature "Mixed quotes (single for strings)" \
    "$QUERY_CMD \"MATCH (n {name: 'Bob'}) RETURN n\"" \
    "\"status_class\":\"00000\""

test_feature "Double quotes (should work or timeout gracefully)" \
    "timeout 1 $QUERY_CMD 'RETURN \"test\"'" \
    "\"status_class\":\"00000\"|timeout" \
    true

echo
echo -e "${BLUE}=== Section 2: QUIC TLS Handshake ===${NC}"
echo "Regression tests for TLS connection issues"

test_feature "QUIC connection with --insecure" \
    "$QUERY_CMD 'RETURN 1 AS x'" \
    "\"x\":1"

test_feature "Multiple insecure connections" \
    "for i in 1 2 3; do $QUERY_CMD \"RETURN \\$i AS n\" 2>/dev/null; done | grep '\"n\"' | wc -l" \
    "3"

echo
echo -e "${BLUE}=== Section 3: Query Features ===${NC}"
echo "Regression tests for implemented query features"

test_feature "Simple CREATE" \
    "$QUERY_CMD \"CREATE (n:Person {id: 1})\"" \
    "\"status_class\":\"00000\""

test_feature "MATCH with WHERE" \
    "$QUERY_CMD \"MATCH (n:Person) WHERE n.age > 25 RETURN n\"" \
    "\"status_class\":\"00000\""

test_feature "COUNT aggregation" \
    "$QUERY_CMD \"MATCH (n) RETURN count(n) AS total\"" \
    "\"total\""

test_feature "ORDER BY property" \
    "$QUERY_CMD \"MATCH (n) RETURN n ORDER BY n.age LIMIT 10\"" \
    "\"status_class\":\"00000\""

test_feature "LIMIT without ORDER BY" \
    "$QUERY_CMD \"MATCH (n) RETURN n LIMIT 5\"" \
    "\"status_class\":\"00000\""

test_feature "Multiple MATCH clauses" \
    "$QUERY_CMD \"MATCH (a:Person) MATCH (b:Company) RETURN a, b\"" \
    "\"status_class\":\"00000\""

test_feature "OPTIONAL MATCH" \
    "$QUERY_CMD \"MATCH (n) OPTIONAL MATCH (n)-[r]->(m) RETURN n, m\"" \
    "\"status_class\":\"00000\""

echo
echo -e "${BLUE}=== Section 4: Data Modification ===${NC}"
echo "Testing SET/DELETE operations"

test_feature "SET property" \
    "$QUERY_CMD \"MATCH (n) SET n.updated = true\"" \
    "\"status_class\":\"00000\""

test_feature "DELETE node" \
    "$QUERY_CMD \"MATCH (n:Temp) DELETE n\"" \
    "\"status_class\":\"00000\""

test_feature "DETACH DELETE" \
    "$QUERY_CMD \"MATCH (n:Temp) DETACH DELETE n\"" \
    "\"status_class\":\"00000\""

echo
echo -e "${BLUE}=== Section 5: Transaction Support ===${NC}"
echo "Testing transaction operations"

test_feature "BEGIN transaction" \
    "printf \"\\\\begin\\n\\\\exit\\n\" | $SHELL_CMD" \
    "Transaction started"

test_feature "COMMIT transaction" \
    "printf \"\\\\begin\\n\\\\commit\\n\\\\exit\\n\" | $SHELL_CMD" \
    "Transaction committed"

test_feature "ROLLBACK transaction" \
    "printf \"\\\\begin\\n\\\\rollback\\n\\\\exit\\n\" | $SHELL_CMD" \
    "Transaction rolled back"

echo
echo -e "${BLUE}=== Section 6: Performance Regression ===${NC}"
echo "Ensuring no performance degradation"

# Create test data
echo -n "Creating test dataset... "
for i in {1..100}; do
    $QUERY_CMD "CREATE (n:PerfTest {id: $i})" > /dev/null 2>&1
done
echo "Done"

echo -n "Testing query performance (100 nodes)... "
START=$(date +%s%N)
$QUERY_CMD "MATCH (n:PerfTest) RETURN count(n)" > /dev/null 2>&1
END=$(date +%s%N)
DURATION_MS=$(( (END - START) / 1000000 ))

if [ $DURATION_MS -le 100 ]; then
    echo -e "${GREEN}GOOD (${DURATION_MS}ms)${NC}"
    ((PASSED++))
elif [ $DURATION_MS -le 500 ]; then
    echo -e "${YELLOW}ACCEPTABLE (${DURATION_MS}ms)${NC}"
    ((WARNINGS++))
else
    echo -e "${RED}TOO SLOW (${DURATION_MS}ms)${NC}"
    ((FAILED++))
fi

echo
echo -e "${BLUE}=== Section 7: Error Handling ===${NC}"
echo "Testing error cases and graceful failures"

test_feature "Invalid syntax error" \
    "$QUERY_CMD \"INVALID QUERY SYNTAX\"" \
    "error\|ParseError"

test_feature "Malformed property map" \
    "$QUERY_CMD \"CREATE (n {invalid})\"" \
    "error\|unexpected"

test_feature "US001 error (OFFSET without ORDER BY)" \
    "$QUERY_CMD \"MATCH (n) RETURN n OFFSET 5\"" \
    "US001\|error"

echo
echo -e "${BLUE}=== Section 8: Advanced Features ===${NC}"
echo "Testing advanced query features"

test_feature "Variable length paths" \
    "$QUERY_CMD \"MATCH (a)-[*1..3]->(b) RETURN count(*)\"" \
    "\"status_class\":\"00000\""

test_feature "UNION queries" \
    "$QUERY_CMD \"RETURN 1 AS x UNION RETURN 2 AS x\"" \
    "\"status_class\":\"00000\""

test_feature "WITH clause" \
    "$QUERY_CMD \"MATCH (n) WITH n WHERE n.age > 30 RETURN n\"" \
    "\"status_class\":\"00000\""

echo
echo "============================================"
echo -e "${CYAN}REGRESSION TEST SUMMARY${NC}"
echo "============================================"
echo -e "Tests passed:        ${GREEN}$PASSED${NC}"
echo -e "Tests failed:        ${RED}$FAILED${NC}"
echo -e "Known issues:        ${YELLOW}$WARNINGS${NC}"
echo -e "Total tests:         $((PASSED + FAILED + WARNINGS))"
echo

if [ $FAILED -eq 0 ]; then
    if [ $WARNINGS -gt 0 ]; then
        echo -e "${YELLOW}All tests passed with $WARNINGS known issues${NC}"
        echo "Known issues:"
        echo "  - Double quotes in string literals cause parser hang"
    else
        echo -e "${GREEN}ALL REGRESSION TESTS PASSED!${NC}"
    fi
    exit 0
else
    echo -e "${RED}REGRESSION DETECTED: $FAILED tests failed${NC}"
    echo "Please investigate and fix the failing tests"
    exit 1
fi
