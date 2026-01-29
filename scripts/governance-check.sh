#!/usr/bin/env bash
set -euo pipefail

# governance-check.sh
# Performs repository governance integrity validation:
# 1. Single H1 per governance-tracked doc (NEXT.md, GAP_ANALYSIS.md, REQUIREMENTS.md, IMPLEMENTATION_REALITY.md)
# 2. NEXT.md freshness (modified within last 24h)
# 3. status.json hash matches embedded marker in GAP_ANALYSIS.md
# 4. Strict CANARY verification
# 5. Emits JSON summary for tooling

DOCS=(docs/NEXT.md docs/GAP_ANALYSIS.md docs/REQUIREMENTS.md docs/IMPLEMENTATION_REALITY.md)

fail() { echo "{\"ok\":false,\"error\":$1}" >&2; exit 2; }

# 1. Single H1 check
for f in "${DOCS[@]}"; do
  h1_count=$(grep -E '^# ' "$f" | wc -l | tr -d ' ')
  if [ "$h1_count" -ne 1 ]; then
    fail "\"MultipleOrMissingH1:$f:$h1_count\""
  fi
done

# 2. NEXT.md freshness (mtime within 24h)
now_epoch=$(date +%s)
next_mtime=$(stat -c %Y docs/NEXT.md)
age_sec=$(( now_epoch - next_mtime ))
if [ "$age_sec" -gt 86400 ]; then
  fail "\"NEXTStale:age_sec=$age_sec\""
fi

# 3. status.json hash stamp
if [ ! -f status.json ]; then
  fail '"Missing status.json"'
fi
hash_actual=$(sha256sum status.json | awk '{print $1}')
hash_embedded=$(grep -E '<!-- STATUS_JSON_SHA256:' docs/GAP_ANALYSIS.md | sed -E 's/.*STATUS_JSON_SHA256: ([0-9a-f]{64}).*/\1/')
if [ -z "$hash_embedded" ]; then
  fail '"MissingHashMarker"'
fi
if [ "$hash_actual" != "$hash_embedded" ]; then
  fail "\"HashMismatch:embedded=$hash_embedded actual=$hash_actual\""
fi

# 4. Strict CANARY verify
./bin/canaryscan --root . --verify docs/GAP_ANALYSIS.md --strict >/dev/null || fail '"CanaryVerifyFailed"'

# 5. Emit JSON success
echo "{\"ok\":true,\"hash\":\"$hash_actual\",\"next_age_sec\":$age_sec}"
