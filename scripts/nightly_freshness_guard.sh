#!/usr/bin/env bash
set -euo pipefail
# Warn if any CANARY UPDATED date is >= threshold_days (default 50) toward the 60-day strict freshness limit.
# Emits JSON summary: {"ok":bool,"threshold_days":N,"warn_days":M,"stale_candidates":[{"req":"REQ-GQL-010","updated":"2025-07-01","age_days":58},...],"scanned":count}
# ok=true if no stale_candidates; false otherwise (but still exit 0 for non-blocking nightly use unless --strict is given).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GAP_FILE="$ROOT_DIR/docs/GAP_ANALYSIS.md"
THRESHOLD=${THRESHOLD_DAYS:-50}
STRICT=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1;;
    --threshold=*) THRESHOLD="${arg#*=}";;
    *) echo "Unknown arg $arg" >&2; exit 2;;
  esac
done

if [[ ! -f "$GAP_FILE" ]]; then
  echo '{"ok":false,"error":"missing_gap_file"}'
  exit 0
fi

# Extract CANARY lines
mapfile -t lines < <(grep '^// CANARY:' "$GAP_FILE" || true)
now_epoch=$(date +%s)
warn_days=$((THRESHOLD))
warnings=()
scanned=0

for l in "${lines[@]}"; do
  scanned=$((scanned+1))
  # UPDATED=YYYY-MM-DD
  updated=$(echo "$l" | sed -n 's/.*UPDATED=\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\).*/\1/p')
  req=$(echo "$l" | sed -n 's/.*REQ=\(REQ-GQL-[0-9]\{3\}\).*/\1/p')
  if [[ -z "$updated" || -z "$req" ]]; then
    continue
  fi
  upd_epoch=$(date -d "$updated" +%s 2>/dev/null || echo 0)
  if [[ $upd_epoch -eq 0 ]]; then
    continue
  fi
  age_days=$(((now_epoch - upd_epoch)/86400))
  if (( age_days >= warn_days )); then
    warnings+=("$req::$updated::$age_days")
  fi
done

ok=true
(( ${#warnings[@]} > 0 )) && ok=false

# Emit JSON
printf '{"ok":%s,"threshold_days":%d,"warn_days":%d,"stale_candidates":[' "$ok" "$THRESHOLD" "$warn_days"
first=1
for w in "${warnings[@]}"; do
  IFS='::' read -r r d a <<<"$w"
  if [[ $first -eq 0 ]]; then printf ','; fi
  printf '{"req":"%s","updated":"%s","age_days":%s}' "$r" "$d" "$a"
  first=0
done
printf '],"scanned":%d}' "$scanned"

# Non-strict always exit 0
if (( STRICT==1 )) && ! $ok; then exit 1; else exit 0; fi
