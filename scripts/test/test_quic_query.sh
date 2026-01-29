#!/bin/bash
set -e

echo "Starting QUIC server..."
./zig-out/bin/geode serve --listen-quic 127.0.0.1:8443 --test-exit-after-first > server.log 2>&1 &
SERVER_PID=$!

sleep 2

echo "Sending QUIC query..."
timeout 10s ./zig-out/bin/geode query --quic 127.0.0.1:8443 "RETURN 1 AS test" || true

echo ""
echo "Server log:"
tail -50 server.log

kill $SERVER_PID 2>/dev/null || true
