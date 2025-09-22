#!/usr/bin/env bash
set -euo pipefail
# Computes added / removed REQ identifiers between previous and current status JSON snapshots.
# Usage: scripts/governance-delta.sh [--prev status_prev.json] [--curr status.json]
# Emits JSON: {"ok":bool,"added":[...],"removed":[...],"prev_count":N,"curr_count":M}
# ok==true if removed is empty (pure additions); false if any removals.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREV="$ROOT_DIR/status_prev.json"
CURR="$ROOT_DIR/status.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prev) PREV="$2"; shift 2;;
    --curr) CURR="$2"; shift 2;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done

if [[ ! -f "$PREV" ]]; then
  echo "Previous status file not found: $PREV" >&2
  echo '{"ok":false,"error":"missing_prev"}'
  exit 0
fi
if [[ ! -f "$CURR" ]]; then
  echo "Current status file not found: $CURR" >&2
  echo '{"ok":false,"error":"missing_curr"}'
  exit 0
fi

# Extract REQ ids from JSON lines (assuming file is a JSON object or array; we fallback to grep)
extract_ids() {
  local file="$1"
  # Try jq if present for robustness; fallback to regex scan.
  if command -v jq >/dev/null 2>&1; then
    jq -r '..|objects|select(.REQ!=null)|.REQ' "$file" 2>/dev/null | sort -u
  else
    grep -Eo 'REQ-GQL-[0-9]+' "$file" | sort -u
  fi
}

mapfile -t prev_ids < <(extract_ids "$PREV") || true
mapfile -t curr_ids < <(extract_ids "$CURR") || true

# Use associative arrays for set arithmetic
declare -A prev_set curr_set
for id in "${prev_ids[@]}"; do prev_set["$id"]=1; done
for id in "${curr_ids[@]}"; do curr_set["$id"]=1; done

added=()
removed=()
for id in "${curr_ids[@]}"; do [[ -z ${prev_set[$id]:-} ]] && added+=("$id") || true; done
for id in "${prev_ids[@]}"; do [[ -z ${curr_set[$id]:-} ]] && removed+=("$id") || true; done

# JSON encode arrays
json_array() {
  local -n arr=$1
  local first=1
  printf '['
  for v in "${arr[@]}"; do
    if [[ $first -eq 0 ]]; then printf ','; fi
    printf '"%s"' "$v"
    first=0
  done
  printf ']'
}

ok=true
[[ ${#removed[@]} -gt 0 ]] && ok=false

printf '{"ok":%s,"added":' "$ok"
json_array added
printf ',"removed":'
json_array removed
printf ',"prev_count":%d,"curr_count":%d}' "${#prev_ids[@]}" "${#curr_ids[@]}"
