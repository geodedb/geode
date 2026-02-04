#!/usr/bin/env bash
set -euo pipefail

# telemetry-smoke.sh — start geode server with paging telemetry, run a small query via geode,
# print captured telemetry lines, and clean up.
# Usage: scripts/telemetry-smoke.sh [page_size]
# Requires: zig build has produced ./zig-out/bin/geode

ROOT_DIR="$(cd "$(dirname "$0")"/.. && pwd)"
BIN_DIR="$ROOT_DIR/zig-out/bin"
SERVER_BIN="$BIN_DIR/geode"
CLIENT_BIN="$BIN_DIR/geode"
PAGE_SIZE="${1:-1}"
LOG_FILE="$(mktemp -t geode_telemetry.XXXXXX.log)"
PID_FILE="$(mktemp -t geode_telemetry.XXXXXX.pid)"
ADMIN_USER="${GEODE_ADMIN_USERNAME:-geode}"
ADMIN_PASS="${GEODE_DEFAULT_PASSWORD:-geode-test-password}"

cleanup() {
  if [[ -f "$PID_FILE" ]]; then
    PID=$(cat "$PID_FILE" || true)
    if [[ -n "${PID:-}" ]]; then
      kill "$PID" >/dev/null 2>&1 || true
      wait "$PID" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  fi
}
trap cleanup EXIT INT TERM

# Ensure server and client binaries exist and are executable
if [ ! -x "$SERVER_BIN" ] || [ ! -x "$CLIENT_BIN" ]; then
  echo "error: build outputs not found; run: zig build" >&2
  exit 1
fi

# Start server with telemetry enabled; capture stderr to log file
GEODE_TELEMETRY_PAGING=1 \
GEODE_ADMIN_USERNAME="${ADMIN_USER}" GEODE_DEFAULT_PASSWORD="${ADMIN_PASS}" \
"$SERVER_BIN" serve --listen 127.0.0.1:3141 --data-dir "$ROOT_DIR/data" \
  1>/dev/null 2>"$LOG_FILE" &
SERVER_PID=$!
echo "$SERVER_PID" >"$PID_FILE"

# Give server a moment to come up
sleep 0.5

# Run a tiny ordered+limited query to ensure a single page flows
"$CLIENT_BIN" query "RETURN 1 AS x ORDER BY x LIMIT $PAGE_SIZE" --format json --server 127.0.0.1:3141 --insecure --user "${ADMIN_USER}" --password "${ADMIN_PASS}" || true

# Print telemetry lines
if grep -q '"event":"PULL_PAGE"' "$LOG_FILE"; then
  echo "--- Captured Telemetry ---"
  grep '"event":"PULL_PAGE"' "$LOG_FILE"
  echo "--------------------------"
else
  echo "warning: no telemetry lines captured (check server startup/logging)" >&2
fi

exit 0
