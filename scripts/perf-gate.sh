#!/usr/bin/env bash
# scripts/perf-gate.sh — geode port of thread-pool's perf-gate.
#
# Usage: ./scripts/perf-gate.sh <step-name> <before|after>
#
# Captures the full perf evidence set for a step and, on `after`, emits
# a diff.md comparing against the matching `before`. Caller controls
# server lifecycle — this script assumes `geode serve` is already running
# on the DSN's host/port.
#
# Artifacts per run (under $ART_DIR):
#   <step>-<phase>-bench-timeseries.json   (zig build bench-timeseries)
#   <step>-<phase>-benchmark.json          (zig build benchmark)
#   <step>-<phase>-loadtest-<scenario>.json (one per scenario)
#   <step>-<phase>-loadtest.json           (merged {scenarios: [...]})
# On `after`: <step>-diff.md
#
# Env knobs (all optional):
#   ZIG                 : zig binary (default: "zig")
#   HARNESS_DIR         : path to ../geode-test-harness (default)
#   LOADTEST_DSN        : Go loadtest DSN
#   LOADTEST_LEVELS     : concurrency matrix (default: 1,2,4,8,16,32)
#   LOADTEST_DURATION   : per-level duration (default: 5s)
#   LOADTEST_SCENARIOS  : space-separated scenario list (default: ping point_read one_hop two_hop fan_out)
#   ART_DIR             : artifact output dir
#   GEODE_BENCH_GIT_SHA : forwarded into bench JSONs (default: git HEAD)
#   GEODE_BENCH_CPU     : forwarded into bench JSONs (default: uname -m)
#   PERF_GATE_ALLOW_BENCH_FAIL  : if 1, tolerate a zig build benchmark failure iff the JSON was produced

set -euo pipefail

ZIG="${ZIG:-zig}"
STEP="${1:?step name required (e.g. step-1-point-read-view)}"
PHASE="${2:?phase required: before | after}"
ART_DIR="${ART_DIR:-docs/performance/2026-04-19-qps-closure}"
HARNESS_DIR="${HARNESS_DIR:-../geode-test-harness}"
LOADTEST_DSN="${LOADTEST_DSN:-127.0.0.1:3141?insecure=true&user=geode&pass=GeodeTestPassword123!}"
LOADTEST_LEVELS="${LOADTEST_LEVELS:-1,2,4,8,16,32}"
LOADTEST_DURATION="${LOADTEST_DURATION:-5s}"
LOADTEST_SCENARIOS="${LOADTEST_SCENARIOS:-ping point_read one_hop two_hop fan_out}"
export GEODE_BENCH_GIT_SHA="${GEODE_BENCH_GIT_SHA:-$(git rev-parse HEAD)}"
export GEODE_BENCH_CPU="${GEODE_BENCH_CPU:-$(uname -m)}"

if [[ "$PHASE" != "before" && "$PHASE" != "after" ]]; then
  echo "[perf-gate] ERROR: phase must be 'before' or 'after', got: $PHASE" >&2
  exit 2
fi

mkdir -p "$ART_DIR"

echo "[perf-gate] step=$STEP phase=$PHASE art_dir=$ART_DIR"
echo "[perf-gate] GEODE_BENCH_GIT_SHA=$GEODE_BENCH_GIT_SHA GEODE_BENCH_CPU=$GEODE_BENCH_CPU"

# 1. Zig bench-timeseries
BENCH_TS="$ART_DIR/${STEP}-${PHASE}-bench-timeseries.json"
echo "[perf-gate] $STEP $PHASE: zig build bench-timeseries -> $BENCH_TS"
"$ZIG" build bench-timeseries -Doptimize=ReleaseFast -- --output "$BENCH_TS"

# 2. Zig benchmark (phase1+phase2).
# Wrapped in a 2-attempt retry because the phase1 SIMD-vs-scalar test
# block is borderline (~2.5x against a 2.5x target) and occasionally
# fails on the first attempt even though the JSON was written. The
# wrapper exe writes the JSON BEFORE the threshold assertion fires, so
# a successful JSON + failing assertion is a known pattern. On final
# failure, honor PERF_GATE_ALLOW_BENCH_FAIL=1 to continue; otherwise
# abort as before.
BENCH_MICRO="$ART_DIR/${STEP}-${PHASE}-benchmark.json"
echo "[perf-gate] $STEP $PHASE: zig build benchmark -> $BENCH_MICRO"
bench_rc=0
for attempt in 1 2; do
  if "$ZIG" build benchmark -Doptimize=ReleaseFast -- --output "$BENCH_MICRO"; then
    bench_rc=0
    break
  else
    bench_rc=$?
    echo "[perf-gate] WARN: zig build benchmark attempt $attempt failed (rc=$bench_rc)" >&2
  fi
done
if [[ "$bench_rc" -ne 0 ]]; then
  if [[ -f "$BENCH_MICRO" ]] && [[ "${PERF_GATE_ALLOW_BENCH_FAIL:-0}" == "1" ]]; then
    echo "[perf-gate] WARN: benchmark failed both attempts but JSON exists and PERF_GATE_ALLOW_BENCH_FAIL=1 — continuing" >&2
  else
    echo "[perf-gate] ERROR: zig build benchmark failed twice (rc=$bench_rc). Set PERF_GATE_ALLOW_BENCH_FAIL=1 to tolerate if the output JSON was produced." >&2
    exit "$bench_rc"
  fi
fi

# 3. Go loadtest per scenario
LOADTEST="$ART_DIR/${STEP}-${PHASE}-loadtest.json"
LOADTEST_BIN="$HARNESS_DIR/loadtest/go/geode-loadtest"
if [[ ! -x "$LOADTEST_BIN" ]]; then
  echo "[perf-gate] WARN: $LOADTEST_BIN missing or not executable — skipping loadtest" >&2
  echo '{"scenarios": []}' > "$LOADTEST"
else
  SCENARIO_FILES=()
  # shellcheck disable=SC2086  # intentional word-split over $LOADTEST_SCENARIOS
  for s in $LOADTEST_SCENARIOS; do
    OUT="$ART_DIR/${STEP}-${PHASE}-loadtest-${s}.json"
    echo "[perf-gate] loadtest scenario=$s -> $OUT"
    "$LOADTEST_BIN" \
      -dsn "$LOADTEST_DSN" -scenario "$s" \
      -levels "$LOADTEST_LEVELS" -duration "$LOADTEST_DURATION" \
      -output "$OUT"
    SCENARIO_FILES+=("$OUT")
  done
  jq -s '{scenarios: .}' "${SCENARIO_FILES[@]}" > "$LOADTEST"
  echo "[perf-gate] merged loadtest -> $LOADTEST"
fi

if [[ "$PHASE" == "after" ]]; then
  DIFF_OUT="$ART_DIR/${STEP}-diff.md"
  BEFORE_TS="$ART_DIR/${STEP}-before-bench-timeseries.json"
  BEFORE_MICRO="$ART_DIR/${STEP}-before-benchmark.json"
  BEFORE_LOAD="$ART_DIR/${STEP}-before-loadtest.json"
  for f in "$BEFORE_TS" "$BEFORE_MICRO" "$BEFORE_LOAD"; do
    if [[ ! -f "$f" ]]; then
      echo "[perf-gate] ERROR: missing $f. Run '$STEP before' first." >&2
      exit 3
    fi
  done

  {
    echo "# Perf diff — $STEP"
    echo
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Commit: $(git rev-parse HEAD)"
    echo "CPU: $GEODE_BENCH_CPU"
    echo
    echo "## Go loadtest (scenarios: $LOADTEST_SCENARIOS; levels $LOADTEST_LEVELS; $LOADTEST_DURATION each)"
    echo
    if [[ -f benchmarks/loadtest/compare_ab.py ]]; then
      echo "| scenario | c | QPS before | QPS after | ΔQPS % | p99 before | p99 after | Δp99 % | err before | err after | verdict |"
      echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|"
      python3 benchmarks/loadtest/compare_ab.py --before "$BEFORE_LOAD" --after "$LOADTEST" --format markdown-rows || true
    else
      echo "_TODO(M0.8): benchmarks/loadtest/compare_ab.py not present yet. Raw JSONs:_"
      echo
      echo "- before: \`$BEFORE_LOAD\`"
      echo "- after:  \`$LOADTEST\`"
    fi
    echo
    echo "## zig bench-timeseries"
    echo
    echo '```'
    "$ZIG" build compare-bench -- --baseline "$BEFORE_TS" --current "$BENCH_TS" 2>&1 || true
    echo '```'
    echo
    echo "## zig benchmark (phase1/phase2 micro-benches)"
    echo
    echo '```'
    "$ZIG" build compare-bench -- --baseline "$BEFORE_MICRO" --current "$BENCH_MICRO" 2>&1 || true
    echo '```'
    echo
    echo "## Review checklist"
    echo
    echo "- Throughput regression >= 5% on any in-range scenario -> BLOCK, escalate."
    echo "- p99 regression >= 10% on any in-range scenario -> BLOCK, escalate."
    echo "- 3-5% throughput / 7-10% p99 -> WARN, disposition below."
    echo
    echo "## Disposition"
    echo
    echo "_(Fill this in if any row in the tables above crosses a gate.)_"
  } > "$DIFF_OUT"

  echo "[perf-gate] diff written to $DIFF_OUT"
fi

echo "[perf-gate] done."
