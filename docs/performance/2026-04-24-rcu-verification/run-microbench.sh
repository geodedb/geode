#!/usr/bin/env bash
# RCU merge_prop_index microbench A/B runner.
#
# Drives the perf-branch `bench-merge-prop-lookup` exe across a thread
# sweep with alternating modes to defeat thermal / load drift. Captures
# every `NATIVE_BENCH` line into raw/per-round files and emits a
# medians.tsv summary the report can ingest.
#
# Usage:  ./run-microbench.sh <bench-exe-path> <out-dir>

set -euo pipefail

BENCH="${1:?bench exe path required}"
OUT="${2:?output dir required}"
THREAD_COUNTS=(1 4 8 16 32 56)
MODES=(baseline rcu)
ROUNDS=5

mkdir -p "${OUT}/raw"
RAW_LOG="${OUT}/raw/microbench-raw.log"
SUMMARY="${OUT}/medians.tsv"

: > "${RAW_LOG}"
printf 'mode\tthreads\tops_per_sec_median\telapsed_ms_median\trounds\n' > "${SUMMARY}"

for t in "${THREAD_COUNTS[@]}"; do
  # Warmup: discard one round per mode at this thread count.
  for m in "${MODES[@]}"; do
    "${BENCH}" "${m}" "${t}" 2>&1 \
      | grep '^NATIVE_BENCH' \
      | sed "s/^/WARMUP /" \
      | tee -a "${RAW_LOG}" >/dev/null || true
  done

  # Measured rounds: alternate modes to interleave drift across the pair.
  for r in $(seq 1 "${ROUNDS}"); do
    for m in "${MODES[@]}"; do
      line=$("${BENCH}" "${m}" "${t}" 2>&1 | grep '^NATIVE_BENCH' || echo "FAIL mode=${m} threads=${t}")
      printf 'ROUND %d %s\n' "${r}" "${line}" | tee -a "${RAW_LOG}" >/dev/null
    done
  done

  # Compute medians per mode at this thread count (median = sorted middle).
  for m in "${MODES[@]}"; do
    ops_med=$(grep "^ROUND " "${RAW_LOG}" \
      | grep "mode=${m} threads=${t} " \
      | sed -E 's/.*ops_per_sec=([0-9.]+).*/\1/' \
      | sort -g \
      | awk 'BEGIN{n=0} {a[++n]=$0} END{print a[int((n+1)/2)]}')
    el_med=$(grep "^ROUND " "${RAW_LOG}" \
      | grep "mode=${m} threads=${t} " \
      | sed -E 's/.*elapsed_ms=([0-9.]+).*/\1/' \
      | sort -g \
      | awk 'BEGIN{n=0} {a[++n]=$0} END{print a[int((n+1)/2)]}')
    printf '%s\t%d\t%s\t%s\t%d\n' "${m}" "${t}" "${ops_med}" "${el_med}" "${ROUNDS}" >> "${SUMMARY}"
  done
done

echo
echo "=== ${SUMMARY} ==="
column -t -s "$(printf '\t')" "${SUMMARY}"
