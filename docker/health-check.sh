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
# Probe order:
#   1. GET http://127.0.0.1:${GEODE_METRICS_PORT}/health — the server's
#      out-of-band liveness endpoint (src/monitoring/metrics_server.zig). It is
#      unauthenticated plain HTTP served on its own thread, completely off the
#      QUIC query path, so a probe tick can neither fail TLS verification nor be
#      recorded as a failed authentication attempt. The server only starts that
#      listener when GEODE_METRICS_PORT is set, so the server images bake in a
#      default (ENV GEODE_METRICS_PORT).
#   2. Only if that endpoint is unreachable AND both GEODE_USERNAME and
#      GEODE_PASSWORD are configured: an authenticated GQL probe over QUIC.
#
# Why this order: the previous version ran the authenticated query path
# unconditionally — with no credentials by default. The server records every
# credential-less HELLO as a failed authentication against its per-source-IP
# rate limiter (src/server/quic_connection_handler.zig), and a probe that can
# never succeed never resets that counter, so the limiter re-tripped on every
# tick forever and the container never recovered.
#
# TLS: this script never asks the CLI to skip certificate verification. The
# release CLI refuses that flag under production conditions (SEC-CLI-01,
# src/cli/insecure_tls_gate.zig) unless GEODE_ALLOW_INSECURE_TLS is set in the
# environment — which no image sets — so passing it made the probe exit 1
# before it ever opened a socket. Point GEODE_HEALTH_CA_CERT at the server's CA
# to use the authenticated fallback with verification intact.
#
# Environment variables (all optional):
#   GEODE_METRICS_PORT   - port of the HTTP liveness endpoint (default: 9090)
#   GEODE_HEALTH_TIMEOUT - seconds allowed for the liveness probe (default: 2)
#   GEODE_HEALTH_PORT    - QUIC port for the authenticated fallback (default: 3141)
#   GEODE_USERNAME       - auth username for the authenticated fallback
#   GEODE_PASSWORD       - auth password for the authenticated fallback
#   GEODE_HEALTH_CA_CERT - CA bundle used to verify the server's certificate

set -e

PORT="${GEODE_HEALTH_PORT:-3141}"
METRICS_PORT="${GEODE_METRICS_PORT:-9090}"
TIMEOUT="${GEODE_HEALTH_TIMEOUT:-2}"
HEALTH_URL="http://127.0.0.1:${METRICS_PORT}/health"

# Probe the unauthenticated liveness endpoint using whichever HTTP client the
# image provides: curl, wget (busybox on the Alpine images), or bash's /dev/tcp
# (Debian ships bash even in -slim). Succeeds only on HTTP 200.
probe_liveness() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time "$TIMEOUT" "$HEALTH_URL" >/dev/null 2>&1
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T "$TIMEOUT" -O /dev/null "$HEALTH_URL" >/dev/null 2>&1
    elif command -v bash >/dev/null 2>&1; then
        # bash builtins only (exec/printf/read/case) — needs no curl, cat or
        # grep, which the Debian -slim runtime images do not all ship.
        timeout "$TIMEOUT" bash -c "exec 3<>/dev/tcp/127.0.0.1/${METRICS_PORT} || exit 1
printf 'GET /health HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n' >&3
read -r status <&3
case \"\$status\" in
    'HTTP/1.0 200'* | 'HTTP/1.1 200'*) exit 0 ;;
    *) exit 1 ;;
esac" 2>/dev/null
    else
        return 1
    fi
}

if probe_liveness; then
    exit 0
fi

# Authenticated fallback, only when BOTH credentials are configured: a
# credential-less attempt can never authenticate and would spend the server's
# auth rate-limiter budget on every tick.
if [ -n "$GEODE_USERNAME" ] && [ -n "$GEODE_PASSWORD" ]; then
    # Positional parameters, never a concatenated string: the password stays a
    # single argv element even though it contains spaces, which the server's
    # own password policy (>= 3 words) effectively requires.
    set -- query "RETURN 1 AS health" --server "127.0.0.1:${PORT}"
    set -- "$@" -U "$GEODE_USERNAME" -P "$GEODE_PASSWORD"
    if [ -n "$GEODE_HEALTH_CA_CERT" ]; then
        set -- "$@" --ca-cert "$GEODE_HEALTH_CA_CERT"
    fi
    exec /usr/local/bin/geode "$@"
fi

echo "geode health check: no response from ${HEALTH_URL}" >&2
echo "geode health check: set GEODE_METRICS_PORT to enable the liveness endpoint," \
    "or GEODE_USERNAME/GEODE_PASSWORD for an authenticated probe" >&2
exit 1
