#!/bin/bash
set -e

echo "Starting geode server..."
timeout 15 ./zig-out/bin/geode serve --listen 127.0.0.1:3141 2>&1 | grep -E "recvfrom got|Socket bound" &
PID=$!

sleep 3

echo "Sending test UDP packet..."
echo "test" | nc -u -w1 127.0.0.1 3141

sleep 3

kill -9 $PID 2>/dev/null || true
pkill -9 geode 2>/dev/null || true

echo "Test complete"
