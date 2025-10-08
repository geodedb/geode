#!/bin/bash

# Start geode server in background
./zig-out/bin/geode serve --listen 0.0.0.0:3141 2>&1 | grep -E "recvfrom got" &
GEODE_PID=$!

# Wait for server to start
sleep 3

# Check if socket is bound
echo "=== Checking if socket is bound ==="
ss -ulnp | grep 3141

# Send test UDP packet
echo "=== Sending test UDP packet with netcat ==="
echo "test" | nc -u -w1 127.0.0.1 3141

# Wait a bit for processing
sleep 2

# Cleanup
kill -9 $GEODE_PID 2>/dev/null
