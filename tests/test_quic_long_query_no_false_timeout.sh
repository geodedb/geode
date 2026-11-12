#!/bin/bash
# Regression test for #747 — QUIC `executeQueryOnConnection` does not wire
# `.hooks = .{ .on_progress = touchActiveQueryDeadlineWatchdog }` on the
# `query_runner.collectQuery` call, so long queries over QUIC false-timeout
# even while the server is actively streaming progress bytes back.
#
# CANARY: REQ=REQ-CLI-DEADLINE-WATCHDOG-002; FEATURE="QueryDeadlineWatchdog"; ASPECT=QuicProgressHookIntegration; STATUS=IMPL; OWNER=cli; UPDATED=2026-04-16
#
# See docs/audit/bugfix-harness-failures-triage.md §4 issue #2/#3/#4 —
# three harness failures (distributed_2pc_undo, gap_0183_0185, ISO-EXPR-001)
# all share this root cause.  The source-level pin is in
# `tests/test_deadline_watchdog_quic_progress_followup.sh`.  This file is
# the runtime companion: it starts a real `geode serve`, issues a query
# whose server-side response takes longer than `--timeout` but arrives as a
# continuous byte stream, and asserts the client completes rather than
# false-timing-out.
#
# Symptom (pre-fix):
#   Client prints `Error: query timed out after 5 seconds` on stderr and
#   exits 1, even though server frames are arriving continuously (measured
#   wall-clock for `RETURN range(1, 500000) AS r` on the debug binary is
#   ~7.4s, well beyond the 5s `--timeout`).  The watchdog's
#   `last_progress_ns` is never touched because the QUIC adapter's
#   `send`/`read` path does not invoke `on_progress`.
#
# Expected (post-fix):
#   Client exit 0, stdout contains a successful response, stderr does NOT
#   contain `query timed out`.  The 5s `--timeout` is idle-timeout, not
#   wall-clock — with progress frames flowing, the watchdog extends and
#   the query completes in its natural ~7-8s.
#
# Fast-query smoke check:
#   A trivial `RETURN 1 AS x` with `--timeout 2` must also succeed (serves
#   as the baseline — the bug cannot trigger on a query that completes in
#   <timeout, but we want to ensure the harness itself is healthy).

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

DATA_DIR="$(mktemp -d /tmp/geode-quic-long-query-XXXXXX)"
SRV_LOG="${DATA_DIR}/server.log"

cleanup() {
    if [ -n "${SRV_PID:-}" ]; then
        kill -9 "${SRV_PID}" 2>/dev/null || true
        wait "${SRV_PID}" 2>/dev/null || true
    fi
    rm -rf "${DATA_DIR}"
}
trap cleanup EXIT

echo "[quic-long-query] starting geode serve on 127.0.0.1:${PORT}"
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

FAIL=0

# -----------------------------------------------------------------------------
# Smoke check: a fast query with a short --timeout must not spuriously time out.
# This is the baseline — even pre-fix this should pass because the query
# completes well within the 2s window.  If this fails, the harness is broken
# and the subsequent long-query assertion has no meaning.
# -----------------------------------------------------------------------------
echo "[quic-long-query] smoke: RETURN 1 AS x  --timeout 2"
SMOKE_STDOUT="${DATA_DIR}/smoke.stdout"
SMOKE_STDERR="${DATA_DIR}/smoke.stderr"
timeout 8s "${GEODE_BIN}" query \
    --server "127.0.0.1:${PORT}" \
    --insecure-tls-skip-verify \
    -U geode -P "Geode Test Admin Passphrase" \
    --timeout 2 \
    "RETURN 1 AS x" \
    > "${SMOKE_STDOUT}" 2> "${SMOKE_STDERR}"
SMOKE_RC=$?

if [ "${SMOKE_RC}" -ne 0 ]; then
    echo "FAIL: smoke query exit=${SMOKE_RC} (expected 0); baseline broken." >&2
    sed 's/^/  stderr| /' "${SMOKE_STDERR}" >&2 || true
    FAIL=1
fi
if ! grep -q '"status_class":"00000"' "${SMOKE_STDOUT}"; then
    echo "FAIL: smoke query stdout missing success marker; baseline broken." >&2
    sed 's/^/  stdout| /' "${SMOKE_STDOUT}" >&2 || true
    FAIL=1
fi
if grep -qi "query timed out" "${SMOKE_STDERR}"; then
    echo "FAIL: smoke query stderr contains 'query timed out' — baseline broken." >&2
    FAIL=1
fi

# -----------------------------------------------------------------------------
# Bug A assertion: a server-streamed query whose natural wall-clock is
# longer than --timeout must NOT time out, because frames are arriving
# continuously and the watchdog should be touched on every byte.
#
# `RETURN range(1, 500000) AS r` takes ~7.4s end-to-end on the debug build
# (measured 2026-04-16).  With `--timeout 5`, pre-fix code hits the
# watchdog at 5s and exits 1.  Post-fix code touches the watchdog on every
# inbound QUIC frame, so the idle-timeout never fires and the query
# completes in its natural time.
# -----------------------------------------------------------------------------
echo "[quic-long-query] long: RETURN range(1, 500000) AS r  --timeout 5"
LONG_STDOUT="${DATA_DIR}/long.stdout"
LONG_STDERR="${DATA_DIR}/long.stderr"
START_NS=$(date +%s%N)
# Outer `timeout 60s` so a hard-hung server can't wedge CI forever.
timeout 60s "${GEODE_BIN}" query \
    --server "127.0.0.1:${PORT}" \
    --insecure-tls-skip-verify \
    -U geode -P "Geode Test Admin Passphrase" \
    --timeout 5 \
    "RETURN range(1, 500000) AS r" \
    > "${LONG_STDOUT}" 2> "${LONG_STDERR}"
LONG_RC=$?
END_NS=$(date +%s%N)
ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))
echo "[quic-long-query] long query exit=${LONG_RC} elapsed_ms=${ELAPSED_MS}"

# Pass condition A1: exit code 0 (no false timeout).
if [ "${LONG_RC}" -ne 0 ]; then
    echo "FAIL: long query exit=${LONG_RC} (expected 0) after ${ELAPSED_MS}ms — #747 watchdog false-timeout regression." >&2
    sed 's/^/  stderr| /' "${LONG_STDERR}" >&2 || true
    FAIL=1
fi

# Pass condition A2: stderr does NOT contain the timeout error string.
if grep -qi "query timed out" "${LONG_STDERR}"; then
    echo "FAIL: long query stderr contains 'query timed out' — #747 watchdog false-timeout regression." >&2
    FAIL=1
fi

# Pass condition A3: stdout contains a successful response marker.
if ! grep -q '"status_class":"00000"' "${LONG_STDOUT}"; then
    echo "FAIL: long query stdout missing success marker — response was not completed." >&2
    sed 's/^/  stdout(head)| /' <(head -c 200 "${LONG_STDOUT}") >&2 || true
    FAIL=1
fi

# Pass condition A4: elapsed time was SHORTER than the outer hard timeout.
# We don't pin a precise upper bound because debug/release timing varies,
# but if the query took >45s something is badly wrong.
if [ "${ELAPSED_MS}" -gt 45000 ]; then
    echo "FAIL: long query took ${ELAPSED_MS}ms — server is hung, not just slow." >&2
    FAIL=1
fi

if [ "${FAIL}" -ne 0 ]; then
    exit 1
fi

echo "PASS: QUIC long query completed without false timeout (elapsed=${ELAPSED_MS}ms)"
exit 0
