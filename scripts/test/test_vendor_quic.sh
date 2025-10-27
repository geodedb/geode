#!/bin/sh

echo "Testing vendor QUIC communication"
echo "===================================="

# Clean state
pkill -KILL quic-server 2>/dev/null || true
pkill -KILL quic-client 2>/dev/null || true
sleep 1

# Start server
echo "Starting vendor QUIC server on 127.0.0.1:4433..."
./vendor/quic/zig-out/bin/quic-server --bind 127.0.0.1:4433 --insecure > /tmp/quic_server.log 2>&1 &
SERVER_PID=$!
sleep 3

# Check if server is running
if ! ps -p $SERVER_PID > /dev/null; then
    echo "ERROR: Server failed to start"
    cat /tmp/quic_server.log
    exit 1
fi

echo "Server PID: $SERVER_PID"

# Test 1: netcat
echo ""
echo "Test 1: Sending UDP packet via netcat..."
echo "test packet" | nc -u -w 1 127.0.0.1 4433
sleep 1

if grep -q "recvfrom got" /tmp/quic_server.log; then
    echo "✅ Netcat packet RECEIVED"
else
    echo "❌ Netcat packet NOT received"
fi

# Test 2: QUIC client
echo ""
echo "Test 2: Sending QUIC Initial packet..."
timeout 5 ./vendor/quic/zig-out/bin/quic-client --connect 127.0.0.1:4433 --insecure > /tmp/quic_client.log 2>&1 || true
sleep 1

if grep -q "recvfrom got.*byte" /tmp/quic_server.log; then
    echo "✅ QUIC packet RECEIVED"
else
    echo "❌ QUIC packet NOT received"
fi

# Cleanup
kill -KILL $SERVER_PID 2>/dev/null || true

echo ""
echo "Server log (last 20 lines with recvfrom):"
grep "recvfrom" /tmp/quic_server.log | tail -20 || echo "No recvfrom messages"

echo ""
echo "Client log (first 30 lines):"
head -30 /tmp/quic_client.log

echo ""
echo "Test complete"
