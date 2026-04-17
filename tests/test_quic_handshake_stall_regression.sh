#!/bin/bash
# Regression test for QUIC client handshake stall
# (Zig 0.16 removed std.Io.Condition.timedWait; hand-rolled nanosleep+re-check
# port in the client stream-receive path spin-futexes at ~250us cadence and
# never lets the main thread drive ep.poll() — see
# docs/audit/bugfix-quic-handshake-triage.md primary defect).
#
# CANARY: REQ=REQ-GQL-074; FEATURE="QUIC Transport"; ASPECT=ClientHandshakeStallRegression; STATUS=TESTED; TEST=test_quic_handshake_stall_regression; OWNER=transport; UPDATED=2026-04-16
#
# Symptom (pre-fix):    `geode query "RETURN 1"` times out at the client deadline.
# Expected (post-fix):  Client handshake + 1-RTT round trip complete well under 2s.
#
# The test:
#   1. Boots a real geode server (real UDP, real QUIC, real TLS — no mocks).
#   2. Runs a client query with a 2s budget.
#   3. Asserts exit=0 and a response was produced.
#
# On the pre-fix code path the 250us futex-spin on the client's worker thread
# starves the main thread of ep.poll() calls, so the 2s budget MUST trip.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GEODE_BIN="${GEODE_BIN:-${REPO_ROOT}/zig-out/bin/geode}"

if [ ! -x "${GEODE_BIN}" ]; then
    echo "FAIL: geode binary not found at ${GEODE_BIN}" >&2
    exit 2
fi

# Allocate a free port deterministically.
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
if ! [[ "${PORT}" =~ ^[0-9]+$ ]]; then
    echo "FAIL: could not allocate a free port" >&2
    exit 2
fi

DATA_DIR="$(mktemp -d /tmp/geode-handshake-stall-XXXXXX)"
SRV_LOG="${DATA_DIR}/server.log"
CLI_LOG="${DATA_DIR}/client.log"

cleanup() {
    if [ -n "${SRV_PID:-}" ]; then
        kill -9 "${SRV_PID}" 2>/dev/null || true
        wait "${SRV_PID}" 2>/dev/null || true
    fi
    rm -rf "${DATA_DIR}"
}
trap cleanup EXIT

echo "[handshake-stall] starting geode serve on 127.0.0.1:${PORT}"
"${GEODE_BIN}" serve \
    --data-dir "${DATA_DIR}" \
    --listen "127.0.0.1:${PORT}" \
    --log-level error \
    > "${SRV_LOG}" 2>&1 &
SRV_PID=$!

# Wait for port to be listening (up to 5s).
for _ in $(seq 1 50); do
    if ss -lun "sport = :${PORT}" 2>/dev/null | grep -q "${PORT}"; then
        break
    fi
    sleep 0.1
done

if ! ss -lun "sport = :${PORT}" 2>/dev/null | grep -q "${PORT}"; then
    echo "FAIL: server did not bind 127.0.0.1:${PORT} within 5s" >&2
    cat "${SRV_LOG}" >&2 || true
    exit 1
fi

echo "[handshake-stall] server listening; running query with 2s budget"

# 2s client budget. Pre-fix: the 5s --timeout will trip because the third
# thread's 250us futex spin keeps the main thread from polling ep.
# We wrap with an outer `timeout 6s` so a hard hang cannot stall CI.
START_NS=$(date +%s%N)
timeout 6s "${GEODE_BIN}" query \
    --server "127.0.0.1:${PORT}" \
    --insecure-tls-skip-verify \
    -U geode -P GeodeTestPassword123! \
    --timeout 2 \
    "RETURN 1 AS x" \
    > "${CLI_LOG}" 2>&1
CLI_RC=$?
END_NS=$(date +%s%N)
ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))

echo "[handshake-stall] client exit=${CLI_RC} elapsed_ms=${ELAPSED_MS}"
echo "[handshake-stall] client output:"
sed 's/^/  | /' "${CLI_LOG}" || true

# Pass conditions:
#   - Client exited 0 (no timeout, no error).
#   - Elapsed < 2500ms (comfortably under the 2s timeout plus startup fudge).
#   - Output contains a success status ("00000") or the value "1".
if [ "${CLI_RC}" -ne 0 ]; then
    echo "FAIL: client exit=${CLI_RC} (expected 0). Pre-fix symptom: handshake stall." >&2
    exit 1
fi

if [ "${ELAPSED_MS}" -gt 2500 ]; then
    echo "FAIL: client elapsed=${ELAPSED_MS}ms > 2500ms budget. Pre-fix symptom: handshake stall." >&2
    exit 1
fi

if ! grep -qE '"status_class":"00000"|"rows":|\b1\b' "${CLI_LOG}"; then
    echo "FAIL: client output did not contain a successful response marker." >&2
    exit 1
fi

echo "PASS: handshake completed in ${ELAPSED_MS}ms (budget 2500ms)"
exit 0
