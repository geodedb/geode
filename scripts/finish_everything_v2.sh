#!/usr/bin/env bash
# finish_everything_v2.sh -- complete the converge-tagged-pins task end-to-end
# using the LATEST tagged versions of every devnw/zig sibling. Targets
# geode-client-zig@v0.2.3 (v0.2.2 was the prior interim tag).

set -euo pipefail

GEODE="$HOME/src/devnw/codepros/geode/geode"
CLIENT="$HOME/src/devnw/codepros/geode/geode-client-zig"
SIBLINGS="$HOME/src/devnw/zig"
GLOBAL_CACHE="${ZIG_GLOBAL_CACHE_DIR:-$HOME/.cache/zig}/p"
NEW_CLIENT_TAG="v0.2.3"
LOG="[finish-v2]"

log() { echo "$LOG $*"; }

update_manifest_to_latest_tags() {
  local manifest="$1"
  log "updating $manifest"
  mapfile -t pin_lines < <(grep -nE '\.url = "git\+https://gitlab\.com/devnw/zig/[a-z][-a-z0-9_]*' "$manifest")
  for line in "${pin_lines[@]}"; do
    local lineno="${line%%:*}"
    local text="${line#*:}"
    local pkg
    pkg=$(echo "$text" | sed -E 's|.*/devnw/zig/([a-z][-a-z0-9_]*)(\.git)?#.*|\1|')
    local oldref
    oldref=$(echo "$text" | sed -E 's|.*#([^"]+)".*|\1|')
    [ -z "$pkg" ] || [ -z "$oldref" ] && continue
    local sib_dir="$SIBLINGS/$pkg"
    [ ! -d "$sib_dir/.git" ] && continue
    local newtag
    newtag=$(git -C "$sib_dir" describe --tags --abbrev=0 2>/dev/null || true)
    [ -z "$newtag" ] && continue
    [ "$oldref" = "$newtag" ] && continue

    local newurl="git+https://gitlab.com/devnw/zig/${pkg}.git#${newtag}"
    log "  $pkg: $oldref -> $newtag"
    local newhash
    newhash=$(zig fetch "$newurl" 2>/dev/null | head -1 | awk '{print $1}')
    [ -z "$newhash" ] && { log "    zig fetch failed for $pkg@$newtag"; return 1; }

    python3 - "$manifest" "$lineno" "$newurl" "$newhash" <<'PY'
import re, sys
path = sys.argv[1]
lineno = int(sys.argv[2])
newurl = sys.argv[3]
newhash = sys.argv[4]
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
}

log "=== step 0: purge stale caches ==="
[ -d "$GLOBAL_CACHE" ] && find "$GLOBAL_CACHE" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
[ -d "$GEODE/zig-pkg" ] && find "$GEODE/zig-pkg" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
[ -d "$CLIENT/zig-pkg" ] && find "$CLIENT/zig-pkg" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

log "=== step 1: geode-client-zig ==="
cd "$CLIENT"
update_manifest_to_latest_tags "$CLIENT/build.zig.zon"

if git diff --quiet build.zig.zon 2>/dev/null && git diff --cached --quiet build.zig.zon 2>/dev/null; then
  log "client manifest unchanged"
else
  git add build.zig.zon
  git commit -m "chore(deps): converge to latest tagged versions (post-rebump2)" \
             -m "Refreshes every devnw/zig dep to its latest annotated tag after the second-pass coordinated bump completed across the stack. Includes quic@v0.1.16 (carrying the macOS cross-compile fix natively), otel@v0.1.3 (BSP race fix), tls@v0.1.6, slog@v0.1.5, thread-pool@v0.2.4, etc."
fi

if ! git tag -l "$NEW_CLIENT_TAG" | grep -qx "$NEW_CLIENT_TAG"; then
  git tag -a "$NEW_CLIENT_TAG" -m "release $NEW_CLIENT_TAG"
fi

log "pushing client HEAD + $NEW_CLIENT_TAG"
if git push --atomic origin HEAD "$NEW_CLIENT_TAG" 2>/tmp/finish-v2-push-err; then
  :
elif grep -q "Everything up-to-date" /tmp/finish-v2-push-err 2>/dev/null; then
  git push origin "$NEW_CLIENT_TAG" || true
else
  cat /tmp/finish-v2-push-err
  exit 1
fi

log "=== step 2: geode pins ==="
cd "$GEODE"
update_manifest_to_latest_tags "$GEODE/build.zig.zon"

client_url="git+https://gitlab.com/devnw/codepros/geode/geode-client-zig.git#${NEW_CLIENT_TAG}"
client_hash=$(zig fetch "$client_url" 2>&1 | head -1 | awk '{print $1}')
[ -z "$client_hash" ] && { log "ERROR: zig fetch for geode-client-zig@$NEW_CLIENT_TAG returned no hash"; exit 1; }
log "client hash: $client_hash"

python3 - "$GEODE/build.zig.zon" "$client_hash" "$NEW_CLIENT_TAG" <<'PY'
import re, sys
path = sys.argv[1]
new_hash = sys.argv[2]
new_tag = sys.argv[3]
src = open(path).read()
pat = re.compile(
    r"(\.geode_client_zig\s*=\s*\.\{[^{}]*?\.url\s*=\s*\")[^\"]+(\"[^{}]*?\.hash\s*=\s*\")[^\"]+(\")",
    re.DOTALL,
)
def _sub(m):
    return (
        m.group(1)
        + f"git+https://gitlab.com/devnw/codepros/geode/geode-client-zig.git#{new_tag}"
        + m.group(2)
        + new_hash
        + m.group(3)
    )
new, n = pat.subn(_sub, src, count=1)
if n == 0:
    sys.exit("could not match .geode_client_zig block in " + path)
open(path, "w").write(new)
PY
log "geode build.zig.zon updated"

log "=== step 3: retire vendored patch ==="
python3 - "$GEODE/.goreleaser.yaml" <<'PY'
import re, sys
path = sys.argv[1]
src = open(path).read()
pat = re.compile(
    r"(?:\s*#[^\n]*\n)*\s*-\s*bash scripts/apply-vendored-patches\.sh\n",
)
new = pat.sub("\n", src, count=1)
open(path, "w").write(new)
PY

python3 - "$GEODE/Makefile" <<'PY'
import re, sys
path = sys.argv[1]
src = open(path).read()
pat = re.compile(
    r"# Apply vendored patches.*?\.PHONY: apply-vendored-patches\napply-vendored-patches:\n\t@bash scripts/apply-vendored-patches\.sh\n\n",
    re.DOTALL,
)
src = pat.sub("", src, count=1)
src = src.replace("cross-macos-x86_64: apply-vendored-patches", "cross-macos-x86_64:")
src = src.replace("cross-macos-arm64: apply-vendored-patches", "cross-macos-arm64:")
open(path, "w").write(src)
PY

[ -d "$GEODE/patches" ] && rm -rf "$GEODE/patches"
[ -f "$GEODE/scripts/apply-vendored-patches.sh" ] && rm -f "$GEODE/scripts/apply-vendored-patches.sh"
log "patches retired"

log "=== step 4: build verification ==="
cd "$GEODE"
[ -d zig-pkg ] && find zig-pkg -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
[ -d zig-out ] && rm -rf zig-out

log "Linux native build..."
make build 2>&1 | tail -3
[ -f zig-out/bin/geode ] || { log "Linux build did NOT produce zig-out/bin/geode"; exit 1; }
log "Linux build OK ($(stat -c%s zig-out/bin/geode) bytes)"

log "macOS x86_64 cross-compile..."
make cross-macos-x86_64 2>&1 | tail -3
[ -f zig-out/macos-x86_64/bin/geode ] || { log "macOS x86_64 build did NOT produce a binary"; exit 1; }
log "macOS x86_64 build OK ($(stat -c%s zig-out/macos-x86_64/bin/geode) bytes)"

log "=== step 5: geode commit + push ==="
cd "$GEODE"
branch=chore/converge-tagged-pins-retire-quic-patch
if ! git show-ref --verify --quiet "refs/heads/$branch"; then
  git checkout -b "$branch"
else
  git checkout "$branch"
fi

git add build.zig.zon .goreleaser.yaml Makefile
git add -u patches scripts/apply-vendored-patches.sh 2>/dev/null || true

git commit -m "chore(deps): converge to tagged versions; retire quic macOS vendored patch" \
           -m "Bumps every devnw/zig dep to its latest annotated tag (uri@v0.1.4, json@v0.1.4, otel@v0.1.3, quic@v0.1.16, slog@v0.1.5, tls@v0.1.6, thread-pool@v0.2.4, etc.) and bumps geode-client-zig to ${NEW_CLIENT_TAG} (which itself pins quic@v0.1.16). With every dep aligned on a versioned tag, the diamond-dep risk drops to a single shared content hash per package across the build graph. Retires the vendored quic udp_transport.zig patch — quic@v0.1.16 carries the macOS cross-compile fix natively (fcntlCmd + std.c.{sendto,recvfrom}), so the workaround is no longer needed."

git push -u origin "$branch"

log "ALL DONE"
