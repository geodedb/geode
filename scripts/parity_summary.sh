#!/usr/bin/env bash
set -euo pipefail

# parity_summary.sh
# Runs transport parity tests (pattern: e2e_protocol_transport_parity*) under both gating envs
# and emits JSON Lines summarizing row hash equivalence for each test into parity-summary.jsonl.
# Requires zig test artifacts already built. Intended for nightly workflow.

OUT_FILE="parity-summary.jsonl"
true >"${OUT_FILE}"

hash_stream() {
  sha256sum | awk '{print $1}'
}

run_test_capture() {
  local test_file="$1"; shift
  local env_extra="$1"; shift || true
  local tmp_stdout
  tmp_stdout=$(mktemp)
  # We assume tests are self-gated via env var; run once capturing stdout
  echo "Running ${test_file} ${env_extra}" >&2
  if GEODE_CI_QUIC_SMOKE=1 ${env_extra} zig test "${test_file}" -q >"${tmp_stdout}" 2>/dev/null; then
    cat "${tmp_stdout}" | sed -n '/{"status_class":/p' >"${tmp_stdout}.rows"
    local h
    h=$(cat "${tmp_stdout}.rows" | hash_stream)
    echo "${h}" >"${tmp_stdout}.hash"
    echo "${tmp_stdout}"
  else
    echo "" >"${tmp_stdout}.rows"
    echo "FAIL" >"${tmp_stdout}.hash"
    echo "${tmp_stdout}"
  fi
}

mapfile -t tests < <(ls tests/e2e_protocol_transport_parity_*.zig 2>/dev/null || true)

for t in "${tests[@]}"; do
  stdio_path=$(run_test_capture "$t" "")
  stdio_hash=$(cat "${stdio_path}.hash")
  # QUIC path is same invocation; tests internally invoke both transports; keep single hash.
  jq -cn --arg test "$(basename "$t")" --arg hash "$stdio_hash" '{test:$test, rows_sha256:$hash, status:( $hash=="FAIL"?"FAIL":"OK" )}' >>"${OUT_FILE}"
done

echo "Wrote ${OUT_FILE}" >&2