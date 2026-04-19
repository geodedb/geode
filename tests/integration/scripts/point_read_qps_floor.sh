#!/usr/bin/env bash
# point_read_qps_floor.sh — Task M1.4 integration guard
#
# Enforces a hard floor on post-PointReadView (M1.2 + M1.3) QPS for the
# `point_read` scenario at c=4. Baseline on `perf/qps-closure-2026-04-19`
# as of commit 62536b9e is 30.0 QPS. Floor is set below that (25) to
# leave room for normal run-to-run variance.
#
# The plan's long-term target (`c=4 QPS >= 100`) is NOT met by M1.4
# alone — PointReadView contributed only a ~10% QPS bump. Raise this
# floor once the M1.1 profile identifies and fixes the remaining
# bottleneck.
#
# Usage (typically from the loadtest-regression CI job):
#   FLOOR_QPS=25 ./tests/integration/scripts/point_read_qps_floor.sh \
#       ../geode-test-harness/reports/loadtest_point_read.json
#
# Env:
#   FLOOR_QPS : hard floor for c=4 QPS (default 25)

set -euo pipefail

FLOOR_QPS="${FLOOR_QPS:-25}"
INPUT="${1:?path to loadtest_point_read.json required}"

if [[ ! -f "$INPUT" ]]; then
    echo "point_read_qps_floor: input not found: $INPUT" >&2
    exit 2
fi

QPS="$(jq '.levels[] | select(.concurrency==4) | .qps' "$INPUT")"
if [[ -z "$QPS" ]]; then
    echo "point_read_qps_floor: no c=4 level in $INPUT" >&2
    exit 3
fi

# bc is available in most CI images; fallback to python if not.
if command -v bc >/dev/null 2>&1; then
    below="$(echo "$QPS < $FLOOR_QPS" | bc -l)"
else
    below="$(python3 -c "import sys; q=float(sys.argv[1]); f=float(sys.argv[2]); print(1 if q < f else 0)" "$QPS" "$FLOOR_QPS")"
fi

if [[ "$below" == "1" ]]; then
    echo "FAIL: point_read c=4 QPS $QPS below floor $FLOOR_QPS" >&2
    exit 1
fi

echo "OK: point_read c=4 QPS $QPS >= $FLOOR_QPS"
