#!/usr/bin/env bash
# bump_geode_to_tagged_pins.sh -- rewrite every devnw/zig/* dep in
# geode's build.zig.zon to point at that sibling's latest annotated
# git tag, and refresh `.hash` via `zig fetch`. After the multi-repo
# tagged-version convergence (see ~/src/devnw/zig/bump_to_versioned_tags.py),
# every sibling has a versioned tag; this script propagates those tags
# into geode so the diamond-dep risk drops to one shared content hash
# per package across the build graph.

set -uo pipefail

ROOT="${ROOT:-$HOME/src/devnw/codepros/geode/geode}"
SIBLINGS_ROOT="${SIBLINGS_ROOT:-$HOME/src/devnw/zig}"
MANIFEST="$ROOT/build.zig.zon"
LOG_PREFIX="[bump-geode-pins]"

mapfile -t pin_lines < <(grep -nE '\.url = "git\+https://gitlab\.com/devnw/zig/[a-z][-a-z0-9_]*' "$MANIFEST")

for line in "${pin_lines[@]}"; do
  lineno="${line%%:*}"
  text="${line#*:}"
  pkg=$(echo "$text" | sed -E 's|.*/devnw/zig/([a-z][-a-z0-9_]*)(\.git)?#.*|\1|')
  oldref=$(echo "$text" | sed -E 's|.*#([^"]+)".*|\1|')
  if [ -z "$pkg" ] || [ -z "$oldref" ]; then
    echo "$LOG_PREFIX skip line $lineno: could not parse"
    continue
  fi
  sib_dir="$SIBLINGS_ROOT/$pkg"
  if [ ! -d "$sib_dir/.git" ]; then
    echo "$LOG_PREFIX skip $pkg: no local clone at $sib_dir"
    continue
  fi
  newtag=$(git -C "$sib_dir" describe --tags --abbrev=0 2>/dev/null || true)
  if [ -z "$newtag" ]; then
    echo "$LOG_PREFIX skip $pkg: no tag in $sib_dir"
    continue
  fi
  if [ "$oldref" = "$newtag" ]; then
    echo "$LOG_PREFIX $pkg: already at $newtag"
    continue
  fi

  newurl="git+https://gitlab.com/devnw/zig/${pkg}.git#${newtag}"
  echo "$LOG_PREFIX $pkg: $oldref -> $newtag  (zig fetch...)"
  newhash=$(zig fetch "$newurl" 2>/dev/null | head -1 | awk '{print $1}')
  if [ -z "$newhash" ]; then
    echo "$LOG_PREFIX FAILED zig fetch for $pkg @ $newtag"
    continue
  fi

  python3 - "$MANIFEST" "$lineno" "$newurl" "$pkg" "$newhash" <<'PY'
import re, sys
path = sys.argv[1]
lineno = int(sys.argv[2])
newurl = sys.argv[3]
pkg = sys.argv[4]
newhash = sys.argv[5]
src = open(path).read().splitlines(keepends=True)
i = lineno - 1
src[i] = re.sub(r'\.url = "[^"]+"', f'.url = "{newurl}"', src[i])
for j in range(i + 1, min(i + 8, len(src))):
    if '.hash = "' in src[j]:
        src[j] = re.sub(r'\.hash = "[^"]+"', f'.hash = "{newhash}"', src[j])
        break
open(path, "w").writelines(src)
PY
done

echo "$LOG_PREFIX done. Run `make build` to validate."
