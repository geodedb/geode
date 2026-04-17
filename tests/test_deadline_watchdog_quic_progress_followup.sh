#!/bin/bash
# FOLLOW-UP (not blocking #746 primary fix): pin the missing `.on_progress`
# hook in the QUIC path's executeQueryOnConnection + QuicProtocolAdapter.
#
# CANARY: REQ=REQ-CLI-DEADLINE-WATCHDOG-002; FEATURE="QueryDeadlineWatchdog"; ASPECT=QuicProgressHookFollowup; STATUS=IMPL; OWNER=cli; UPDATED=2026-04-16
#
# Per docs/audit/bugfix-deadline-watchdog-triage.md §8:
#   "wire `touchActiveQueryDeadlineWatchdog` into the QUIC send/recv path —
#    the `QuicProtocolAdapter` in `executeQueryOnConnection` (lines
#    2496-2520) and the handshake `writeProtoMessageViaZigClient` /
#    `readProtoMessageViaZigClient` calls that bookend it.  Without this,
#    post-fix a slow query will still false-timeout."
#
# The grep-based assertion below pins that `on_progress` is wired at the
# QuicProtocolAdapter call site.  It is intentionally source-based rather
# than runtime-based because: (a) the primary #746 lifetime bug masks any
# slow-query behaviour until it is fixed; (b) we want this to flip green
# automatically as soon as the follow-up patch lands — no server-under-test
# plumbing required.
#
# Status gate:
#   GEODE_RUN_FOLLOWUP=1 forces the check to run.  Default in CI: SKIP.
#   This file intentionally does not feed into the #746 red→green cycle.

set -u

if [ "${GEODE_RUN_FOLLOWUP:-0}" != "1" ]; then
    echo "SKIP: follow-up test for QUIC .on_progress — set GEODE_RUN_FOLLOWUP=1 to run"
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MAIN_ZIG="${REPO_ROOT}/src/cli/main.zig"

# The exact adapter construction that is currently missing on_progress.
# Allow either spelling (on_progress = touch... or on_progress: touch...) as
# long as it is within ~40 lines of the QuicProtocolAdapter definition.
if ! awk '/const QuicProtocolAdapter = struct/,/^    var protocol_client/' "${MAIN_ZIG}" \
    | grep -q "on_progress"; then
    echo "FAIL: src/cli/main.zig: QuicProtocolAdapter block does NOT wire .on_progress." >&2
    echo "      Secondary bug from #746 triage is still open." >&2
    exit 1
fi

echo "PASS: QuicProtocolAdapter wires on_progress"
exit 0
