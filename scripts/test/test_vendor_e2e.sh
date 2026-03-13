#!/bin/sh
set -eu

echo "=== Vendor QUIC End-to-End Test ==="
pkill -KILL quic-server 2>/dev/null || true
pkill -KILL quic-client 2>/dev/null || true
sleep 1

# Start server
echo "Starting vendor server..."
./vendor/quic/zig-out/bin/quic-server --bind 127.0.0.1:4433 --insecure > /tmp/e2e_server.log 2>&1 &
SERVER_PID=$!
sleep 3

echo "Starting vendor client..."
timeout 10 ./vendor/quic/zig-out/bin/quic-client --connect 127.0.0.1:4433 --insecure > /tmp/e2e_client.log 2>&1 || true

echo ""
echo "=== Results ==="

if grep -q "got.*byte" /tmp/e2e_server.log; then
    echo "✅ Server received data"
else
    echo "❌ Server did not receive data"
fi

if grep -q "echo: hello" /tmp/e2e_client.log; then
    echo "✅ Client completed successfully"
else
    echo "❌ Client did not complete"
fi

echo ""
echo "Server log (grep 'got'):"
grep "got" /tmp/e2e_server.log | head -10

echo ""
echo "Client log (first 20 lines):"
head -20 /tmp/e2e_client.log

kill -KILL $SERVER_PID 2>/dev/null || true
pkill -KILL quic 2>/dev/null || true
