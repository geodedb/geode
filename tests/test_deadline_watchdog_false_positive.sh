#!/bin/bash
# Regression test for issue #746 — spurious `query timed out` on successful query.
#
# CANARY: REQ=REQ-CLI-DEADLINE-WATCHDOG-001; FEATURE="QueryDeadlineWatchdog"; ASPECT=FalsePositiveRegression; STATUS=TESTED; TEST=test_deadline_watchdog_false_positive; OWNER=cli; UPDATED=2026-04-16
#
# Symptom (pre-fix):
#   `geode query "RETURN 1"` prints the correct JSON response to stdout, then
#   ~800 ms later emits `Error: query timed out after N seconds` on stderr and
#   exits 1 — even though the server responded in <1s and the client budget
#   was 10s.  Mechanism: QueryDeadlineState lives on cmdQuery's stack;
#   .finish() doesn't join the watchdog; after cmdQuery returns the stack is
#   reused and the watchdog reads garbage last_progress_ns, computes now -
#   garbage >> timeout_ns, writes the error, and calls std.process.exit(1).
#
# Expected (post-fix):
#   Client exit 0, stdout contains a successful response, stderr does NOT
#   contain `query timed out`, wall-clock well under 3s.
#
# See docs/audit/bugfix-deadline-watchdog-triage.md.

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

DATA_DIR="$(mktemp -d /tmp/geode-watchdog-false-positive-XXXXXX)"
SRV_LOG="${DATA_DIR}/server.log"
CLI_STDOUT="${DATA_DIR}/client.stdout"
CLI_STDERR="${DATA_DIR}/client.stderr"

cleanup() {
    if [ -n "${SRV_PID:-}" ]; then
        kill -9 "${SRV_PID}" 2>/dev/null || true
        wait "${SRV_PID}" 2>/dev/null || true
    fi
    rm -rf "${DATA_DIR}"
}
trap cleanup EXIT

echo "[watchdog-false-positive] starting geode serve on 127.0.0.1:${PORT}"
GEODE_ADMIN_PASSWORD="Geode Test Admin Passphrase" "${GEODE_BIN}" serve \
    --data-dir "${DATA_DIR}" \
    --listen "127.0.0.1:${PORT}" \
    --log-level error \
    > "${SRV_LOG}" 2>&1 &
SRV_PID=$!

# Wait for the UDP listener to bind (up to 5s).
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

echo "[watchdog-false-positive] server listening; issuing trivial RETURN 1 with --timeout 10"

# --timeout 10 is intentionally well above the actual response time (~<1s
# against localhost).  A correct fix should NEVER make the watchdog fire.
# Outer `timeout 8s` guard so a hard hang can't stall CI forever.
START_NS=$(date +%s%N)
timeout 8s "${GEODE_BIN}" query \
    --server "127.0.0.1:${PORT}" \
    --insecure-tls-skip-verify \
    -U geode -P "Geode Test Admin Passphrase" \
    --timeout 10 \
    "RETURN 1 AS x" \
    > "${CLI_STDOUT}" 2> "${CLI_STDERR}"
CLI_RC=$?
END_NS=$(date +%s%N)
ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))

echo "[watchdog-false-positive] client exit=${CLI_RC} elapsed_ms=${ELAPSED_MS}"
echo "[watchdog-false-positive] client stdout:"
sed 's/^/  | /' "${CLI_STDOUT}" || true
echo "[watchdog-false-positive] client stderr:"
sed 's/^/  | /' "${CLI_STDERR}" || true

FAIL=0

# Pass condition 1: exit code 0.
if [ "${CLI_RC}" -ne 0 ]; then
    echo "FAIL: client exit=${CLI_RC} (expected 0). Pre-fix symptom: spurious watchdog exit(1)." >&2
    FAIL=1
fi

# Pass condition 2: stdout contains a successful response marker.
if ! grep -qE '"status_class":"00000"|"rows":|\b1\b' "${CLI_STDOUT}"; then
    echo "FAIL: client stdout did not contain a successful response marker." >&2
    FAIL=1
fi

# Pass condition 3 — THE primary #746 regression assertion:
# stderr must NOT contain "query timed out".  The pre-fix watchdog UAF
# prints this exact string after stdout has already produced a correct
# response, causing the test to trip here.
if grep -qi "query timed out" "${CLI_STDERR}"; then
    echo "FAIL: stderr contains 'query timed out' after a successful query — #746 regression." >&2
    FAIL=1
fi

# Pass condition 4: elapsed well under 3 seconds.
if [ "${ELAPSED_MS}" -gt 3000 ]; then
    echo "FAIL: client elapsed=${ELAPSED_MS}ms > 3000ms — unexpectedly slow (possible stall or retry)." >&2
    FAIL=1
fi

if [ "${FAIL}" -ne 0 ]; then
    exit 1
fi

echo "PASS: query completed in ${ELAPSED_MS}ms without spurious watchdog timeout"
exit 0
