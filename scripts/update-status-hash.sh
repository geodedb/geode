#!/usr/bin/env bash
set -euo pipefail
# Recomputes sha256 of status.json and updates the STATUS_JSON_SHA256 marker in GAP_ANALYSIS.md
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS_JSON="$ROOT_DIR/status.json"
GAP_FILE="$ROOT_DIR/docs/GAP_ANALYSIS.md"

if [[ ! -f "$STATUS_JSON" ]]; then
  echo "status.json not found; run canaryscan first" >&2
  exit 1
fi

hash=$(sha256sum "$STATUS_JSON" | awk '{print $1}')

# Use sed to replace the marker line
if grep -q 'STATUS_JSON_SHA256:' "$GAP_FILE"; then
  sed -i "s/<!-- STATUS_JSON_SHA256: .*/<!-- STATUS_JSON_SHA256: $hash -->/" "$GAP_FILE"
else
  # Insert after first heading if marker missing
  awk -v h="$hash" 'NR==1{print;print"\n<!-- STATUS_JSON_SHA256: " h " -->";next}1' "$GAP_FILE" > "$GAP_FILE.tmp" && mv "$GAP_FILE.tmp" "$GAP_FILE"
fi

echo "Updated hash marker to $hash"
