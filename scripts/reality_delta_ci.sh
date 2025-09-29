#!/usr/bin/env bash
# Reality Delta CI Gate
# Verifies that IMPLEMENTATION_REALITY.md reflects current CANARY evidence counts.
# Fails if counts diverge or canaryscan verification fails.
#
# Requirements:
#   - canaryscan binary at ./bin/canaryscan
#   - jq installed (for JSON parsing)
#
# Exit codes:
#   0  OK
#   1  Missing dependency / misuse
#   2  Divergent counts (REALITY_DELTA_FAIL)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -x "${ROOT}/bin/canaryscan" ]; then
  echo "ERROR: canaryscan binary missing at ${ROOT}/bin/canaryscan" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not installed; required for reality delta check" >&2
  exit 1
fi

echo "[reality-delta] Running canaryscan verify..." >&2
"${ROOT}/bin/canaryscan" --root "${ROOT}" \
  --out "${ROOT}/status.json" --csv "${ROOT}/status.csv" \
  --verify "${ROOT}/docs/GAP_ANALYSIS.md" --strict

total=$(jq '[.requirements[].features[]] | length' "${ROOT}/status.json")
tested=$(jq '[.requirements[].features[] | select(.status=="TESTED")] | length' "${ROOT}/status.json")
benched=$(jq '[.requirements[].features[] | select(.status=="BENCHED")] | length' "${ROOT}/status.json")

# Extract documented counts (first occurrence patterns).
doc_total=$(grep -Eo '([0-9]+) features' "${ROOT}/docs/IMPLEMENTATION_REALITY.md" | head -1 | awk '{print $1}' || echo 0)
doc_tested=$(grep -Eo '[0-9]+ TESTED' "${ROOT}/docs/IMPLEMENTATION_REALITY.md" | head -1 | awk '{print $1}' || echo 0)
doc_benched=$(grep -Eo '[0-9]+ BENCHED' "${ROOT}/docs/IMPLEMENTATION_REALITY.md" | head -1 | awk '{print $1}' || echo 0)

if [ "${total}" != "${doc_total}" ] || [ "${tested}" != "${doc_tested}" ] || [ "${benched}" != "${doc_benched}" ]; then
  echo "REALITY_DELTA_FAIL counts diverge: status.json (total=${total} tested=${tested} benched=${benched}) doc (total=${doc_total} tested=${doc_tested} benched=${doc_benched})" >&2
  exit 2
fi

echo "REALITY_DELTA_OK total=${total} tested=${tested} benched=${benched}" >&2
exit 0
