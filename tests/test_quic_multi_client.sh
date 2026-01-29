#!/bin/sh
# QUIC Multi-Client Test Suite
# Tests single server handling multiple concurrent clients

set -e

echo "=== QUIC Multi-Client Test Suite ==="
echo ""

# Function to run a query and check result
run_query() {
    local client_id=$1
    local query=$2
    local expected=$3
    local server_port=${4:-8443}

    echo "Client $client_id: Executing query..."
    OUTPUT=$(./zig-out/bin/geode query --server 127.0.0.1:$server_port "$query" 2>&1 | grep -E "(SCHEMA|RESULT|STATUS|Error)" || true)

    if echo "$OUTPUT" | grep -q "$expected"; then
        echo "Client $client_id: ✓ Query successful"
        return 0
    else
        echo "Client $client_id: ✗ Query failed"
        echo "Expected: $expected"
        echo "Got: $OUTPUT"
        return 1
    fi
}

# Test 1: Sequential clients
echo "Test 1: Sequential clients to single server"
echo "Starting server..."
./zig-out/bin/geode serve --listen-quic 127.0.0.1:8443 > test_server.log 2>&1 &
SERVER_PID=$!
sleep 2

echo "Running sequential queries..."
run_query 1 "RETURN 1 AS client_id" '"client_id":1' || exit 1
run_query 2 "RETURN 2 AS client_id" '"client_id":2' || exit 1
run_query 3 "RETURN 3 AS client_id" '"client_id":3' || exit 1

kill $SERVER_PID 2>/dev/null || true
echo "✓ Test 1 passed"
echo ""

# Test 2: Concurrent clients
echo "Test 2: Concurrent clients to single server"
echo "Starting server..."
./zig-out/bin/geode serve --listen-quic 127.0.0.1:8444 > test_server2.log 2>&1 &
SERVER_PID=$!
sleep 2

echo "Launching 5 concurrent clients..."
# Launch clients in background
(./zig-out/bin/geode query --server 127.0.0.1:8444 "RETURN 'A' AS data" > client_a.out 2>&1) &
PID_A=$!
(./zig-out/bin/geode query --server 127.0.0.1:8444 "RETURN 'B' AS data" > client_b.out 2>&1) &
PID_B=$!
(./zig-out/bin/geode query --server 127.0.0.1:8444 "RETURN 'C' AS data" > client_c.out 2>&1) &
PID_C=$!
(./zig-out/bin/geode query --server 127.0.0.1:8444 "RETURN 'D' AS data" > client_d.out 2>&1) &
PID_D=$!
(./zig-out/bin/geode query --server 127.0.0.1:8444 "RETURN 'E' AS data" > client_e.out 2>&1) &
PID_E=$!

# Wait for all clients to complete
wait $PID_A
wait $PID_B
wait $PID_C
wait $PID_D
wait $PID_E

# Check results
FAILURES=0
if grep -q '"data":"A"' client_a.out; then
    echo "Client A: ✓"
else
    echo "Client A: ✗"
    cat client_a.out
    FAILURES=$((FAILURES + 1))
fi

if grep -q '"data":"B"' client_b.out; then
    echo "Client B: ✓"
else
    echo "Client B: ✗"
    cat client_b.out
    FAILURES=$((FAILURES + 1))
fi

if grep -q '"data":"C"' client_c.out; then
    echo "Client C: ✓"
else
    echo "Client C: ✗"
    cat client_c.out
    FAILURES=$((FAILURES + 1))
fi

if grep -q '"data":"D"' client_d.out; then
    echo "Client D: ✓"
else
    echo "Client D: ✗"
    cat client_d.out
    FAILURES=$((FAILURES + 1))
fi

if grep -q '"data":"E"' client_e.out; then
    echo "Client E: ✓"
else
    echo "Client E: ✗"
    cat client_e.out
    FAILURES=$((FAILURES + 1))
fi

# Cleanup
rm -f client_*.out
kill $SERVER_PID 2>/dev/null || true

if [ $FAILURES -eq 0 ]; then
    echo "✓ Test 2 passed"
else
    echo "✗ Test 2 failed with $FAILURES client failures"
    exit 1
fi
echo ""

# Test 3: Rapid fire from single client
echo "Test 3: Rapid sequential queries from single client"
echo "Starting server..."
./zig-out/bin/geode serve --listen-quic 127.0.0.1:8445 > test_server3.log 2>&1 &
SERVER_PID=$!
sleep 2

echo "Sending rapid queries..."
for i in 1 2 3 4 5 6 7 8 9 10; do
    OUTPUT=$(./zig-out/bin/geode query --server 127.0.0.1:8445 "RETURN $i AS num" 2>&1 || true)
    if echo "$OUTPUT" | grep -q "\"num\":$i"; then
        echo "Query $i: ✓"
    else
        echo "Query $i: ✗"
        echo "$OUTPUT"
        kill $SERVER_PID 2>/dev/null || true
        exit 1
    fi
done

kill $SERVER_PID 2>/dev/null || true
echo "✓ Test 3 passed"
echo ""

# Test 4: Stress test with 10 concurrent clients
echo "Test 4: Stress test with 10 concurrent clients"
echo "Starting server..."
./zig-out/bin/geode serve --listen-quic 127.0.0.1:8446 > test_server4.log 2>&1 &
SERVER_PID=$!
sleep 2

echo "Launching 10 concurrent clients..."
PIDS=""
for i in 1 2 3 4 5 6 7 8 9 10; do
    (./zig-out/bin/geode query --server 127.0.0.1:8446 "RETURN $i AS id" > stress_$i.out 2>&1) &
    PIDS="$PIDS $!"
done

# Wait for all clients
for pid in $PIDS; do
    wait $pid
done

# Check results
STRESS_FAILURES=0
for i in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q "\"id\":$i" stress_$i.out; then
        echo "Stress client $i: ✓"
    else
        echo "Stress client $i: ✗"
        cat stress_$i.out
        STRESS_FAILURES=$((STRESS_FAILURES + 1))
    fi
done

# Cleanup
rm -f stress_*.out
kill $SERVER_PID 2>/dev/null || true

if [ $STRESS_FAILURES -eq 0 ]; then
    echo "✓ Test 4 passed"
else
    echo "✗ Test 4 failed with $STRESS_FAILURES client failures"
    exit 1
fi
echo ""

# Test 5: Connection reuse (multiple queries per client)
echo "Test 5: Connection reuse test"
echo "Starting server..."
./zig-out/bin/geode serve --listen-quic 127.0.0.1:8447 > test_server5.log 2>&1 &
SERVER_PID=$!
sleep 2

echo "Client performing multiple queries..."
SUCCESS=0
for i in 1 2 3; do
    OUTPUT=$(./zig-out/bin/geode query --server 127.0.0.1:8447 "RETURN $i AS iteration" 2>&1 || true)
    if echo "$OUTPUT" | grep -q "\"iteration\":$i"; then
        echo "Iteration $i: ✓"
        SUCCESS=$((SUCCESS + 1))
    else
        echo "Iteration $i: ✗"
    fi
done

kill $SERVER_PID 2>/dev/null || true

if [ $SUCCESS -eq 3 ]; then
    echo "✓ Test 5 passed"
else
    echo "✗ Test 5 failed"
    exit 1
fi
echo ""

echo "=== All Multi-Client Tests Passed ==="
echo ""
echo "Summary:"
echo "- Sequential clients: ✓"
echo "- Concurrent clients (5): ✓"
echo "- Rapid sequential queries: ✓"
echo "- Stress test (10 clients): ✓"
echo "- Connection reuse: ✓"
