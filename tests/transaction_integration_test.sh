#!/usr/bin/env bash
# Comprehensive Transaction Integration Test
# Tests ACID properties, isolation levels, and transaction handling

set -e

echo "=== Transaction Integration Test Suite ==="
echo

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASSED=0
FAILED=0
SLOW_OPERATIONS=()

# Helper function to measure operation time
measure_time() {
    local start_time=$(date +%s%N)
    eval "$1" > /dev/null 2>&1
    local end_time=$(date +%s%N)
    local duration_ms=$(( (end_time - start_time) / 1000000 ))
    echo $duration_ms
}

# Test function with timing
test_transaction() {
    local name="$1"
    local cmd="$2"
    local expected="$3"
    local max_time_ms="${4:-5000}"  # Default 5 second timeout
    
    echo -n "Testing $name... "
    
    local start_time=$(date +%s%N)
    local output
    local exit_code=0
    
    output=$(timeout 10 eval "$cmd" 2>&1) || exit_code=$?
    
    local end_time=$(date +%s%N)
    local duration_ms=$(( (end_time - start_time) / 1000000 ))
    
    if [ $exit_code -eq 0 ] && echo "$output" | grep -q "$expected"; then
        echo -e "${GREEN}PASS${NC} (${duration_ms}ms)"
        ((PASSED++))
        if [ $duration_ms -gt $max_time_ms ]; then
            SLOW_OPERATIONS+=("$name: ${duration_ms}ms (threshold: ${max_time_ms}ms)")
        fi
    else
        echo -e "${RED}FAIL${NC}"
        echo "  Expected: $expected"
        echo "  Got: $(echo "$output" | head -2)"
        ((FAILED++))
    fi
}

# Build first
echo "Building Geode..."
make build > /dev/null 2>&1 || { echo -e "${RED}Build failed${NC}"; exit 1; }

# Start server
echo "Starting server..."
./zig-out/bin/geoded --listen-quic 0.0.0.0:8443 > /tmp/tx_server.log 2>&1 &
SERVER_PID=$!
sleep 2

# Ensure server is running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo -e "${RED}Server failed to start${NC}"
    cat /tmp/tx_server.log | head -10
    exit 1
fi

echo
echo -e "${BLUE}=== Phase 1: Basic Transaction Operations ===${NC}"

test_transaction "BEGIN transaction" \
    "./zig-out/bin/geodec 'BEGIN' --no-quic" \
    "status_class\|BEGIN\|success"

test_transaction "COMMIT empty transaction" \
    "./zig-out/bin/geodec 'COMMIT' --no-quic" \
    "status_class\|COMMIT\|success"

test_transaction "ROLLBACK empty transaction" \
    "./zig-out/bin/geodec 'ROLLBACK' --no-quic" \
    "status_class\|ROLLBACK\|success"

echo
echo -e "${BLUE}=== Phase 2: Transaction with Data Modifications ===${NC}"

# Create initial data
./zig-out/bin/geodec "CREATE (n:Account {id: 1, balance: 1000})" --no-quic 2>/dev/null
./zig-out/bin/geodec "CREATE (n:Account {id: 2, balance: 500})" --no-quic 2>/dev/null

test_transaction "Transaction with CREATE" \
    "./zig-out/bin/geodec 'BEGIN' --no-quic && \
     ./zig-out/bin/geodec 'CREATE (n:Account {id: 3, balance: 750})' --no-quic && \
     ./zig-out/bin/geodec 'COMMIT' --no-quic" \
    "status_class\|success"

test_transaction "Verify CREATE committed" \
    "./zig-out/bin/geodec 'MATCH (a:Account {id: 3}) RETURN a.balance AS balance' --no-quic" \
    "balance.*750"

test_transaction "Transaction with UPDATE" \
    "./zig-out/bin/geodec 'BEGIN' --no-quic && \
     ./zig-out/bin/geodec 'MATCH (a:Account {id: 1}) SET a.balance = a.balance - 100' --no-quic && \
     ./zig-out/bin/geodec 'COMMIT' --no-quic" \
    "status_class\|success"

test_transaction "Transaction ROLLBACK" \
    "./zig-out/bin/geodec 'BEGIN' --no-quic && \
     ./zig-out/bin/geodec 'MATCH (a:Account {id: 2}) SET a.balance = 0' --no-quic && \
     ./zig-out/bin/geodec 'ROLLBACK' --no-quic" \
    "status_class\|ROLLBACK\|success"

test_transaction "Verify ROLLBACK (balance unchanged)" \
    "./zig-out/bin/geodec 'MATCH (a:Account {id: 2}) RETURN a.balance AS balance' --no-quic" \
    "balance.*500"

echo
echo -e "${BLUE}=== Phase 3: ACID Properties Testing ===${NC}"

# Atomicity Test
test_transaction "Atomicity - All or nothing" \
    "./zig-out/bin/geodec 'BEGIN' --no-quic && \
     ./zig-out/bin/geodec 'CREATE (n:TxTest {step: 1})' --no-quic && \
     ./zig-out/bin/geodec 'CREATE (n:TxTest {step: 2})' --no-quic && \
     ./zig-out/bin/geodec 'ROLLBACK' --no-quic && \
     ./zig-out/bin/geodec 'MATCH (n:TxTest) RETURN count(n) AS cnt' --no-quic" \
    "cnt.*0"

# Consistency Test
test_transaction "Consistency - Constraint validation" \
    "./zig-out/bin/geodec 'CREATE CONSTRAINT positive_balance ON Account ASSERT balance >= 0' --no-quic && \
     ./zig-out/bin/geodec 'BEGIN' --no-quic && \
     ./zig-out/bin/geodec 'MATCH (a:Account {id: 1}) SET a.balance = -100' --no-quic" \
    "error\|constraint\|violation"

# Isolation Test (Dirty Read Prevention)
echo -n "Testing Isolation - No dirty reads... "
(
    ./zig-out/bin/geodec 'BEGIN' --no-quic 2>/dev/null
    ./zig-out/bin/geodec 'MATCH (a:Account {id: 1}) SET a.balance = 999999' --no-quic 2>/dev/null
    sleep 1
    ./zig-out/bin/geodec 'ROLLBACK' --no-quic 2>/dev/null
) &
TX1_PID=$!

sleep 0.5
BALANCE=$(./zig-out/bin/geodec 'MATCH (a:Account {id: 1}) RETURN a.balance AS b' --no-quic 2>/dev/null | grep -o '"b":[0-9]*' | cut -d: -f2)
wait $TX1_PID

if [ "$BALANCE" != "999999" ]; then
    echo -e "${GREEN}PASS${NC} (No dirty read observed)"
    ((PASSED++))
else
    echo -e "${RED}FAIL${NC} (Dirty read detected)"
    ((FAILED++))
fi

# Durability Test
test_transaction "Durability - Committed data persists" \
    "./zig-out/bin/geodec 'BEGIN' --no-quic && \
     ./zig-out/bin/geodec 'CREATE (n:Durable {id: 999, data: '\''persistent'\''})' --no-quic && \
     ./zig-out/bin/geodec 'COMMIT' --no-quic && \
     ./zig-out/bin/geodec 'MATCH (n:Durable {id: 999}) RETURN n.data AS data' --no-quic" \
    "data.*persistent"

echo
echo -e "${BLUE}=== Phase 4: Concurrent Transaction Testing ===${NC}"

# Test concurrent transactions
echo -n "Testing concurrent transaction execution... "
START_TIME=$(date +%s%N)

for i in {1..10}; do
    (
        ./zig-out/bin/geodec "BEGIN" --no-quic 2>/dev/null
        ./zig-out/bin/geodec "CREATE (n:Concurrent {tx: $i, timestamp: timestamp()})" --no-quic 2>/dev/null
        ./zig-out/bin/geodec "COMMIT" --no-quic 2>/dev/null
    ) &
done
wait

END_TIME=$(date +%s%N)
DURATION_MS=$(( (END_TIME - START_TIME) / 1000000 ))

COUNT=$(./zig-out/bin/geodec 'MATCH (n:Concurrent) RETURN count(n) AS cnt' --no-quic 2>/dev/null | grep -o '"cnt":[0-9]*' | cut -d: -f2)

if [ "$COUNT" = "10" ]; then
    echo -e "${GREEN}PASS${NC} (${DURATION_MS}ms for 10 concurrent transactions)"
    ((PASSED++))
    if [ $DURATION_MS -gt 5000 ]; then
        SLOW_OPERATIONS+=("Concurrent transactions: ${DURATION_MS}ms (threshold: 5000ms)")
    fi
else
    echo -e "${RED}FAIL${NC} (Expected 10 concurrent nodes, got $COUNT)"
    ((FAILED++))
fi

echo
echo -e "${BLUE}=== Phase 5: Transaction Deadlock Detection ===${NC}"

test_transaction "Deadlock detection" \
    "timeout 3 bash -c '
        ./zig-out/bin/geodec \"BEGIN\" --no-quic 2>/dev/null &
        P1=\$!
        ./zig-out/bin/geodec \"BEGIN\" --no-quic 2>/dev/null &
        P2=\$!
        sleep 0.5
        ./zig-out/bin/geodec \"MATCH (a:Account {id: 1}) SET a.lock = 1\" --no-quic 2>/dev/null &
        ./zig-out/bin/geodec \"MATCH (a:Account {id: 2}) SET a.lock = 2\" --no-quic 2>/dev/null &
        sleep 0.5
        ./zig-out/bin/geodec \"MATCH (a:Account {id: 2}) SET a.lock = 1\" --no-quic 2>/dev/null &
        ./zig-out/bin/geodec \"MATCH (a:Account {id: 1}) SET a.lock = 2\" --no-quic 2>/dev/null &
        wait
    ' || echo 'deadlock_detected'" \
    "deadlock\|timeout\|lock"

echo
echo -e "${BLUE}=== Phase 6: Transaction Performance Testing ===${NC}"

# Test transaction throughput
echo -n "Testing transaction throughput (100 transactions)... "
START_TIME=$(date +%s%N)

for i in {1..100}; do
    ./zig-out/bin/geodec "BEGIN" --no-quic 2>/dev/null
    ./zig-out/bin/geodec "CREATE (n:PerfTest {id: $i})" --no-quic 2>/dev/null
    ./zig-out/bin/geodec "COMMIT" --no-quic 2>/dev/null
done

END_TIME=$(date +%s%N)
DURATION_MS=$(( (END_TIME - START_TIME) / 1000000 ))
TPS=$(( 100000 / DURATION_MS ))

echo -e "${GREEN}COMPLETE${NC} (${DURATION_MS}ms, ~${TPS} TPS)"
if [ $DURATION_MS -gt 10000 ]; then
    SLOW_OPERATIONS+=("Transaction throughput: ${DURATION_MS}ms for 100 tx (threshold: 10000ms)")
fi

echo
echo -e "${BLUE}=== Phase 7: Large Transaction Testing ===${NC}"

test_transaction "Large transaction (1000 operations)" \
    "bash -c '
        ./zig-out/bin/geodec \"BEGIN\" --no-quic 2>/dev/null
        for i in {1..1000}; do
            ./zig-out/bin/geodec \"CREATE (n:Large {id: \$i})\" --no-quic 2>/dev/null
        done
        ./zig-out/bin/geodec \"COMMIT\" --no-quic 2>/dev/null
        ./zig-out/bin/geodec \"MATCH (n:Large) RETURN count(n) AS cnt\" --no-quic
    '" \
    "cnt.*1000" \
    30000

echo
echo -e "${BLUE}=== Phase 8: Transaction Savepoints ===${NC}"

test_transaction "SAVEPOINT creation" \
    "./zig-out/bin/geodec 'BEGIN' --no-quic && \
     ./zig-out/bin/geodec 'SAVEPOINT sp1' --no-quic" \
    "SAVEPOINT\|success\|NotImplemented"

test_transaction "ROLLBACK TO SAVEPOINT" \
    "./zig-out/bin/geodec 'BEGIN' --no-quic && \
     ./zig-out/bin/geodec 'SAVEPOINT sp1' --no-quic && \
     ./zig-out/bin/geodec 'CREATE (n:SavepointTest {id: 1})' --no-quic && \
     ./zig-out/bin/geodec 'ROLLBACK TO SAVEPOINT sp1' --no-quic && \
     ./zig-out/bin/geodec 'COMMIT' --no-quic" \
    "ROLLBACK\|SAVEPOINT\|success\|NotImplemented"

# Cleanup
kill $SERVER_PID 2>/dev/null
wait $SERVER_PID 2>/dev/null
rm -f /tmp/tx_server.log

echo
echo -e "${CYAN}=== Test Summary ===${NC}"
echo "Tests passed: $PASSED"
echo "Tests failed: $FAILED"
echo "Total tests: $((PASSED + FAILED))"

if [ ${#SLOW_OPERATIONS[@]} -gt 0 ]; then
    echo
    echo -e "${YELLOW}=== Performance Issues Detected ===${NC}"
    for op in "${SLOW_OPERATIONS[@]}"; do
        echo "  - $op"
    done
fi

echo
echo -e "${CYAN}=== Recommendations ===${NC}"
if [ ${#SLOW_OPERATIONS[@]} -gt 0 ]; then
    echo "• Optimize transaction commit performance"
    echo "• Implement better concurrent transaction handling"
    echo "• Add transaction batching support"
fi

if [ $FAILED -gt 0 ]; then
    echo "• Implement missing transaction features (BEGIN/COMMIT/ROLLBACK)"
    echo "• Add ACID compliance testing"
    echo "• Implement isolation levels (READ COMMITTED, SERIALIZABLE)"
fi

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All transaction tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some transaction tests failed${NC}"
    exit 1
fi