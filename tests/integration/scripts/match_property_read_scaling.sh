#!/usr/bin/env bash
# Reproduction test for the MATCH-by-property write-lock serialization bug.
#
# Triage:  docs/audit/LOADTEST_REPORT_2026_04_18_v0.3.5.md
# Issue:   src/server/quic_connection_handler.zig:2302-2325 calls
#          graph_store.acquireGraphWriteLock() unconditionally for every
#          non-EXPLAIN query, so read-only MATCH-by-property traffic
#          serializes behind the exclusive writer lock.
#
# Expected loadtest behaviour:
#   before fix:     QPS at c=4 < QPS at c=1 (observed: 32.3 -> 30.3, ratio 0.94x;
#                   original triage captured the worst case at 28.6 -> 18.0, ratio 0.63x)
#   after  fix:     QPS at c=4 > QPS at c=1 * 1.1 (reads no longer serialize)
#   aspirational:   ratio >= 1.5x once the plan-cache lock at
#                   src/server/query_plan_cache.zig:451 is narrowed and the
#                   response poll loop at src/server/main.zig:815 is
#                   parallelized.  Tracked as a follow-up to GAP-0752.
#
# Progression history:
#   * GAP-0752 (landed): handler takes SHARED read lock on non-mutating queries.
#   * GAP-0753 (landed): handler releases the lock before execute — lock hold
#                        scope bounded by snapshot capture (<10 ms).
#   * GAP-0754 (landed): graph_store global allocator swapped from
#                        DebugAllocator (serialized on internal mutex) to
#                        smp_allocator (sharded per-core, thread-local fast
#                        path) — removes the next hot-path bottleneck.
#   * GAP-0755 (landed): per-query arena pool in src/server/query_arena.zig
#                        wired into both QUIC and gRPC handlers. Each query
#                        borrows an arena from the pool; on release the arena
#                        is reset (retain_capacity) and returned, so scratch
#                        allocations do not round-trip through smp_allocator
#                        across queries. The scratch allocator is installed
#                        as a thread-local hint; executor scratch sites can
#                        opt in via match_operations.scratchAllocatorOr()
#                        without threading a parameter through the ~7k-line
#                        executor.  Opportunistic adoption of the hint by
#                        internal ArrayList/dupe sites is a follow-up; the
#                        plumbing is in place so those sites are a 1-line
#                        change each.
#   * Follow-ups:        plan-cache wiring into MATCH path (GAP-0756),
#                        multi-core poll dispatch (GAP-0757). The 1.1x floor
#                        remains conservative until those land; on a quiet
#                        host the arena pool alone lifts the ratio into the
#                        1.0-1.3x band, but single-digit-QPS workloads are
#                        still bottlenecked downstream by parse+plan cost
#                        and single-thread QUIC poll dispatch.
#
# This script:
#   1. Builds the geode server if not already built.
#   2. Spawns a throwaway server on an ephemeral port with a fresh data-dir.
#   3. Runs `geode-loadtest -scenario point_read -levels 1,4 -duration 3s`.
#   4. Parses the JSON report with `jq` and asserts
#        qps[c=4] > 1.1 * qps[c=1]    (hard failure)
#      and warns (exit 0, logged) if
#        1.1x <= ratio < 1.5x         (partial scaling — the follow-up work
#                                       above has not landed yet)
#
# Exit codes:
#   0   — assertion holds (scaling observed, fix is in place; may include warn band)
#   1   — assertion fails (bug still present, reads serializing)
#   2   — infrastructure failure (binary missing, server wouldn't start, etc.)
#
# The assertion is the bug-detector.  This script MUST exit non-zero
# against commit 0704009b.  The 1.1x floor is intentionally conservative:
# it catches the regression (pre-fix ratio is 0.6-0.94x, so even host noise
# will not push a regressed build above 1.1x) while remaining achievable in
# the current handler-lock-only fix.  Raise this bar to 1.5x only after the
# plan-cache / poll-loop follow-up work lands.

set -u
set -o pipefail

GEODE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HARNESS_REPO="$(cd "${GEODE_REPO}/../geode-test-harness" && pwd)"
LOADTEST_BIN="${HARNESS_REPO}/loadtest/go/geode-loadtest"
GEODE_BIN="${GEODE_REPO}/zig-out/bin/geode"

log()  { echo "[match-read-scaling] $*" >&2; }
fail() { log "FAIL: $*"; exit 1; }
infra_fail() { log "INFRA FAIL: $*"; exit 2; }

[ -x "${GEODE_BIN}" ]     || infra_fail "geode binary missing at ${GEODE_BIN}; run \`make build\` first"
[ -x "${LOADTEST_BIN}" ]  || infra_fail "loadtest binary missing at ${LOADTEST_BIN}; build it with \`cd ${HARNESS_REPO} && make loadtest-go\`"
command -v jq >/dev/null || infra_fail "jq not installed"

# Pick an ephemeral-but-predictable port above 30000 to avoid collision.
PORT="$(( ( RANDOM % 10000 ) + 40000 ))"
DATA_DIR="$(mktemp -d /tmp/geode_match_read_scaling_XXXXXX)"
LOG_FILE="$(mktemp /tmp/geode_match_read_scaling_server_XXXXXX.log)"
REPORT_FILE="$(mktemp /tmp/geode_match_read_scaling_report_XXXXXX.json)"

ADMIN_USER="${GEODE_ADMIN_USERNAME:-geode}"
# Provide an explicit GEODE_ADMIN_PASSWORD so the admin user is created
# without the force-reset-on-first-login flag that comes with an
# auto-generated password (see src/security/user_management.zig:570-591).
ADMIN_PASS="${GEODE_ADMIN_PASSWORD:-match-read-scaling-pw}"

SERVER_PID=""
cleanup() {
    if [ -n "${SERVER_PID}" ] && kill -0 "${SERVER_PID}" 2>/dev/null; then
        kill "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
    fi
    rm -rf "${DATA_DIR}" "${LOG_FILE}" "${REPORT_FILE}" 2>/dev/null || true
}
trap cleanup EXIT

log "starting geode server on 127.0.0.1:${PORT} (data=${DATA_DIR})"
GEODE_ADMIN_USERNAME="${ADMIN_USER}" GEODE_ADMIN_PASSWORD="${ADMIN_PASS}" \
    "${GEODE_BIN}" serve \
        --listen "127.0.0.1:${PORT}" \
        --data-dir "${DATA_DIR}" \
        --log-level warn \
        >"${LOG_FILE}" 2>&1 &
SERVER_PID=$!

# Wait up to 10s for the server to accept queries.
READY=0
for _ in $(seq 1 20); do
    sleep 0.5
    if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
        log "server died during startup; log tail:"
        tail -30 "${LOG_FILE}" >&2 || true
        infra_fail "server exited before ready"
    fi
    # Very small probe: if the server is listening we're good enough.
    if ss -Hln "sport = :${PORT}" 2>/dev/null | grep -q UDP; then
        READY=1
        break
    fi
    # Fallback: /proc/net/udp
    if grep -iq ":$(printf '%04X' "${PORT}")" /proc/net/udp /proc/net/udp6 2>/dev/null; then
        READY=1
        break
    fi
done
[ "${READY}" = "1" ] || infra_fail "server never bound ${PORT}"
log "server ready"

# Build the DSN the loadtest expects.
DSN="127.0.0.1:${PORT}?insecure=true&user=${ADMIN_USER}&pass=${ADMIN_PASS}"

# Run the point_read scenario at concurrency 1 and 4 for a short burst.
# A 3-second-per-level window is long enough for the handler-lock effect
# to dominate noise while keeping the test inside CI budgets.
log "running loadtest: scenario=point_read levels=1,4 duration=3s"
if ! "${LOADTEST_BIN}" \
        -dsn "${DSN}" \
        -scenario point_read \
        -levels 1,4 \
        -duration 3s \
        -output "${REPORT_FILE}" >&2; then
    log "loadtest command failed; server log tail:"
    tail -30 "${LOG_FILE}" >&2 || true
    infra_fail "loadtest exited non-zero"
fi

[ -s "${REPORT_FILE}" ] || infra_fail "loadtest produced empty report"

QPS_C1="$(jq -r '.levels[] | select(.concurrency == 1) | .qps' "${REPORT_FILE}")"
QPS_C4="$(jq -r '.levels[] | select(.concurrency == 4) | .qps' "${REPORT_FILE}")"
ERR_C1="$(jq -r '.levels[] | select(.concurrency == 1) | .error_rate' "${REPORT_FILE}")"
ERR_C4="$(jq -r '.levels[] | select(.concurrency == 4) | .error_rate' "${REPORT_FILE}")"

if [ -z "${QPS_C1}" ] || [ -z "${QPS_C4}" ]; then
    log "report did not contain both concurrency levels; full report:"
    cat "${REPORT_FILE}" >&2 || true
    infra_fail "missing QPS entries"
fi

# Reject the run if either level suffered catastrophic errors — we want
# to compare throughput of successful queries, not error-rate artifacts.
if awk -v e="${ERR_C1}" 'BEGIN { exit !(e > 0.10) }'; then
    infra_fail "c=1 error rate ${ERR_C1} > 0.10 — rerun"
fi
if awk -v e="${ERR_C4}" 'BEGIN { exit !(e > 0.10) }'; then
    infra_fail "c=4 error rate ${ERR_C4} > 0.10 — rerun"
fi

RATIO="$(awk -v a="${QPS_C4}" -v b="${QPS_C1}" 'BEGIN { if (b <= 0) print 0; else printf "%.3f", a / b }')"
log "point_read  qps@c=1=${QPS_C1}  qps@c=4=${QPS_C4}  ratio=${RATIO}x"

# Contract: with the fix, c=4 should deliver at least 1.1x the throughput
# of c=1 on the point_read scenario.  This is the floor — the aspirational
# target is 1.5x, unlocked by narrowing the plan-cache lock
# (src/server/query_plan_cache.zig:451) and parallelizing the response
# poll loop (src/server/main.zig:815).  See the header comment for detail.
HARD_FLOOR=1.1
WARN_CEILING=1.5

if awk -v r="${RATIO}" -v f="${HARD_FLOOR}" 'BEGIN { exit !(r < f) }'; then
    log "BUG REPRODUCED: point_read did not scale from c=1 to c=4"
    log "  qps@c=1  = ${QPS_C1}"
    log "  qps@c=4  = ${QPS_C4}"
    log "  ratio    = ${RATIO}x  (required: > ${HARD_FLOOR}x)"
    log "  Handler is serializing reads through the exclusive writer lock."
    log "  See src/server/quic_connection_handler.zig:2317-2329."
    cat "${REPORT_FILE}" >&2 || true
    exit 1
fi

if awk -v r="${RATIO}" -v w="${WARN_CEILING}" 'BEGIN { exit !(r < w) }'; then
    log "PASS (warn band): point_read scales ${RATIO}x (hard floor ${HARD_FLOOR}x cleared)"
    log "  aspirational target is ${WARN_CEILING}x — gated on plan-cache lock"
    log "  narrowing (src/server/query_plan_cache.zig:451) and poll-loop"
    log "  parallelization (src/server/main.zig:815).  Tracked as follow-up"
    log "  to GAP-0752."
    exit 0
fi

log "PASS: point_read scales ${RATIO}x from c=1 to c=4 (target ${WARN_CEILING}x met)"
exit 0
