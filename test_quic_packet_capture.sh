#!/bin/bash

# Start packet capture
timeout 15 tcpdump -i lo -n udp port 3141 2>&1 &
TCPDUMP_PID=$!

sleep 2

# Start geode server
timeout 15 ./zig-out/bin/geode serve --listen 127.0.0.1:3141 2>&1 | grep -E "recvfrom got" &
GEODE_PID=$!

sleep 3

# Run quic-go client
echo "Running QUIC client..."
timeout 10 go run test_quic_connection.go 2>&1

sleep 3

# Cleanup
kill -9 $TCPDUMP_PID 2>/dev/null || true
kill -9 $GEODE_PID 2>/dev/null || true
pkill -9 geode 2>/dev/null || true
pkill -9 tcpdump 2>/dev/null || true

echo "Test complete"
