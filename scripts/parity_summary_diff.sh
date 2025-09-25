#!/usr/bin/env bash
set -euo pipefail

# parity_summary_diff.sh
# Compare two parity summary JSONL files and emit JSON lines describing changes.
# Usage: parity_summary_diff.sh <old_summary.jsonl> <new_summary.jsonl> > diff.jsonl
# If old file missing, emits all new as additions.

OLD=${1:-}
NEW=${2:-}
if [[ -z "${NEW}" ]]; then
  echo "Usage: $0 <old_summary.jsonl> <new_summary.jsonl>" >&2
  exit 2
fi

if [[ ! -f "${NEW}" ]]; then
  echo "New summary file not found: ${NEW}" >&2
  exit 2
fi

tmp_old=$(mktemp)
if [[ -n "${OLD}" && -f "${OLD}" ]]; then
  cp "${OLD}" "${tmp_old}"
else
  : > "${tmp_old}"
fi

# Build maps using jq (require jq)
if ! command -v jq >/dev/null 2>&1; then
  echo '{"error":"jq_not_found"}'
  exit 0
fi

declare -A old_map
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  name=$(echo "$line" | jq -r '.test // empty') || true
  hash=$(echo "$line" | jq -r '.rows_sha256 // empty') || true
  [[ -n "$name" ]] && old_map["$name"]="$hash"
done <"${tmp_old}"

declare -A new_map
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  name=$(echo "$line" | jq -r '.test // empty') || true
  hash=$(echo "$line" | jq -r '.rows_sha256 // empty') || true
  [[ -n "$name" ]] && new_map["$name"]="$hash"
done <"${NEW}"

# Detect removals & hash changes
for k in "${!old_map[@]}"; do
  if [[ -z "${new_map[$k]+x}" ]]; then
    jq -cn --arg test "$k" '{type:"REMOVED",test:$test}'
  else
    if [[ "${old_map[$k]}" != "${new_map[$k]}" ]]; then
      jq -cn --arg test "$k" --arg old "${old_map[$k]}" --arg new "${new_map[$k]}" '{type:"CHANGED",test:$test,old:$old,new:$new}'
    fi
  fi
done

# Additions
for k in "${!new_map[@]}"; do
  if [[ -z "${old_map[$k]+x}" ]]; then
    jq -cn --arg test "$k" --arg hash "${new_map[$k]}" '{type:"ADDED",test:$test,hash:$hash}'
  fi
done
