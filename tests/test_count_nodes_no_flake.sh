#!/bin/bash
# Harness flake pin for the unlabeled `MATCH (n) RETURN count(n)` 30s stall
# triaged in docs/audit/bugfix-shell-count-nodes-triage.md.
#
# CANARY: REQ=REQ-PERF-COUNT-NODES-PUSHDOWN; FEATURE="UnlabeledMatchCountPushdown"; ASPECT=FlakePin; STATUS=TESTED; TEST=test_count_nodes_no_flake; OWNER=execution; UPDATED=2026-04-16
#
# Symptom (pre-fix): geodetestlab `shell_comprehensive_tests.yml::count-nodes`
# SIGKILLs at 30s roughly 1-in-4 runs. The triage identifies the unlabeled
# full-scan fallback at `src/execution/match_operations.zig:1738-1754`
# iterating every node under store_mutex while a background WAL/checkpoint
# writer parks the reader.
#
# Strategy: seed a small graph (matching the geodetestlab spec shape — 5
# nodes by the time the `count-nodes` test runs), then hammer the exact
# query 10 times in a row with a tight 5s client timeout and a 3s
# pass-bar on wall-clock. Pre-fix the flake rate should put at least one
# hit across 10 runs (triager observed 1-in-4 locally; 10 runs = P(no-hit)
# = (3/4)^10 ≈ 5.6%, so under 6% false-green). Post-fix every run returns
# in <50ms because the count-only pushdown is O(1).
#
# This test intentionally does NOT modify the geodetestlab YAML spec — that
# spec stays as the ground-truth flake source. This shell test is the
# repo-local reproducer that the fixer can iterate on without needing the
# geode-test-harness checkout.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GEODE_BIN="${GEODE_BIN:-${REPO_ROOT}/zig-out/bin/geode}"

# How many consecutive successful runs we require. 10 runs vs a 1-in-4
# pre-fix flake rate yields ~5.6% false-green chance; good enough to
# prove the red/green transition.
RUNS="${RUNS:-10}"

# Per-run wall-clock pass threshold in milliseconds.
#
# The triage-observed flake rate is 1-in-4 under concurrent load with
# 4150 other tests running (WAL checkpointer contending with the
# full-scan reader on the store mutex). Isolated single-spec runs show
# every query completing in 767-870 ms — the 30-second SIGKILL only
# materialises when WAL/checkpoint writers park the reader.
#
# We set PASS_MS=3000 per the triage spec: catches the statistical
# 30-second hang whenever it fires, generous enough to never flake on a
# quiet machine, and tight enough that a post-fix count-only pushdown
# (server-side response <1 ms; CLI overhead ~800 ms unchanged) still
# lands comfortably under the bar. This makes the test a **flake pin**,
# not a pure-deterministic regression test:
#
#   - On a pristine local run (zero background harness load): this test
#     can pass pre-fix because the WAL-contention scenario doesn't arise.
#     That is exactly what the triage observes and what "1-in-4" means.
#   - Under full geodetestlab load OR with a WAL-busy server: this test
#     reliably catches pre-fix stalls.
#   - Post-fix: the pushdown path never iterates the node map, so no
#     Tier-1 lock contention can touch it; must pass 10/10 under any
#     load.
#
# To force a reliable pre-fix red on a quiet box, set BACKGROUND_LOAD=1
# which spawns a concurrent writer to contend the store_mutex while the
# count queries run.
PASS_MS="${PASS_MS:-3000}"

# Client `--timeout N` (seconds). Tighter than the harness's 30s so a
# pre-fix stall trips out inside THIS test instead of hanging the driver.
CLIENT_TIMEOUT="${CLIENT_TIMEOUT:-5}"

if [ ! -x "${GEODE_BIN}" ]; then
    echo "FAIL: geode binary not found at ${GEODE_BIN} (run 'make build' first)" >&2
    exit 2
fi

# Deterministic free-port allocation.
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
if ! [[ "${PORT}" =~ ^[0-9]+$ ]]; then
    echo "FAIL: could not allocate a free port" >&2
    exit 2
fi

DATA_DIR="$(mktemp -d /tmp/geode-count-nodes-flake-XXXXXX)"
SRV_LOG="${DATA_DIR}/server.log"
ADMIN_PASSWORD="Geode Test Admin Passphrase"

cleanup() {
    if [ -n "${SRV_PID:-}" ]; then
        kill -9 "${SRV_PID}" 2>/dev/null || true
        wait "${SRV_PID}" 2>/dev/null || true
    fi
    rm -rf "${DATA_DIR}"
}
trap cleanup EXIT

echo "[count-nodes-flake-pin] starting geode serve on 127.0.0.1:${PORT}"
GEODE_ADMIN_PASSWORD="${ADMIN_PASSWORD}" "${GEODE_BIN}" serve \
    --data-dir "${DATA_DIR}" \
    --listen "127.0.0.1:${PORT}" \
    --log-level error \
    > "${SRV_LOG}" 2>&1 &
SRV_PID=$!

# Wait for the UDP listener to bind (up to 10s — serve path imports a
# lot of state on debug builds, first boot can take ~2-3s).
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

echo "[count-nodes-flake-pin] server listening; issuing a fresh auth/seed"

# Helper: wrap a `geode query` invocation with a common prelude.
geode_q() {
    local q="$1"
    timeout 8s "${GEODE_BIN}" query \
        --server "127.0.0.1:${PORT}" \
        --insecure-tls-skip-verify \
        -U geode -P "${ADMIN_PASSWORD}" \
        --timeout "${CLIENT_TIMEOUT}" \
        "${q}"
}

# Seed the graph to match the shape `count-nodes` runs against in
# shell_comprehensive_tests.yml (5 Person+Company nodes after the preceding
# create-*-nodes tests). Exact number doesn't matter — what matters is
# that the unlabeled `MATCH (n)` path is exercised against non-zero nodes.
if ! geode_q "CREATE (alice:Person {name: 'Alice'}), (bob:Person {name: 'Bob'}), (carol:Person {name: 'Carol'}), (techcorp:Company {name: 'TechCorp'}), (financeinc:Company {name: 'FinanceInc'})" > /dev/null 2>&1; then
    echo "FAIL: seed CREATE failed — is the server responding?" >&2
    sed 's/^/  srv| /' "${SRV_LOG}" >&2 || true
    exit 1
fi

# Optional background-load mode: starts a parallel writer that churns
# CREATE statements to force WAL/checkpoint contention while the count
# queries run. This mirrors the scenario that produces the 1-in-4 flake
# in a full geodetestlab run. Disabled by default so the test stays
# stable on quiet dev boxes; opt-in by setting BACKGROUND_LOAD=1.
LOAD_PIDS=()
if [ "${BACKGROUND_LOAD:-0}" = "1" ]; then
    NUM_LOADERS="${NUM_LOADERS:-8}"
    echo "[count-nodes-flake-pin] BACKGROUND_LOAD=1: spawning ${NUM_LOADERS} concurrent writers"
    # Pre-seed a bulk of nodes so the unlabeled full-scan has real work to do.
    # The triage symptom depends on iteration time growing with live node
    # count; 5 nodes isn't enough to expose the WAL-contention stall even
    # with writers thrashing. Bulk seeding to ~5k matches the geodetestlab
    # cumulative state better.
    BULK_SEED="${BULK_SEED:-2000}"
    echo "[count-nodes-flake-pin] bulk-seeding ${BULK_SEED} nodes to simulate cumulative harness state"
    SEED_Q="UNWIND range(1, ${BULK_SEED}) AS i CREATE (:Bulk {id: i})"
    geode_q "${SEED_Q}" > /dev/null 2>&1 || true

    for k in $(seq 1 "${NUM_LOADERS}"); do
        (
            while :; do
                geode_q "CREATE (:Load {ts: timestamp()})" > /dev/null 2>&1 || true
            done
        ) &
        LOAD_PIDS+=("$!")
    done
fi

# Extend cleanup to reap any load processes we started.
if [ "${#LOAD_PIDS[@]}" -gt 0 ]; then
    cleanup() {
        for lp in "${LOAD_PIDS[@]}"; do
            kill -9 "${lp}" 2>/dev/null || true
        done
        if [ -n "${SRV_PID:-}" ]; then
            kill -9 "${SRV_PID}" 2>/dev/null || true
            wait "${SRV_PID}" 2>/dev/null || true
        fi
        rm -rf "${DATA_DIR}"
    }
    trap cleanup EXIT
fi

echo "[count-nodes-flake-pin] seeded 5 nodes; hammering count query ${RUNS}x"

FAIL=0
MAX_MS=0
MIN_MS=99999999

for i in $(seq 1 "${RUNS}"); do
    RUN_OUT="$(mktemp "${DATA_DIR}/run_${i}.out.XXXXXX")"
    RUN_ERR="$(mktemp "${DATA_DIR}/run_${i}.err.XXXXXX")"

    START_NS=$(date +%s%N)
    geode_q "MATCH (n) RETURN count(n) AS c" > "${RUN_OUT}" 2> "${RUN_ERR}"
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
        FAIL=1
    fi

    # Every successful run must report a positive count. With BACKGROUND_LOAD=1
    # the count grows over time (extra `:Load` + `:Bulk` nodes are created
    # continuously), so we only enforce "non-zero integer" correctness. Without
    # background load we enforce exactly 5. Skip the correctness check on
    # already-failed runs — RC!=0 means stdout is empty and grep WILL fail,
    # producing a redundant WRONG_COUNT signal.
    if [ "${RC}" -eq 0 ]; then
        if [ "${BACKGROUND_LOAD:-0}" = "1" ]; then
            if ! grep -qE '"c":\s*[1-9][0-9]*' "${RUN_OUT}"; then
                STATUS="${STATUS} WRONG_COUNT"
                FAIL=1
            fi
        else
            if ! grep -qE '"c":\s*5|"c":5' "${RUN_OUT}"; then
                STATUS="${STATUS} WRONG_COUNT"
                FAIL=1
            fi
        fi
    fi

    echo "[count-nodes-flake-pin] run ${i}/${RUNS}: ${ELAPSED_MS}ms ${STATUS}"

    if [ "${RC}" -ne 0 ] || [ "${ELAPSED_MS}" -gt "${PASS_MS}" ]; then
        echo "  stdout:" >&2
        sed 's/^/    | /' "${RUN_OUT}" >&2 || true
        echo "  stderr:" >&2
        sed 's/^/    | /' "${RUN_ERR}" >&2 || true
    fi
done

echo "[count-nodes-flake-pin] summary: min=${MIN_MS}ms max=${MAX_MS}ms across ${RUNS} runs"

if [ "${FAIL}" -ne 0 ]; then
    echo "FAIL: at least one of ${RUNS} consecutive count(n) runs exceeded ${PASS_MS}ms or errored." >&2
    echo "      This is the pre-fix flake class: unlabeled MATCH(n) RETURN count(n) full-scan" >&2
    echo "      fallback occasionally stalls behind a WAL/checkpoint writer." >&2
    echo "      Fix: add count-only pushdown in src/execution/match_operations.zig." >&2
    exit 1
fi

echo "PASS: ${RUNS}/${RUNS} count(n) runs under ${PASS_MS}ms each"
exit 0
