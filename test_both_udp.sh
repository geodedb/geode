#!/bin/bash

# Start geode server
timeout 15 ./zig-out/bin/geode serve --listen 127.0.0.1:3141 2>&1 | grep -E "recvfrom got" &
PID=$!

sleep 3

echo "=== Test 1: netcat ==="
echo "test1" | nc -u -w1 127.0.0.1 3141
sleep 1

echo "=== Test 2: raw Go UDP ==="
go run test_raw_udp.go
sleep 1

echo "=== Test 3: quic-go (will timeout) ==="
timeout 8 go run test_quic_connection.go 2>&1 || echo "QUIC test timed out or failed"

sleep 2

kill -9 $PID 2>/dev/null || true
pkill -9 geode 2>/dev/null || true

echo "Test complete"
