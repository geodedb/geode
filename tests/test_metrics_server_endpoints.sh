#!/bin/bash
# Regression test for GitLab #749 — Prometheus /metrics + /health HTTP
# endpoints are stubbed out in the Zig 0.16 migration.
#
# CANARY: REQ=REQ-PROMETHEUS-WIRE-003; FEATURE="Prometheus Metrics Endpoint"; ASPECT=HTTPEndpointsIntegration; STATUS=TESTED; TEST=tests/test_metrics_server_endpoints.sh; OWNER=monitoring; UPDATED=2026-04-16
#
# Symptom (pre-fix):    `curl http://127.0.0.1:9091/metrics` → Connection refused.
#                       `MetricsServer.start()` in src/monitoring/metrics_server.zig
#                       is a stub: it sets `running = false` and returns without
#                       binding any socket.  `/health`, `/metrics`, and
#                       `/<anything>` all fail at the TCP layer.
# Expected (post-fix):  All four probes return valid HTTP responses:
#                         (A) GET /metrics  → 200, text/plain, `# HELP` + `# TYPE`.
#                         (B) GET /health   → 200, `ok` in the body.
#                         (C) GET /nonexistent → 404.
#                         (D) GET /metrics via a non-127.0.0.1 Host header → 200
#                             (proves the HTTP handler is Host-header-independent,
#                             i.e. routes on path not Host — Prometheus scrapers
#                             often use DNS names like `metrics.local`).
#
# The test:
#   1. Boots a real geode server with GEODE_METRICS_PORT set to an
#      allocated free port (same env var `src/server/main.zig:541`
#      reads in production).  Admin credentials are bootstrapped with the
#      same pattern the QUIC handshake test uses.
#   2. Waits for the geode main listen port to bind (NOT the metrics
#      port — waiting on the metrics port would make the pre-fix test
#      hang for the entire server-startup timeout since metrics never
#      becomes ready).
#   3. Runs 4 curl probes and asserts each contract.  On pre-fix code
#      every probe fails at connect time (exit 7, ECONNREFUSED).
#   4. Cleans up the server.
#
# This test lives alongside the harness spec gap_0166_prometheus_metrics.yml
# (which is the primary pin).  It adds Host-header-independence coverage and
# can run standalone without the geode-test-harness installed.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GEODE_BIN="${GEODE_BIN:-${REPO_ROOT}/zig-out/bin/geode}"

if [ ! -x "${GEODE_BIN}" ]; then
    echo "FAIL: geode binary not found at ${GEODE_BIN}" >&2
    exit 2
fi

# Allocate two free ports deterministically — one for geode's QUIC listen,
# one for the HTTP metrics endpoint.
QUIC_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
METRICS_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
if ! [[ "${QUIC_PORT}" =~ ^[0-9]+$ ]] || ! [[ "${METRICS_PORT}" =~ ^[0-9]+$ ]]; then
    echo "FAIL: could not allocate free ports" >&2
    exit 2
fi

DATA_DIR="$(mktemp -d /tmp/geode-metrics-endpoints-XXXXXX)"
SRV_LOG="${DATA_DIR}/server.log"

cleanup() {
    if [ -n "${SRV_PID:-}" ]; then
        kill -9 "${SRV_PID}" 2>/dev/null || true
        wait "${SRV_PID}" 2>/dev/null || true
    fi
    rm -rf "${DATA_DIR}"
}
trap cleanup EXIT

echo "[metrics-endpoints] booting geode serve on 127.0.0.1:${QUIC_PORT} (metrics on :${METRICS_PORT})"

# GEODE_METRICS_PORT is the env var read by src/server/main.zig:541 which
# in turn calls metrics_server.initGlobalMetrics() → MetricsServer.start().
GEODE_ADMIN_PASSWORD="GeodeTestPassword123!" \
GEODE_METRICS_PORT="${METRICS_PORT}" \
"${GEODE_BIN}" serve \
    --data-dir "${DATA_DIR}" \
    --listen "127.0.0.1:${QUIC_PORT}" \
    --log-level error \
    > "${SRV_LOG}" 2>&1 &
SRV_PID=$!

# Wait for the QUIC UDP listen socket to bind (up to 5s).  We do NOT wait
# on the metrics TCP port — the whole point of #749 is that the metrics
# server never binds.  A wait on port 9091 would mask the bug by making
# the test hang for the entire startup timeout.
echo "[metrics-endpoints] waiting for main UDP listen on :${QUIC_PORT}"
for _ in $(seq 1 50); do
    if ss -lun "sport = :${QUIC_PORT}" 2>/dev/null | grep -q "${QUIC_PORT}"; then
        break
    fi
    sleep 0.1
done

if ! ss -lun "sport = :${QUIC_PORT}" 2>/dev/null | grep -q "${QUIC_PORT}"; then
    echo "FAIL: geode did not bind UDP :${QUIC_PORT} within 5s" >&2
    echo "---- server log ----" >&2
    cat "${SRV_LOG}" >&2 || true
    exit 1
fi

# Give the server a brief moment to finish the post-listen init.  The
# metrics path is initialized AFTER the main listen bind in main.zig, so
# this sleep is what distinguishes "metrics server is being stood up"
# from "metrics server is permanently dark".
sleep 0.5

# Track overall outcome across all 4 probes — we report every failure
# rather than short-circuiting so the fixer sees the full pre-fix surface.
FAIL_COUNT=0

run_probe() {
    local label="$1"
    local expected_status="$2"
    shift 2
    # Remaining args are the curl invocation (already includes URL, etc.).
    local out
    local rc
    echo "[metrics-endpoints] probe: ${label}"
    out="$(curl -sS -o /dev/stdout -w $'\n__CURL_HTTP_CODE__=%{http_code}\n__CURL_EXIT__=' --max-time 5 "$@" 2>&1)"
    rc=$?
    echo "${out}" | sed 's/^/  | /'
    local code
    code="$(echo "${out}" | awk -F= '/^__CURL_HTTP_CODE__=/{print $2}' | tail -1)"
    if [ "${rc}" -ne 0 ]; then
        echo "  ! ${label}: curl exit=${rc} (pre-fix symptom: ECONNREFUSED on metrics port)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi
    if [ "${code}" != "${expected_status}" ]; then
        echo "  ! ${label}: http_code=${code}, expected ${expected_status}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi
    return 0
}

# --- Probe A: /metrics returns 200 with Prometheus text body ---
BODY_A="$(curl -sS --max-time 5 "http://127.0.0.1:${METRICS_PORT}/metrics" 2>&1)"
RC_A=$?
echo "[metrics-endpoints] GET /metrics → curl_rc=${RC_A} body_bytes=${#BODY_A}"
if [ "${RC_A}" -ne 0 ]; then
    echo "FAIL(A): curl exit=${RC_A} for /metrics. Pre-fix symptom: ECONNREFUSED." >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    if ! grep -q "# HELP" <<< "${BODY_A}"; then
        echo "FAIL(A): /metrics body missing '# HELP' line." >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    if ! grep -q "^# TYPE " <<< "${BODY_A}"; then
        echo "FAIL(A): /metrics body missing any '# TYPE' line." >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    # Content-Type check via a second HEAD-style probe.
    CT_A="$(curl -sSI --max-time 5 "http://127.0.0.1:${METRICS_PORT}/metrics" 2>&1 | tr -d '\r' | awk -F': ' '/^[Cc]ontent-[Tt]ype:/ {print tolower($2)}' | head -1)"
    if [[ "${CT_A}" != text/plain* ]]; then
        echo "FAIL(A): /metrics Content-Type='${CT_A}', expected text/plain*." >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
fi

# --- Probe B: /health returns 200 with 'ok' ---
BODY_B="$(curl -sS --max-time 5 "http://127.0.0.1:${METRICS_PORT}/health" 2>&1)"
RC_B=$?
echo "[metrics-endpoints] GET /health  → curl_rc=${RC_B} body='${BODY_B}'"
if [ "${RC_B}" -ne 0 ]; then
    echo "FAIL(B): curl exit=${RC_B} for /health. Pre-fix symptom: ECONNREFUSED." >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    if ! grep -q "ok" <<< "${BODY_B}"; then
        echo "FAIL(B): /health body does not contain 'ok'." >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
fi

# --- Probe C: /nonexistent returns 404 ---
# Use -i so we can grep the status line; -f would swallow the 404 body.
RESP_C="$(curl -sSi --max-time 5 "http://127.0.0.1:${METRICS_PORT}/nonexistent" 2>&1)"
RC_C=$?
echo "[metrics-endpoints] GET /nonexistent → curl_rc=${RC_C}"
if [ "${RC_C}" -ne 0 ]; then
    echo "FAIL(C): curl exit=${RC_C} for /nonexistent. Pre-fix symptom: ECONNREFUSED." >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    if ! grep -qE "^HTTP/1\.[01] 404" <<< "${RESP_C}"; then
        echo "FAIL(C): /nonexistent did not return 404. Got:" >&2
        echo "${RESP_C}" | head -3 >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
fi

# --- Probe D: /metrics via a non-127.0.0.1 Host header (metrics.local) ---
# Prometheus scrapers resolve the target by DNS and set Host accordingly.
# A working HTTP router must match on path, not on Host — so this probe
# must still return 200 with a Prometheus body.  --resolve rewrites DNS
# without changing Host, so the request goes to 127.0.0.1:PORT but the
# Host header reads `metrics.local:PORT`.
BODY_D="$(curl -sS --max-time 5 \
    --resolve "metrics.local:${METRICS_PORT}:127.0.0.1" \
    "http://metrics.local:${METRICS_PORT}/metrics" 2>&1)"
RC_D=$?
echo "[metrics-endpoints] GET /metrics (Host=metrics.local) → curl_rc=${RC_D} body_bytes=${#BODY_D}"
if [ "${RC_D}" -ne 0 ]; then
    echo "FAIL(D): curl exit=${RC_D} with Host=metrics.local. Pre-fix symptom: ECONNREFUSED." >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    if ! grep -q "# HELP" <<< "${BODY_D}"; then
        echo "FAIL(D): /metrics body (Host=metrics.local) missing '# HELP'." >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
fi

if [ "${FAIL_COUNT}" -gt 0 ]; then
    echo "" >&2
    echo "RESULT: ${FAIL_COUNT} probe failure(s). Pre-fix: expected 4+ failures because" >&2
    echo "        MetricsServer.start() is a stub and no TCP listener binds." >&2
    echo "---- server log tail ----" >&2
    tail -40 "${SRV_LOG}" >&2 || true
    exit 1
fi

echo "PASS: /metrics + /health + 404 + Host-independent probes all green"
exit 0
