#!/bin/bash
set -e

echo "Starting QUIC server..."
ADMIN_USER="${GEODE_ADMIN_USERNAME:-geode}"
ADMIN_PASS="${GEODE_DEFAULT_PASSWORD:-geode-test-password}"
GEODE_ADMIN_USERNAME="${ADMIN_USER}" GEODE_DEFAULT_PASSWORD="${ADMIN_PASS}" \
    ./zig-out/bin/geode serve --listen 127.0.0.1:8443 > server.log 2>&1 &
SERVER_PID=$!

sleep 2

echo "Sending QUIC query..."
timeout 10s ./zig-out/bin/geode query "RETURN 1 AS test" --server 127.0.0.1:8443 --insecure --user "${ADMIN_USER}" --password "${ADMIN_PASS}" || true

echo ""
echo "Server log:"
tail -50 server.log

kill $SERVER_PID 2>/dev/null || true
