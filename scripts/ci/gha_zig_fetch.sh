#!/usr/bin/env bash
# Prime the Zig package cache for a GitHub Actions job (.github/workflows/ci.yml),
# the way the GitLab `.zig-vendor-cache` anchor does for GitLab jobs:
#
#   1. copy vendored packages (zig-pkg/, docker/zig-packages/) when present;
#   2. pre-fetch protoc, protobuf's lazy host dependency, which is a GitHub
#      release download that drops connections (HttpConnectionClosing). On
#      x86_64 Linux it comes first from this project's public GitLab
#      generic-package mirror, placed directly as the `p/<hash>.tar.gz` blob
#      Zig 0.16 reads; otherwise (and as the fallback) via `zig fetch`;
#   3. `zig build --fetch [args]` with up to 4 attempts, so a dropped download
#      is retried before any build step runs. Compiler errors are never
#      retried: --fetch builds nothing.
#
#   scripts/ci/gha_zig_fetch.sh [extra zig build args, e.g. -Dfips=true]
set -uo pipefail

: "${ZIG_GLOBAL_CACHE_DIR:?set ZIG_GLOBAL_CACHE_DIR}"
mkdir -p "${ZIG_GLOBAL_CACHE_DIR}/p" "${ZIG_GLOBAL_CACHE_DIR}/tmp"

for vendored in zig-pkg docker/zig-packages; do
  if [ -d "$vendored" ] && ls "$vendored"/* >/dev/null 2>&1; then
    cp -rn "$vendored"/* "${ZIG_GLOBAL_CACHE_DIR}/p/" 2>/dev/null || true
    echo "populated the package cache from ${vendored}/"
  fi
done

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    protoc_hash="N-V-__8AAGKbngAmNuaBMSXq_WgmQi6N8WVWVKp0moFSTvoJ"
    protoc_zip="https://github.com/protocolbuffers/protobuf/releases/download/v32.1/protoc-32.1-linux-x86_64.zip"
    protoc_mirror="https://gitlab.com/api/v4/projects/77156681/packages/generic/protoc/32.1/protoc-32.1-linux-x86_64.pkg.tar.gz"
    ;;
  Darwin-arm64)
    protoc_hash=""
    protoc_zip="https://github.com/protocolbuffers/protobuf/releases/download/v32.1/protoc-32.1-osx-aarch_64.zip"
    protoc_mirror=""
    ;;
  *)
    protoc_hash=""
    protoc_zip=""
    protoc_mirror=""
    ;;
esac

# On macOS runners the per-session TMPDIR can be cleaned mid-job, which made
# `zig fetch` fail with "failed to create temporary zip file" on GitLab's
# macOS runners; keep temporary files inside the workspace.
if [ "$(uname -s)" = "Darwin" ]; then
  export TMPDIR="${GITHUB_WORKSPACE:-$PWD}/.zig-tmp"
  mkdir -p "$TMPDIR"
fi
scratch="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"

if [ -n "$protoc_zip" ] && { [ -z "$protoc_hash" ] || [ ! -e "${ZIG_GLOBAL_CACHE_DIR}/p/${protoc_hash}.tar.gz" ]; }; then
  ok=0
  for attempt in 1 2 3; do
    if [ -n "$protoc_mirror" ] &&
      curl -fsSL --retry 3 --retry-delay 3 --retry-all-errors --connect-timeout 20 \
        -o "$scratch/protoc.pkg.tar.gz" "$protoc_mirror" &&
      gzip -t "$scratch/protoc.pkg.tar.gz" 2>/dev/null; then
      mv "$scratch/protoc.pkg.tar.gz" "${ZIG_GLOBAL_CACHE_DIR}/p/${protoc_hash}.tar.gz"
      echo "pre-fetched protoc from the GitLab package mirror (attempt ${attempt})"
      ok=1
      break
    fi
    if zig fetch "$protoc_zip" >"$scratch/zig-fetch-protoc.log" 2>&1; then
      echo "pre-fetched protoc via zig fetch (attempt ${attempt}, hash $(cat "$scratch/zig-fetch-protoc.log"))"
      ok=1
      break
    fi
    echo "protoc pre-fetch attempt ${attempt} failed: $(tail -1 "$scratch/zig-fetch-protoc.log" 2>/dev/null)"
    sleep $((attempt * 10))
  done
  [ "$ok" = 1 ] || echo "protoc pre-fetch failed; zig build --fetch will try again"
fi

for attempt in 1 2 3 4; do
  if zig build --fetch "$@"; then
    echo "fetched the dependency closure on attempt ${attempt}"
    exit 0
  fi
  [ "$attempt" = 4 ] && break
  echo "zig build --fetch attempt ${attempt} failed; retrying in $((attempt * 20))s"
  sleep $((attempt * 20))
done
echo "zig build --fetch failed after 4 attempts" >&2
exit 1
