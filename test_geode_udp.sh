#!/bin/sh

echo "Testing Geode UDP reception"
pkill -KILL geode 2>/dev/null || true
sleep 1

./zig-out/bin/geode serve --listen 127.0.0.1:3141 > /tmp/geode_udp.log 2>&1 &
sleep 3

echo "Sending test packet..."
echo "test" | nc -u 127.0.0.1 3141 &
sleep 2

echo "Checking log..."
grep "recvfrom got" /tmp/geode_udp.log || echo "No packets received"

pkill -KILL geode 2>/dev/null || true
