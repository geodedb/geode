#!/bin/bash
# Regression reproducer for GitLab #751 — CLI session setup queues behind the
# thread-pool's single blocking-lane worker under concurrent write load.
#
# CANARY: REQ=REQ-PERF-SESSION-ADMISSION-001; FEATURE="ConnectionAdmissionParallelism"; ASPECT=RegressionRepro; STATUS=IMPL; TEST=test_session_admission_parallelism; OWNER=transport; UPDATED=2026-04-16
#
# Root cause (per docs/audit/bugfix-session-contention-triage.md):
#   src/transport/thread_pool.zig hardcodes blocking_workers = 1 AND routes
#   every submit() call to `.lane = .blocking` (L188-190, L211). The main
#   connection pool has 16 workers but only the one blocking-lane worker
#   ever services new-connection work; the other 15 idle. Under 8 writers
#   a freshly-connecting CLI queues behind their handshake+query work and
#   exhausts `--timeout 5` deterministically (see triage table: 0 writers
#   = 870 ms, 8 writers = 6077 ms / TIMEOUT on `RETURN 1 AS x`).
#
# Repro strategy (reuses the BACKGROUND_LOAD pattern from
# test_count_nodes_no_flake.sh — do NOT edit that file; this one is an
# admission-latency-specific twin):
#   1. Boot `geode serve` on an ephemeral port.
#   2. Spawn 8 background CLIs that loop a trivial `CREATE … RETURN count(*)`
#      so the admission pool is saturated with real short-lived connections.
#   3. Measure `RETURN 1 AS x` 10 times with `--timeout 3`. `RETURN 1` has
#      zero storage / zero WAL / zero mutex — the only thing it can be
#      waiting on is admission-lane parallelism.
#   4. Assert every run completes in < 2000 ms.
#
# Expected pre-fix: at least 1 of 10 runs > 2000 ms (triage matrix shows
# all runs at ~6000 ms under 8 writers). Red.
# Expected post-fix: 10/10 runs < 2000 ms (ideally << 1500 ms per triage
# prediction). Green.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GEODE_BIN="${GEODE_BIN:-${REPO_ROOT}/zig-out/bin/geode}"

# 10 measurements of `RETURN 1 AS x` under 8 writer load. Under the
# pre-fix scheduler, probability a single measurement lands under 2000 ms
# is effectively zero once the queue has 4+ writers ahead — triage
# measured uniformly ~6 s. Post-fix each measurement costs ~150-250 ms
# (handshake + one RETURN), comfortably under the 2000 ms bar.
RUNS="${RUNS:-10}"

# Per-measurement pass threshold in milliseconds. Chosen well below the
# triage's pre-fix minimum (6063 ms at N=8) and well above the post-fix
# prediction (< 1500 ms per run). Lenient enough to absorb first-run
# TLS/handshake jitter; tight enough to still deterministically fail
# pre-fix.
PASS_MS="${PASS_MS:-2000}"

# Client deadline. Keep it tight so a pre-fix stall trips here rather than
# propagating a 30 s hang up to `timeout 60s`.
CLIENT_TIMEOUT="${CLIENT_TIMEOUT:-3}"

# Number of concurrent CREATE writers. 8 is the triage's measured threshold
# for a deterministic red; 6 already trips but 8 is unambiguous.
NUM_WRITERS="${NUM_WRITERS:-8}"

if [ ! -x "${GEODE_BIN}" ]; then
    echo "FAIL: geode binary not found at ${GEODE_BIN} (run 'make build' first)" >&2
    exit 2
fi

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
if ! [[ "${PORT}" =~ ^[0-9]+$ ]]; then
    echo "FAIL: could not allocate a free port" >&2
    exit 2
fi

DATA_DIR="$(mktemp -d /tmp/geode-admission-parallel-XXXXXX)"
SRV_LOG="${DATA_DIR}/server.log"
ADMIN_PASSWORD="Geode Test Admin Passphrase"

LOAD_PIDS=()
cleanup() {
    for lp in "${LOAD_PIDS[@]:-}"; do
        [ -n "${lp:-}" ] && kill -9 "${lp}" 2>/dev/null || true
    done
    for lp in "${LOAD_PIDS[@]:-}"; do
        [ -n "${lp:-}" ] && wait "${lp}" 2>/dev/null || true
    done
    if [ -n "${SRV_PID:-}" ]; then
        kill -9 "${SRV_PID}" 2>/dev/null || true
        wait "${SRV_PID}" 2>/dev/null || true
    fi
    rm -rf "${DATA_DIR}"
}
trap cleanup EXIT

echo "[admission-parallel] starting geode serve on 127.0.0.1:${PORT}"
GEODE_ADMIN_PASSWORD="${ADMIN_PASSWORD}" "${GEODE_BIN}" serve \
    --data-dir "${DATA_DIR}" \
    --listen "127.0.0.1:${PORT}" \
    --log-level error \
    > "${SRV_LOG}" 2>&1 &
SRV_PID=$!

BOUND=0
for _ in $(seq 1 100); do
    if ss -lun "sport = :${PORT}" 2>/dev/null | grep -q "${PORT}"; then
        BOUND=1
        break
    fi
    sleep 0.1
done

if [ "${BOUND}" -ne 1 ]; then
    echo "FAIL: server did not bind 127.0.0.1:${PORT} within 10s" >&2
    sed 's/^/  srv| /' "${SRV_LOG}" >&2 || true
    exit 1
fi

echo "[admission-parallel] server bound; smoke-testing auth path"

geode_q() {
    local q="$1"
    local timeout_ms="${2:-${CLIENT_TIMEOUT}}"
    timeout 10s "${GEODE_BIN}" query \
        --server "127.0.0.1:${PORT}" \
        --insecure-tls-skip-verify \
        -U geode -P "${ADMIN_PASSWORD}" \
        --timeout "${timeout_ms}" \
        "${q}"
}

# Smoke test before starting writer load — verifies the auth path and
# confirms a trivial query completes at baseline (no concurrent load).
if ! geode_q "RETURN 1 AS x" > /dev/null 2>&1; then
    echo "FAIL: baseline RETURN 1 failed before writer load started" >&2
    sed 's/^/  srv| /' "${SRV_LOG}" >&2 || true
    exit 1
fi

echo "[admission-parallel] spawning ${NUM_WRITERS} concurrent CREATE writers"

for k in $(seq 1 "${NUM_WRITERS}"); do
    (
        while :; do
            # `CREATE (:W {i: $i}) RETURN count(*)` — short-lived write
            # exactly matching the triage repro shape. Use k as the $i
            # value so all 8 writers push distinct nodes.
            geode_q "CREATE (w:W {i: ${k}}) RETURN count(*) AS c" 4 > /dev/null 2>&1 || true
        done
    ) &
    LOAD_PIDS+=("$!")
done

# Let the writer backlog saturate the admission worker. With the single
# blocking-lane worker serving ~200 ms per connection lifecycle, 8
# concurrent writers reach steady-state queue depth within ~2 s.
sleep 2

echo "[admission-parallel] writers warm; running ${RUNS} trivial admission measurements"

FAIL=0
OVER_BAR=0
MAX_MS=0
MIN_MS=99999999

for i in $(seq 1 "${RUNS}"); do
    RUN_OUT="$(mktemp "${DATA_DIR}/run_${i}.out.XXXXXX")"
    RUN_ERR="$(mktemp "${DATA_DIR}/run_${i}.err.XXXXXX")"

    START_NS=$(date +%s%N)
    geode_q "RETURN 1 AS x" > "${RUN_OUT}" 2> "${RUN_ERR}"
    RC=$?
    END_NS=$(date +%s%N)
    ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))

    if [ "${ELAPSED_MS}" -gt "${MAX_MS}" ]; then MAX_MS="${ELAPSED_MS}"; fi
    if [ "${ELAPSED_MS}" -lt "${MIN_MS}" ]; then MIN_MS="${ELAPSED_MS}"; fi

    STATUS="OK"
    if [ "${RC}" -ne 0 ]; then
        STATUS="RC=${RC}"
        FAIL=1
    fi

    if [ "${ELAPSED_MS}" -gt "${PASS_MS}" ]; then
        STATUS="${STATUS} SLOW(${ELAPSED_MS}ms>${PASS_MS}ms)"
        OVER_BAR=$((OVER_BAR + 1))
        FAIL=1
    fi

    echo "[admission-parallel] run ${i}/${RUNS}: ${ELAPSED_MS}ms ${STATUS}"
done

echo "[admission-parallel] summary: min=${MIN_MS}ms max=${MAX_MS}ms over_bar=${OVER_BAR}/${RUNS} (bar=${PASS_MS}ms)"

if [ "${FAIL}" -ne 0 ]; then
    echo "FAIL: at least one of ${RUNS} trivial RETURN 1 measurements exceeded ${PASS_MS}ms under ${NUM_WRITERS}-writer load." >&2
    echo "      Pre-fix: all runs cluster around ~6000 ms because the single blocking-lane" >&2
    echo "      worker serializes connection admission (see triage)." >&2
    echo "      Fix: route src/server/main.zig:900 pool.submit(...) via a default-lane" >&2
    echo "      entry point in src/transport/thread_pool.zig." >&2
    exit 1
fi

echo "PASS: ${RUNS}/${RUNS} trivial admission measurements under ${PASS_MS}ms under ${NUM_WRITERS}-writer load"
exit 0
