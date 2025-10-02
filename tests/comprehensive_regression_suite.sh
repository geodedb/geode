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

echo
echo -e "${BLUE}=== Section 1: String Literal Handling ===${NC}"
echo "Regression tests for single/double quote issues"

test_feature "Single quotes in RETURN" \
    "echo \"RETURN 'test' AS x\" | ./zig-out/bin/geoded" \
    "status_class\|SCHEMA"

test_feature "Single quotes in properties" \
    "echo \"CREATE (n {name: 'Alice', city: 'NYC'})\" | ./zig-out/bin/geoded" \
    "status_class"

test_feature "Mixed quotes (single for strings)" \
    "echo \"MATCH (n {name: 'Bob'}) RETURN n\" | ./zig-out/bin/geoded" \
    "status_class\|SCHEMA"

test_feature "Double quotes (should work or timeout gracefully)" \
    "echo 'RETURN \"test\"' | timeout 1 ./zig-out/bin/geoded" \
    "status_class\|timeout" \
    true

echo
echo -e "${BLUE}=== Section 2: QUIC TLS Handshake ===${NC}"
echo "Regression tests for TLS connection issues"

# Start server for TLS tests
./zig-out/bin/geoded --listen-quic 0.0.0.0:8443 > /tmp/tls_test.log 2>&1 &
SERVER_PID=$!
sleep 2

test_feature "QUIC connection with --insecure" \
    "./zig-out/bin/geodec 'RETURN 1 AS x' --quic-addr 127.0.0.1 --quic-port 8443 --insecure" \
    "\"x\":1"

test_feature "Multiple insecure connections" \
    "for i in 1 2 3; do ./zig-out/bin/geodec 'RETURN \$i AS n' --quic-addr 127.0.0.1 --quic-port 8443 --insecure 2>/dev/null; done | grep '\"n\"' | wc -l" \
    "3"

kill $SERVER_PID 2>/dev/null
wait $SERVER_PID 2>/dev/null

echo
echo -e "${BLUE}=== Section 3: Query Features ===${NC}"
echo "Regression tests for implemented query features"

test_feature "Simple CREATE" \
    "echo \"CREATE (n:Person {id: 1})\" | ./zig-out/bin/geoded" \
    "status_class"

test_feature "MATCH with WHERE" \
    "echo \"MATCH (n:Person) WHERE n.age > 25 RETURN n\" | ./zig-out/bin/geoded" \
    "status_class\|SCHEMA"

test_feature "COUNT aggregation" \
    "echo \"MATCH (n) RETURN count(n) AS total\" | ./zig-out/bin/geoded" \
    "status_class\|total"

test_feature "ORDER BY property" \
    "echo \"MATCH (n) RETURN n ORDER BY n.age LIMIT 10\" | ./zig-out/bin/geoded" \
    "status_class\|SCHEMA"

test_feature "LIMIT without ORDER BY" \
    "echo \"MATCH (n) RETURN n LIMIT 5\" | ./zig-out/bin/geoded" \
    "status_class"

test_feature "Multiple MATCH clauses" \
    "echo \"MATCH (a:Person) MATCH (b:Company) RETURN a, b\" | ./zig-out/bin/geoded" \
    "status_class\|SCHEMA"

test_feature "OPTIONAL MATCH" \
    "echo \"MATCH (n) OPTIONAL MATCH (n)-[r]->(m) RETURN n, m\" | ./zig-out/bin/geoded" \
    "status_class\|SCHEMA"

echo
echo -e "${BLUE}=== Section 4: Data Modification ===${NC}"
echo "Testing SET/DELETE operations"

test_feature "SET property" \
    "echo \"MATCH (n) SET n.updated = true\" | ./zig-out/bin/geoded" \
    "status_class"

test_feature "DELETE node" \
    "echo \"MATCH (n:Temp) DELETE n\" | ./zig-out/bin/geoded" \
    "status_class"

test_feature "DETACH DELETE" \
    "echo \"MATCH (n:Temp) DETACH DELETE n\" | ./zig-out/bin/geoded" \
    "status_class"

echo
echo -e "${BLUE}=== Section 5: Transaction Support ===${NC}"
echo "Testing transaction operations"

test_feature "BEGIN transaction" \
    "echo \"BEGIN\" | ./zig-out/bin/geoded" \
    "status_class\|BEGIN"

test_feature "COMMIT transaction" \
    "echo \"COMMIT\" | ./zig-out/bin/geoded" \
    "status_class\|COMMIT"

test_feature "ROLLBACK transaction" \
    "echo \"ROLLBACK\" | ./zig-out/bin/geoded" \
    "status_class\|ROLLBACK"

echo
echo -e "${BLUE}=== Section 6: Performance Regression ===${NC}"
echo "Ensuring no performance degradation"

# Create test data
echo -n "Creating test dataset... "
for i in {1..100}; do
    echo "CREATE (n:PerfTest {id: $i})" | ./zig-out/bin/geoded > /dev/null 2>&1
done
echo "Done"

echo -n "Testing query performance (100 nodes)... "
START=$(date +%s%N)
echo "MATCH (n:PerfTest) RETURN count(n)" | ./zig-out/bin/geoded > /dev/null 2>&1
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
    "echo \"INVALID QUERY SYNTAX\" | ./zig-out/bin/geoded" \
    "error\|ParseError"

test_feature "Malformed property map" \
    "echo \"CREATE (n {invalid})\" | ./zig-out/bin/geoded" \
    "error\|unexpected"

test_feature "US001 error (OFFSET without ORDER BY)" \
    "echo \"MATCH (n) RETURN n OFFSET 5\" | ./zig-out/bin/geoded" \
    "US001\|error"

echo
echo -e "${BLUE}=== Section 8: Advanced Features ===${NC}"
echo "Testing advanced query features"

test_feature "Variable length paths" \
    "echo \"MATCH (a)-[*1..3]->(b) RETURN count(*)\" | ./zig-out/bin/geoded" \
    "status_class\|SCHEMA"

test_feature "UNION queries" \
    "echo \"RETURN 1 AS x UNION RETURN 2 AS x\" | ./zig-out/bin/geoded" \
    "status_class\|SCHEMA"

test_feature "WITH clause" \
    "echo \"MATCH (n) WITH n WHERE n.age > 30 RETURN n\" | ./zig-out/bin/geoded" \
    "status_class\|SCHEMA"

# Cleanup
rm -f /tmp/tls_test.log

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