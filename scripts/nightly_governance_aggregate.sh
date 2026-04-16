#!/usr/bin/env bash
set -euo pipefail
# Aggregate nightly governance signals into a single JSON object.
# Runs: governance-delta, nightly_freshness_guard (pre-warn), governance-dry-run.
# Output JSON structure:
# {
#   "ok": bool,                # true if all sub-tools ok
#   "timestamp": "ISO8601",
#   "delta": { ... },
#   "freshness": { ... },
#   "governance": { ... },     # dry-run enriched governance-check output
#   "errors": [ ... ]
# }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

delta_json=$("$ROOT_DIR/scripts/governance-delta.sh" || echo '{"ok":false,"error":"delta_failed"}')
fresh_json=$("$ROOT_DIR/scripts/nightly_freshness_guard.sh" || echo '{"ok":false,"error":"freshness_failed"}')
gov_json=$("$ROOT_DIR/scripts/governance-dry-run.sh" || echo '{"ok":false,"error":"governance_failed"}')

errors=()
echo "$delta_json" | grep -q '"ok":false' && errors+=(delta)
echo "$fresh_json" | grep -q '"ok":false' && errors+=(freshness)
echo "$gov_json" | grep -q '"ok":false' && errors+=(governance)

ok=true
if (( ${#errors[@]} > 0 )); then ok=false; fi

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

printf '{"ok":%s,"timestamp":"%s","delta":%s,"freshness":%s,"governance":%s,"errors":[' "$ok" "$ts" "$delta_json" "$fresh_json" "$gov_json"
if (( ${#errors[@]} > 0 )); then
  for i in "${!errors[@]}"; do
    [[ $i -gt 0 ]] && printf ','
    printf '"%s"' "${errors[$i]}"
  done
fi
printf ']}'
