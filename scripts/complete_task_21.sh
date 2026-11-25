#!/usr/bin/env bash
# complete_task_21.sh -- complete the geode pin convergence after the
# multi-repo tagged-version bump.
#
# Steps:
#  1. Bump + tag geode-client-zig (quic pin already updated to v0.1.15
#     in its build.zig.zon by an earlier in-conversation edit).
#  2. Update geode's geode_client_zig pin to v0.2.2.
#  3. Retire the vendored quic patch (patches/, script, .goreleaser
#     hook, Makefile prereq) — quic@v0.1.15 carries the macOS fix
#     natively.
#  4. Verify Linux + macOS builds.
#  5. Commit + push geode on a fix branch.
#
# Failure handling: stops at the first failed sub-step.

set -euo pipefail

GEODE="$HOME/src/devnw/codepros/geode/geode"
CLIENT="$HOME/src/devnw/codepros/geode/geode-client-zig"
LOG="[complete-task-21]"

# ----------------------------------------------------------------------
# 1. geode-client-zig: build + commit + tag + push
# ----------------------------------------------------------------------
echo "$LOG === step 1: geode-client-zig ==="
cd "$CLIENT"
[ -d zig-pkg ] && find zig-pkg -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
echo "$LOG verifying client build..."
zig build 2>&1 | tail -5

if git diff --quiet build.zig.zon; then
  echo "$LOG client manifest already committed (or unchanged)"
else
  git add build.zig.zon
  git commit -m "chore(deps): bump quic to v0.1.15 (macOS fix included)" \
             -m "Tracks the converged tagged-version chain across the devnw/zig stack and pulls in upstream quic@b73a804's macOS cross-compile fix (std.c.F shape divergence + std.c.{sendto,recvfrom} replacing dropped std.posix wrappers)."
fi

if ! git tag -l v0.2.2 | grep -q v0.2.2; then
  git tag -a v0.2.2 -m "release v0.2.2"
fi
git push --atomic origin HEAD v0.2.2 || git push origin v0.2.2

# ----------------------------------------------------------------------
# 2. geode: bump geode_client_zig pin to v0.2.2
# ----------------------------------------------------------------------
echo "$LOG === step 2: geode geode_client_zig pin ==="
cd "$GEODE"
new_hash=$(zig fetch "git+https://gitlab.com/devnw/codepros/geode/geode-client-zig.git#v0.2.2" 2>&1 | head -1 | awk '{print $1}')
if [ -z "$new_hash" ]; then
  echo "$LOG ERROR: zig fetch for geode-client-zig@v0.2.2 returned no hash"; exit 1
fi
echo "$LOG new hash: $new_hash"

python3 - "$GEODE/build.zig.zon" "$new_hash" <<'PY'
import re, sys
path = sys.argv[1]
new_hash = sys.argv[2]
src = open(path).read()
pat = re.compile(
    r"(\.geode_client_zig\s*=\s*\.\{[^{}]*?\.url\s*=\s*\")[^\"]+(\"[^{}]*?\.hash\s*=\s*\")[^\"]+(\"[^{}]*?\})",
    re.DOTALL,
)
def _sub(m):
    return (
        m.group(1)
        + "git+https://gitlab.com/devnw/codepros/geode/geode-client-zig.git#v0.2.2"
        + m.group(2)
        + new_hash
        + m.group(3)
    )
new, n = pat.subn(_sub, src, count=1)
if n == 0:
    sys.exit("could not match .geode_client_zig block in " + path)
open(path, "w").write(new)
PY

# ----------------------------------------------------------------------
# 3. Retire the vendored quic patch
# ----------------------------------------------------------------------
echo "$LOG === step 3: retire vendored patch ==="

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
src = src.replace(
    "cross-macos-x86_64: apply-vendored-patches",
    "cross-macos-x86_64:",
)
src = src.replace(
    "cross-macos-arm64: apply-vendored-patches",
    "cross-macos-arm64:",
)
open(path, "w").write(src)
PY

rm -rf "$GEODE/patches"
rm -f "$GEODE/scripts/apply-vendored-patches.sh"

# ----------------------------------------------------------------------
# 4. Verify build (Linux native + macOS cross-compile)
# ----------------------------------------------------------------------
echo "$LOG === step 4: verify builds ==="
cd "$GEODE"
[ -d zig-pkg ] && find zig-pkg -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
[ -d zig-out ] && rm -rf zig-out

echo "$LOG Linux native build..."
make build 2>&1 | tail -5
[ -f zig-out/bin/geode ] || { echo "$LOG Linux build did NOT produce zig-out/bin/geode"; exit 1; }

echo "$LOG macOS x86_64 cross-compile..."
make cross-macos-x86_64 2>&1 | tail -5
[ -f zig-out/macos-x86_64/bin/geode ] || { echo "$LOG macOS x86_64 build did NOT produce a binary"; exit 1; }

# ----------------------------------------------------------------------
# 5. Commit + push geode
# ----------------------------------------------------------------------
echo "$LOG === step 5: commit + push geode ==="
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
           -m "Bumps every devnw/zig dep to its new tagged version (uri@v0.1.2, json@v0.1.2, otel@v0.1.1, quic@v0.1.15, slog@v0.1.3, tls@v0.1.4, thread-pool@v0.2.2, etc.) and bumps geode-client-zig to v0.2.2 which itself pins quic@v0.1.15. With every dep aligned on a versioned tag, the diamond-dep risk drops to a single shared content hash per package across the build graph. Retires the vendored quic udp_transport.zig patch (patches/, scripts/apply-vendored-patches.sh, .goreleaser.yaml hook, Makefile prereq) — quic@v0.1.15 carries the macOS fix natively (fcntlCmd + std.c.{sendto,recvfrom}) so the workaround is no longer needed."

git push -u origin "$branch"

echo "$LOG ALL DONE"
