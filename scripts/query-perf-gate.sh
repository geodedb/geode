#!/usr/bin/env bash
# scripts/query-perf-gate.sh — A/B driver for the query-path benches (M4.2).
#
# Usage: ./scripts/query-perf-gate.sh <step-name> <before|after>
#
# Runs parser / planner / executor-match / executor-mutation benches,
# writes per-layer JSONs plus a merged <step>-<phase>-query-all.json.
# On `after`, invokes `zig build compare-bench` against the matching
# `before` merged artifact and writes <step>-diff.md.
#
# Artifacts per run (under $ART_DIR):
#   <step>-<phase>-parser.json
#   <step>-<phase>-planner.json
#   <step>-<phase>-executor-match.json
#   <step>-<phase>-executor-mutation.json
#   <step>-<phase>-query-all.json           (merged rows)
# On `after`: <step>-diff.md
#
# Env knobs:
#   ZIG                 : zig binary (default: "zig")
#   ART_DIR             : artifact dir (default: docs/performance/2026-04-20-query-bench)
#   GEODE_BENCH_GIT_SHA : forwarded into bench JSONs (default: git HEAD)
#   GEODE_BENCH_CPU     : forwarded into bench JSONs (default: uname -m)
#   QUERY_BENCHES       : space-separated subset of {parser planner executor-match executor-mutation}
#                         (default: all four).

set -euo pipefail

ZIG="${ZIG:-zig}"
STEP="${1:?step name required}"
PHASE="${2:?phase required: before|after}"
ART_DIR="${ART_DIR:-docs/performance/2026-04-20-query-bench}"
BENCHES="${QUERY_BENCHES:-parser planner executor-match executor-mutation}"

export GEODE_BENCH_GIT_SHA="${GEODE_BENCH_GIT_SHA:-$(git rev-parse HEAD)}"
export GEODE_BENCH_CPU="${GEODE_BENCH_CPU:-$(uname -m)}"

if [[ "$PHASE" != "before" && "$PHASE" != "after" ]]; then
  echo "[query-perf-gate] ERROR: phase must be 'before' or 'after'" >&2
  exit 2
fi

mkdir -p "$ART_DIR"

for bench in $BENCHES; do
  OUT="$ART_DIR/${STEP}-${PHASE}-${bench}.json"
  echo "[query-perf-gate] $STEP $PHASE: zig build bench-query-$bench -> $OUT"
  "$ZIG" build "bench-query-$bench" -Doptimize=ReleaseFast -- --output "$OUT"
done

# Merge the per-layer JSONs into one <step>-<phase>-query-all.json. If
# QUERY_BENCHES is a subset, jq only merges the ones that exist.
MERGED="$ART_DIR/${STEP}-${PHASE}-query-all.json"
MERGE_INPUTS=()
for bench in $BENCHES; do
  MERGE_INPUTS+=("$ART_DIR/${STEP}-${PHASE}-${bench}.json")
done

jq -s '{
  generated_at_unix_s: .[0].generated_at_unix_s,
  rows: (map(.rows) | add)
}' "${MERGE_INPUTS[@]}" > "$MERGED"
echo "[query-perf-gate] merged -> $MERGED"

if [[ "$PHASE" == "after" ]]; then
  DIFF_OUT="$ART_DIR/${STEP}-diff.md"
  BEFORE_MERGED="$ART_DIR/${STEP}-before-query-all.json"
  if [[ ! -f "$BEFORE_MERGED" ]]; then
    echo "[query-perf-gate] ERROR: missing $BEFORE_MERGED (run 'before' phase first)" >&2
    exit 3
  fi
  {
    echo "# Query perf diff — $STEP"
    echo
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Commit: $(git rev-parse HEAD)"
    echo "CPU: $GEODE_BENCH_CPU"
    echo "Benches: $BENCHES"
    echo
    echo '## zig build compare-bench output'
    echo
    echo '```'
    "$ZIG" build compare-bench -- --baseline "$BEFORE_MERGED" --current "$MERGED" 2>&1 || true
    echo '```'
    echo
    echo '## Review checklist'
    echo
    echo '- `throughput_*` regression ≥ 5% on any scenario/size → BLOCK'
    echo '- `latency_*_ns_p50` rise ≥ 10% on any scenario/size → BLOCK'
    echo '- `alloc_bytes_per_op` rise ≥ 10% → WARN, disposition below'
    echo
    echo '## Disposition'
    echo
    echo '_(Fill this in if any row in the compare-bench output crosses a gate.)_'
  } > "$DIFF_OUT"
  echo "[query-perf-gate] diff -> $DIFF_OUT"
fi

echo "[query-perf-gate] done."
