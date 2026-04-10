#!/bin/sh
# Shared Geode health check script for Docker containers.
# Extracted to a single file to avoid duplicating the HEALTHCHECK CMD
# across 13+ Dockerfiles (see issue #549).
#
# Usage in Dockerfile:
#   COPY docker/health-check.sh /usr/local/bin/health-check.sh
#   HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
#       CMD /usr/local/bin/health-check.sh
#
# Environment variables (optional):
#   GEODE_HEALTH_PORT  - port to check (default: 3141)
#   GEODE_USERNAME     - auth username (omitted if unset)
#   GEODE_PASSWORD     - auth password (omitted if unset)
#
# SEC-22: --insecure is acceptable here because the health check connects to
# localhost (127.0.0.1) only, never leaving the container. The auto-generated
# TLS cert's CN won't match 127.0.0.1, so TLS verification must be skipped.

set -e

PORT="${GEODE_HEALTH_PORT:-3141}"

AUTH_ARGS=""
if [ -n "$GEODE_USERNAME" ]; then
    AUTH_ARGS="$AUTH_ARGS -U $GEODE_USERNAME"
fi
if [ -n "$GEODE_PASSWORD" ]; then
    AUTH_ARGS="$AUTH_ARGS -P $GEODE_PASSWORD"
fi

# shellcheck disable=SC2086
exec /usr/local/bin/geode query "RETURN 1 AS health" \
    --server "127.0.0.1:${PORT}" \
    --insecure \
    $AUTH_ARGS
