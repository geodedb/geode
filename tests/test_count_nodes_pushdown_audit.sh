#!/bin/bash
# Source-audit reproduction test for the unlabeled `MATCH (n) RETURN count(n)`
# flake triaged in docs/audit/bugfix-shell-count-nodes-triage.md.
#
# CANARY: REQ=REQ-PERF-COUNT-NODES-PUSHDOWN; FEATURE="UnlabeledMatchCountPushdown"; ASPECT=SourceAudit; STATUS=TESTED; TEST=tests/test_count_nodes_pushdown_audit.sh; OWNER=execution; UPDATED=2026-04-16
#
# Purpose: pin the *shape* of the fix. The unit test
# `tests/test_count_nodes_pushdown_perf.zig` proves the pushdown is WIRED
# (the full-scan counter stays 0 and the query finishes in microseconds).
# This test asserts the fix actually LIVES in the right place —
# `src/execution/match_operations.zig` — as either:
#
#   a) a named helper function `countNodesFastPath` (or any identifier
#      matching `countNode(s?)FastPath` case-insensitively), OR
#   b) a well-commented marker `COUNT_PUSHDOWN` / `count pushdown` /
#      `count-only pushdown` that a future reader can grep for.
#
# Why this is valuable: the fix could technically be implemented in a
# different file (planner.zig, execution.zig, etc.) and still pass the
# runtime test by luck. Pinning it in match_operations.zig near the
# existing labeled fast-path at :1726-1735 keeps the two branches
# side-by-side and maintainable — that's the shape the triage prescribes.
#
# Red state before fix: neither marker exists in match_operations.zig.
# Green state after fix: at least one marker exists.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET="${REPO_ROOT}/src/execution/match_operations.zig"

if [ ! -f "${TARGET}" ]; then
    echo "FAIL: target file not found: ${TARGET}" >&2
    exit 2
fi

echo "[count-pushdown-audit] inspecting ${TARGET}"

FOUND=0
EVIDENCE=""

# Marker shape (a): named helper function. Accept either `countNodesFastPath`
# or `countNodeFastPath` in case the fixer names it slightly differently;
# case-insensitive.
if grep -Eni '\bcountNodes?FastPath\b' "${TARGET}" > /dev/null 2>&1; then
    FOUND=1
    EVIDENCE="$(grep -Eni '\bcountNodes?FastPath\b' "${TARGET}" | head -3)"
fi

# Marker shape (b): explicit comment marker the triage recommends.
if grep -Eni 'COUNT_PUSHDOWN|count[ -]only pushdown|count pushdown' "${TARGET}" > /dev/null 2>&1; then
    FOUND=1
    EVIDENCE="${EVIDENCE}
$(grep -Eni 'COUNT_PUSHDOWN|count[ -]only pushdown|count pushdown' "${TARGET}" | head -3)"
fi

# Marker shape (c): direct call to countNodesForGraph from match_operations.zig.
# This is the strongest signal — the fix delegates to the store counter.
if grep -Eni '\.countNodesForGraph\s*\(' "${TARGET}" > /dev/null 2>&1; then
    FOUND=1
    EVIDENCE="${EVIDENCE}
$(grep -Eni '\.countNodesForGraph\s*\(' "${TARGET}" | head -3)"
fi

if [ "${FOUND}" -eq 0 ]; then
    echo "FAIL: no count-pushdown marker found in match_operations.zig." >&2
    echo "      The fix must live near the labeled fast-path at :1726-1735" >&2
    echo "      and be discoverable via one of:" >&2
    echo "        - a function named countNodesFastPath (or countNodeFastPath)" >&2
    echo "        - a comment containing COUNT_PUSHDOWN / 'count pushdown' / 'count-only pushdown'" >&2
    echo "        - a call to store.countNodesForGraph(...)" >&2
    echo "      Triage: docs/audit/bugfix-shell-count-nodes-triage.md" >&2
    exit 1
fi

echo "[count-pushdown-audit] marker(s) present:"
echo "${EVIDENCE}" | sed 's/^/  | /'
echo "PASS: count-pushdown marker present in match_operations.zig"
exit 0
