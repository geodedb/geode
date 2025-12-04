#!/bin/bash
# Health check script for Geode server in Docker

set -e

GEODE_HOST="${GEODE_HOST:-127.0.0.1}"
GEODE_PORT="${GEODE_PORT:-8443}"
TIMEOUT="${HEALTH_CHECK_TIMEOUT:-10}"

# Check if geode binary exists
if [ ! -x "/app/geode" ]; then
    echo "ERROR: Geode binary not found"
    exit 1
fi

# Try to execute a simple query
RESULT=$(/app/geode query \
    --server "${GEODE_HOST}:${GEODE_PORT}" \
    --insecure \
    --timeout "${TIMEOUT}s" \
    "RETURN 'health-check' AS status" 2>&1)

if echo "$RESULT" | grep -q '"status"'; then
    echo "OK: Geode server is healthy"
    exit 0
else
    echo "ERROR: Health check failed - $RESULT"
    exit 1
fi
