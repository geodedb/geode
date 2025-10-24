#!/usr/bin/env bash
set -euo pipefail
# Wrapper that runs the primary governance check but never returns non-zero to callers.
# It annotates the JSON with a dry_run flag and (if failing) an errors[] array.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_SCRIPT="$ROOT_DIR/scripts/governance-check.sh"
if [[ ! -x "$CHECK_SCRIPT" ]]; then
  echo '{"ok":false,"error":"missing_governance_script","dry_run":true}'
  exit 0
fi

# Capture output & exit code
set +e
RAW_OUTPUT=$($CHECK_SCRIPT 2>&1)
CODE=$?
set -e

# If output already JSON with ok field, append dry_run + original_exit
if echo "$RAW_OUTPUT" | grep -q '"ok"'; then
  # naive append: insert before final }
  if [[ $CODE -eq 0 ]]; then
    echo "$RAW_OUTPUT" | sed 's/}$/,"dry_run":true,"original_exit":0}/'
  else
    echo "$RAW_OUTPUT" | sed 's/}$/,"dry_run":true,"original_exit":'$CODE',"errors":["governance_check_failed"]}/'
  fi
else
  # Fallback generic wrapper
  if [[ $CODE -eq 0 ]]; then
    printf '{"ok":true,"note":"non_json_output","raw":"%s","dry_run":true,"original_exit":0}' "$(echo "$RAW_OUTPUT" | sed 's/"/\\"/g')"
  else
    printf '{"ok":false,"note":"non_json_output","raw":"%s","dry_run":true,"original_exit":%d,"errors":["governance_check_failed"]}' "$(echo "$RAW_OUTPUT" | sed 's/"/\\"/g')" "$CODE"
  fi
fi
# Always exit 0
exit 0
