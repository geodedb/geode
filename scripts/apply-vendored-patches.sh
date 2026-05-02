#!/usr/bin/env bash
# Apply vendored patches to fetched zig-pkg dependencies.
#
# Why this exists:
#   * The geode release pipeline cross-compiles to x86_64-macos via
#     GoReleaser. As of 2026-05-02, the pinned `quic@49f59f7` package
#     fails that cross-compile inside `src/quic/endpoint/udp_transport.zig`
#     because it uses `@intFromEnum(std.c.F.GETFL)` — `std.c.F` is an enum
#     on Linux but a struct of `pub const comptime_int` on macOS, plus
#     it still references the dropped `std.posix.{sendto,recvfrom}`.
#   * The fix is committed to upstream quic at `b73a804`
#     (branch `fix/macos-cross-compile-fcntl-sendto-recvfrom`).
#   * Bumping geode's pin to `b73a804` triggers a Zig 0.16 module-dedup
#     diamond ("file exists in modules 'build_options13' and
#     'build_options0'") — the same package content compiles cleanly
#     under hash `gBIqUS4j…` (the 49f59f7 hash) but not under
#     `gBIqUY0p…` (the b73a804 hash). The diamond is hash-driven, not
#     content-driven.
#   * Workaround: keep the pin at 49f59f7 (no diamond), and overlay the
#     patched udp_transport.zig onto the cache directory before
#     compilation. This is correctness-preserving — the patched content
#     is identical to upstream `b73a804`'s udp_transport.zig.
#
# Sunset:
#   Delete this script, the `patches/` directory, and the corresponding
#   `.goreleaser.yaml` `before:hooks` entry once a coordinated sibling
#   pin bump (gql / dns / repl / vulkan / thread_pool / protobuf / slog /
#   wal / quic / otel) lets geode pin a quic SHA whose tree compiles
#   cleanly under its own hash.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHES_DIR="$REPO_ROOT/patches"

# Candidate cache roots. Zig 0.16 resolves package sources from a few
# possible locations:
#   * `${ZIG_GLOBAL_CACHE_DIR}/p` — the global cache (default
#     `~/.cache/zig/p`); CI populates this from `zig-pkg/` via the
#     `.zig-vendor-cache` template in `.gitlab-ci.yml`.
#   * `$REPO_ROOT/zig-pkg` — the in-tree vendored cache used for local
#     builds.
# We patch every cache location that contains the target hash so the
# patch lands wherever zig build resolves the dep from.
DEFAULT_GLOBAL_CACHE="${HOME:-/root}/.cache/zig"
ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$DEFAULT_GLOBAL_CACHE}"

CACHE_ROOTS=(
  "$REPO_ROOT/zig-pkg"
  "$ZIG_GLOBAL_CACHE_DIR/p"
)

# ----------------------------------------------------------------------
# Patch: quic@49f59f7 udp_transport.zig macOS cross-compile fix
# ----------------------------------------------------------------------
QUIC_HASH="quic-0.1.14-gBIqUS4jOgBqM61tIiulYgHrmm9DemZXX2DtMnV8XcJj"
QUIC_URL="git+https://gitlab.com/devnw/zig/quic.git#49f59f7ac432d71842baf1263abe39988b9603c3"
QUIC_REL="$QUIC_HASH/src/quic/endpoint/udp_transport.zig"
QUIC_PATCHED="$PATCHES_DIR/quic-49f59f7-udp-transport-macos.zig"

if [ ! -f "$QUIC_PATCHED" ]; then
  echo "[apply-vendored-patches] error: missing patch file $QUIC_PATCHED" >&2
  exit 1
fi

apply_to_root() {
  local root="$1"
  local target="$root/$QUIC_REL"

  if [ ! -d "$root" ]; then
    return 0  # cache root doesn't exist on this host; skip silently
  fi

  if [ ! -d "$root/$QUIC_HASH" ]; then
    # Cache root exists but this specific package hash isn't there yet.
    # Trigger an idempotent zig fetch — it's a no-op if already cached
    # under the GLOBAL cache; populates whichever root zig elects.
    echo "[apply-vendored-patches] $QUIC_HASH not in $root; running zig fetch"
    zig fetch "$QUIC_URL" >/dev/null
  fi

  if [ ! -f "$target" ]; then
    echo "[apply-vendored-patches] note: $target still missing (zig may have populated a different cache root)"
    return 0
  fi

  if cmp -s "$QUIC_PATCHED" "$target"; then
    echo "[apply-vendored-patches] $root/$QUIC_HASH/.../udp_transport.zig already patched"
  else
    echo "[apply-vendored-patches] patching $root/$QUIC_HASH/.../udp_transport.zig"
    cp "$QUIC_PATCHED" "$target"
  fi
}

for root in "${CACHE_ROOTS[@]}"; do
  apply_to_root "$root"
done

echo "[apply-vendored-patches] done"
