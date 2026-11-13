#!/usr/bin/env bash
# External mermaid integration test for `geode query --format mermaid`.
#
# Builds geode (if needed), starts a private instance on a high port,
# runs three representative queries through `--format mermaid`, and
# pipes each output to `npx @mermaid-js/mermaid-cli mmdc` to verify
# the output is *actually* valid mermaid (rendered to SVG).
#
# Requirements: node + npx on PATH. The first run will install
# @mermaid-js/mermaid-cli into npx's cache, which downloads chromium
# (~200 MB). Subsequent runs are fast.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

GEODE_BIN="${GEODE_BIN:-$REPO_ROOT/zig-out/bin/geode}"
PORT="${MERMAID_TEST_PORT:-$((RANDOM % 16383 + 49152))}"
TMPDIR="$(mktemp -d)"
SERVER_PID=""

cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

# 1. Sanity-check tooling
if ! command -v node >/dev/null 2>&1; then
    echo "FAIL: node not found on PATH" >&2
    exit 1
fi
if ! command -v npx >/dev/null 2>&1; then
    echo "FAIL: npx not found on PATH" >&2
    exit 1
fi

# 2. Build geode if the binary is missing
if [ ! -x "$GEODE_BIN" ]; then
    echo "Building geode..."
    zig build
fi
if [ ! -x "$GEODE_BIN" ]; then
    echo "FAIL: $GEODE_BIN missing after build" >&2
    exit 1
fi

# 3. Start a private geode instance on a high port.
# GEODE_ADMIN_PASSWORD bootstraps the admin account on first boot (the
# data dir is fresh so it triggers the first-boot path). The geode QUIC
# transport is UDP-only — we cannot use a TCP probe, so wait for the
# "server ready" log line instead.
PASSWORD="MermaidTestPassword123!"
echo "Starting geode on 127.0.0.1:$PORT (data: $TMPDIR/data)..."
mkdir -p "$TMPDIR/data"
GEODE_ADMIN_PASSWORD="$PASSWORD" \
"$GEODE_BIN" serve \
    --listen "127.0.0.1:$PORT" \
    --data-dir "$TMPDIR/data" \
    --log-level warn \
    >"$TMPDIR/server.log" 2>&1 &
SERVER_PID=$!

# Wait for geode to log readiness (up to 30s).
for _ in $(seq 1 60); do
    if grep -q "server ready" "$TMPDIR/server.log" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "FAIL: geode process exited before becoming ready" >&2
        cat "$TMPDIR/server.log" >&2
        exit 1
    fi
    sleep 0.5
done
if ! grep -q "server ready" "$TMPDIR/server.log" 2>/dev/null; then
    echo "FAIL: geode did not become ready on port $PORT within 30s" >&2
    cat "$TMPDIR/server.log" >&2
    exit 1
fi

# 4. Run three representative queries and validate via mmdc
PUP_CONFIG="$REPO_ROOT/tests/integration/mermaid-puppeteer-config.json"

run_case() {
    local name="$1"
    local query="$2"
    local mmd_file="$TMPDIR/$name.mmd"
    local svg_file="$TMPDIR/$name.svg"

    echo "--- Case: $name ---"
    "$GEODE_BIN" query \
        --server "127.0.0.1:$PORT" \
        --insecure-tls-skip-verify \
        --user geode \
        --password "$PASSWORD" \
        --format mermaid \
        "$query" \
        > "$mmd_file"

    if [ ! -s "$mmd_file" ]; then
        echo "FAIL[$name]: empty mermaid output" >&2
        return 1
    fi

    if ! grep -q "^flowchart LR$" "$mmd_file"; then
        echo "FAIL[$name]: missing 'flowchart LR' header" >&2
        cat "$mmd_file" >&2
        return 1
    fi

    # Run the official mermaid renderer. Exit code 0 + non-empty SVG = valid mermaid.
    # PUPPETEER_SKIP_*_DOWNLOAD env vars prevent the npx install from pulling
    # ~200 MB of chromium when the system already provides it; the puppeteer
    # config's "executablePath" points mmdc at /usr/bin/chromium at runtime.
    if ! PUPPETEER_SKIP_DOWNLOAD=true \
        PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true \
        npx -y -p @mermaid-js/mermaid-cli mmdc \
        -i "$mmd_file" \
        -o "$svg_file" \
        --quiet \
        --puppeteerConfigFile "$PUP_CONFIG" 2> "$TMPDIR/$name.mmdc.log"; then
        echo "FAIL[$name]: mmdc rejected geode output" >&2
        echo "--- mermaid input ---" >&2
        cat "$mmd_file" >&2
        echo "--- mmdc stderr ---" >&2
        cat "$TMPDIR/$name.mmdc.log" >&2
        return 1
    fi

    if [ ! -s "$svg_file" ]; then
        echo "FAIL[$name]: mmdc produced empty SVG" >&2
        return 1
    fi

    if ! grep -q "<svg" "$svg_file"; then
        echo "FAIL[$name]: mmdc output is not SVG" >&2
        head -c 200 "$svg_file" >&2
        return 1
    fi

    echo "OK[$name]: mermaid valid, SVG $(wc -c < "$svg_file") bytes"
}

# Case 1: empty graph (just header)
run_case "empty" "RETURN 1 AS x"

# Case 2: single node
run_case "single-node" "CREATE (n:Person {name: 'Alice'}) RETURN n"

# Case 3: relationship
run_case "relationship" "CREATE (a:Person {name: 'Alice'})-[r:KNOWS]->(b:Person {name: 'Bob'}) RETURN a, r, b"

echo ""
echo "ALL MERMAID INTEGRATION TESTS PASSED"
