#!/usr/bin/env bash
# =============================================================================
# update_dep_hashes.sh — Update all dependency hashes in build.zig.zon
#
# Reads each dependency's git URL from build.zig.zon, fetches the latest
# commit from the local sibling repo (or remote), computes the zig package
# hash via `zig fetch`, and updates build.zig.zon in place.
#
# Usage:
#   ./scripts/update_dep_hashes.sh              # update all deps
#   ./scripts/update_dep_hashes.sh quic tls     # update specific deps
#
# Prerequisites:
#   - zig 0.15+ (for `zig fetch`)
#   - Local sibling repos at ../zig/<name> or ../../zig/<name>
#   - Run from the geode repo root
# =============================================================================
set -euo pipefail

GEODE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZON="$GEODE_ROOT/build.zig.zon"
ZIG_BASE="/home/benji/src/devnw/zig"
CLIENT_BASE="/home/benji/src/devnw/codepros/geode"

# Map of zon dep names → local repo paths and remote URL bases
declare -A REPO_MAP=(
  # Phase 1: Foundation
  [uri]="$ZIG_BASE/uri|git+https://gitlab.com/devnw/zig/uri.git"
  [yaml]="$ZIG_BASE/yaml|git+https://gitlab.com/devnw/zig/yaml.git"
  [toml]="$ZIG_BASE/toml|git+https://gitlab.com/devnw/zig/toml.git"
  [strings]="$ZIG_BASE/strings|git+https://gitlab.com/devnw/zig/strings.git"
  [repl]="$ZIG_BASE/repl|git+https://gitlab.com/devnw/zig/repl.git"
  [vulkan]="$ZIG_BASE/vulkan|git+https://gitlab.com/devnw/zig/vulkan.git"
  # Phase 2: Core
  [json]="$ZIG_BASE/json|git+https://gitlab.com/devnw/zig/json.git"
  [quic]="$ZIG_BASE/quic|git+https://gitlab.com/devnw/zig/quic.git"
  # Phase 3: Integration
  [slog]="$ZIG_BASE/slog|git+https://gitlab.com/devnw/zig/slog.git"
  [config]="$ZIG_BASE/config|git+https://gitlab.com/devnw/zig/config.git"
  # Phase 4: Application
  [cli]="$ZIG_BASE/cli|git+https://gitlab.com/devnw/zig/cli.git"
  [dns]="$ZIG_BASE/dns|git+https://gitlab.com/devnw/zig/dns.git"
  [thread_pool]="$ZIG_BASE/thread-pool|git+https://gitlab.com/devnw/zig/thread-pool.git"
  # Phase 5: Optional
  [mcp]="$ZIG_BASE/mcp|git+https://gitlab.com/devnw/zig/mcp.git"
  [protobuf]="$ZIG_BASE/protobuf|git+https://gitlab.com/devnw/zig/protobuf.git"
  [grpc_zig]="$ZIG_BASE/grpc-zig|git+https://gitlab.com/devnw/zig/grpc-zig.git"
  [geode_client_zig]="$CLIENT_BASE/geode-client-zig|git+https://gitlab.com/devnw/codepros/geode/geode-client-zig.git"
  # Phase 6: Extracted Core
  [uuid]="$ZIG_BASE/uuid|git+https://gitlab.com/devnw/zig/uuid.git"
  [wal]="$ZIG_BASE/wal|git+https://gitlab.com/devnw/zig/wal.git"
  [graph_storage]="$ZIG_BASE/graph-storage|git+https://gitlab.com/devnw/zig/graph-storage.git"
  [auth]="$ZIG_BASE/auth|git+https://gitlab.com/devnw/zig/auth.git"
  [timeseries]="$ZIG_BASE/timeseries|git+https://gitlab.com/devnw/zig/timeseries.git"
  [hnsw]="$ZIG_BASE/hnsw|git+https://gitlab.com/devnw/zig/hnsw.git"
  [fle]="$ZIG_BASE/fle|git+https://gitlab.com/devnw/zig/fle.git"
  # Phase 7
  [advanced_types]="$ZIG_BASE/advanced-types|git+https://gitlab.com/devnw/zig/advanced-types.git"
  [gql]="$ZIG_BASE/gql|git+https://gitlab.com/devnw/zig/gql.git"
  [metrics]="$ZIG_BASE/metrics|git+https://gitlab.com/devnw/zig/metrics.git"
  [concurrency]="$ZIG_BASE/concurrency|git+https://gitlab.com/devnw/zig/concurrency.git"
  [rtree]="$ZIG_BASE/rtree|git+https://gitlab.com/devnw/zig/rtree.git"
  [audit]="$ZIG_BASE/audit|git+https://gitlab.com/devnw/zig/audit.git"
  [capture]="$ZIG_BASE/capture|git+https://gitlab.com/devnw/zig/capture.git"
  [entropy]="$ZIG_BASE/entropy|git+https://gitlab.com/devnw/zig/entropy.git"
)

# Deps to update (all if none specified)
if [ $# -gt 0 ]; then
  DEPS=("$@")
else
  DEPS=("${!REPO_MAP[@]}")
fi

cd "$GEODE_ROOT"
rm -rf zig-pkg/ .zig-cache/ 2>/dev/null || true

UPDATED=0
FAILED=0

for dep in "${DEPS[@]}"; do
  info="${REPO_MAP[$dep]:-}"
  if [ -z "$info" ]; then
    echo "SKIP $dep: not in REPO_MAP"
    continue
  fi

  local_path="${info%%|*}"
  remote_base="${info##*|}"

  # Get latest commit from local repo
  if [ ! -d "$local_path" ]; then
    echo "SKIP $dep: local repo not found at $local_path"
    continue
  fi

  commit=$(git -C "$local_path" rev-parse HEAD 2>/dev/null)
  if [ -z "$commit" ]; then
    echo "SKIP $dep: could not get HEAD commit"
    continue
  fi

  url="${remote_base}#${commit}"

  # Fetch zig package hash
  pkg_hash=$(zig fetch "$url" 2>&1)
  if [[ "$pkg_hash" == *error* ]] || [ -z "$pkg_hash" ]; then
    echo "FAIL $dep: zig fetch failed — $pkg_hash"
    FAILED=$((FAILED + 1))
    continue
  fi

  # Get repo suffix for URL matching (e.g., "quic.git")
  repo_suffix=$(echo "$remote_base" | grep -oP '[^/]+\.git$')

  # Update build.zig.zon using python for reliable regex
  python3 -c "
import re, sys
with open('$ZON') as f: c = f.read()

# Update commit hash in URL
repo_suffix = '${repo_suffix}'
new_commit = '${commit}'
c = re.sub(
    rf'({re.escape(repo_suffix)}#)[a-f0-9]+',
    rf'\g<1>{new_commit}',
    c
)

# Update package hash — match the dep name prefix
pkg_hash = '${pkg_hash}'
# Extract prefix: everything up to the base64 hash part
# e.g., 'quic-0.1.11-' from 'quic-0.1.11-gBIqUY32...'
parts = pkg_hash.split('-')
# Find where base64 starts (not a digit-only segment)
prefix_end = 0
for i, p in enumerate(parts):
    if i >= 2 and not p.replace('.','').isdigit():
        prefix_end = i
        break
if prefix_end > 0:
    prefix = '-'.join(parts[:prefix_end]) + '-'
    c = re.sub(rf'{re.escape(prefix)}[A-Za-z0-9_-]+', pkg_hash, c)

with open('$ZON', 'w') as f: f.write(c)
" 2>/dev/null

  echo "  OK $dep: $pkg_hash"
  UPDATED=$((UPDATED + 1))
done

echo ""
echo "Updated $UPDATED deps, $FAILED failed"
echo "Run 'zig build' to verify"
