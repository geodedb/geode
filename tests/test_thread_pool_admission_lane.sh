#!/bin/bash
# Static source-audit test for GitLab #751 — asserts the fix shape is in place
# in src/transport/thread_pool.zig and src/server/main.zig.
#
# CANARY: REQ=REQ-PERF-SESSION-ADMISSION-002; FEATURE="ConnectionAdmissionLaneWiring"; ASPECT=SourceAudit; STATUS=IMPL; TEST=test_thread_pool_admission_lane; OWNER=transport; UPDATED=2026-04-16
#
# Per triage docs/audit/bugfix-session-contention-triage.md the fix is:
#   1. Add a `submitDefault` (or equivalent name) helper to ThreadPool that
#      routes work items to the default lane (`.lane = .default`) so the
#      15 default-lane workers handle connection admission rather than
#      the single blocking-lane worker.
#   2. Switch the accept-loop submit in src/server/main.zig (~L900) to use
#      the new default-lane submit.
#
# This is a deliberately blunt grep-based test — the goal is to catch any
# future regression that re-introduces .lane = .blocking for the admission
# path. It does NOT try to parse Zig; it just checks that the required
# token pattern is present in the required file.
#
# Pre-fix: the existing pool only exposes `submit` (hardcoded .blocking)
# and `submitBlocking`. No `submitDefault` exists → grep A fails. Red.
# Post-fix: `submitDefault` exists, routes to `.lane = .default`, and
# main.zig calls it → all three asserts pass. Green.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

POOL_FILE="${REPO_ROOT}/src/transport/thread_pool.zig"
MAIN_FILE="${REPO_ROOT}/src/server/main.zig"

if [ ! -f "${POOL_FILE}" ]; then
    echo "FAIL: expected ${POOL_FILE} to exist" >&2
    exit 2
fi
if [ ! -f "${MAIN_FILE}" ]; then
    echo "FAIL: expected ${MAIN_FILE} to exist" >&2
    exit 2
fi

FAIL=0

# --- Assertion A: submitDefault function exists in thread_pool.zig ---
#
# We look for a `pub fn submitDefault` signature in the pool wrapper.
# Any naming convention that the fixer adopts needs to match this
# grep; if they pick a different name (e.g. `submitAdmission`) the
# triage doc's fix-shape section lists both options and we bias toward
# submitDefault per the user's bug-fix test plan.
if grep -qE 'pub fn submitDefault\s*\(' "${POOL_FILE}"; then
    echo "[lane-audit] OK: thread_pool.zig exports pub fn submitDefault(...)"
else
    echo "[lane-audit] MISSING: thread_pool.zig does not export pub fn submitDefault(...)" >&2
    FAIL=1
fi

# --- Assertion B: submitDefault body routes to .lane = .default ---
#
# The function must actually use the default lane. We extract the ~20
# lines following the declaration and grep for `.lane = .default` within
# that window. Catches a bug where the fixer adds the function but
# forgets to flip the lane.
if grep -qE 'pub fn submitDefault' "${POOL_FILE}"; then
    # Extract 20 lines starting from the submitDefault declaration.
    BODY="$(awk '/pub fn submitDefault/,/^\s*\}\s*$/' "${POOL_FILE}" | head -30)"
    if printf '%s\n' "${BODY}" | grep -qE '\.lane\s*=\s*\.default'; then
        echo "[lane-audit] OK: submitDefault body routes to .lane = .default"
    else
        echo "[lane-audit] MISSING: submitDefault body does not contain .lane = .default" >&2
        echo "  body grep target:" >&2
        printf '%s\n' "${BODY}" | sed 's/^/    | /' >&2
        FAIL=1
    fi
else
    # Already reported by assertion A; mark fail and keep going.
    FAIL=1
fi

# --- Assertion C: main.zig accept-loop calls submitDefault (or equivalent) ---
#
# The accept loop at src/server/main.zig:~900 currently does:
#     if (!pool.submit(work_item)) { ... }
# The fix switches this to submitDefault. We enforce that *some* call
# site in main.zig invokes pool.submitDefault(...); this catches the
# case where the new API lands in thread_pool.zig but the accept loop
# is never updated to use it.
if grep -qE 'pool\.submitDefault\s*\(' "${MAIN_FILE}"; then
    echo "[lane-audit] OK: main.zig accept loop calls pool.submitDefault(...)"
else
    echo "[lane-audit] MISSING: main.zig does not call pool.submitDefault(...)" >&2
    echo "  context grep (line ~900):" >&2
    awk 'NR>=890 && NR<=915' "${MAIN_FILE}" | sed 's/^/    | /' >&2
    FAIL=1
fi

if [ "${FAIL}" -ne 0 ]; then
    echo "FAIL: admission-lane source audit failed. See triage" >&2
    echo "      docs/audit/bugfix-session-contention-triage.md for the fix shape." >&2
    exit 1
fi

echo "PASS: admission-lane wiring present in thread_pool.zig and main.zig"
exit 0
