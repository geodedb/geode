#!/usr/bin/env bash
set -euo pipefail
# Capture current adaptive clamp variance benchmark metrics and append to history file.
# Creates benchmarks/history directory if missing.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIST_DIR="$ROOT_DIR/benchmarks/history"
HIST_FILE="$HIST_DIR/adaptive_clamp.jsonl"

mkdir -p "$HIST_DIR"

BENCH_BIN="$ROOT_DIR/zig-out/bin/bench_bias_clamp_variance"
if [[ ! -x "$BENCH_BIN" ]]; then
  echo "Benchmark binary not found at $BENCH_BIN. Building..." >&2
  (cd "$ROOT_DIR" && zig build bench_bias_clamp_variance || zig build test) >/dev/null 2>&1 || true
fi

if [[ ! -x "$BENCH_BIN" ]]; then
  echo "ERROR: Unable to locate or build bench_bias_clamp_variance binary" >&2
  exit 1
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
out="$($BENCH_BIN)" || {
  echo "Benchmark execution failed" >&2
  exit 2
}

# Inject timestamp field while preserving original JSON keys (simple sed insert after opening brace)
augmented="$(echo "$out" | sed -E 's/^\{/{"timestamp":"'$ts'",/')"
echo "$augmented" >> "$HIST_FILE"
echo "Appended benchmark line to $HIST_FILE" >&2
