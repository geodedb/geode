#!/bin/bash
# Zig client integration test runner

set -e

GEODE_HOST="${GEODE_HOST:-geode-server}"
GEODE_PORT="${GEODE_PORT:-8443}"
LOG_DIR="${LOG_DIR:-/logs}"
RESULTS_DIR="${RESULTS_DIR:-/results}"

echo "==============================================="
echo "Geode Zig Client Integration Tests"
echo "==============================================="
echo "Server: ${GEODE_HOST}:${GEODE_PORT}"
echo "Log Dir: ${LOG_DIR}"
echo "Results Dir: ${RESULTS_DIR}"
echo "Started: $(date -Iseconds)"
echo "==============================================="

# Create output directories
mkdir -p "${LOG_DIR}/zig" "${RESULTS_DIR}/zig"

# Wait for server to be ready (QUIC uses UDP)
echo "Waiting for Geode server..."
MAX_RETRIES=60
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    # Use UDP check for QUIC server (-u flag)
    # Try TCP first (default), then UDP (QUIC)
    if nc -z -w 2 "${GEODE_HOST}" "${GEODE_PORT}" 2>/dev/null || \
       nc -z -u -w 2 "${GEODE_HOST}" "${GEODE_PORT}" 2>/dev/null; then
        echo "Server is ready!"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "Waiting for server... (attempt ${RETRY_COUNT}/${MAX_RETRIES})"
    sleep 2
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "ERROR: Server did not become ready in time"
    exit 1
fi

# Set environment for Zig client
export GEODE_SERVER="${GEODE_HOST}:${GEODE_PORT}"
export GEODE_INSECURE=true

# Run Zig tests
cd /app/clients/zig

echo ""
echo "Running Zig client tests..."
echo ""

# Create writable directories for Zig build cache and output
export ZIG_LOCAL_CACHE_DIR="/tmp/zig-cache"
export ZIG_GLOBAL_CACHE_DIR="/tmp/zig-global-cache"
export ZIG_INSTALL_PREFIX="/tmp/zig-out"
mkdir -p "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_INSTALL_PREFIX/bin"

# Build and run the test executable (uses "run" step, not "test" step)
# Use -p to specify a writable install prefix
zig build run --cache-dir "$ZIG_LOCAL_CACHE_DIR" --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" -p "$ZIG_INSTALL_PREFIX" 2>&1 | tee "${LOG_DIR}/zig/test_output.txt"
TEST_EXIT_CODE=${PIPESTATUS[0]}

# Parse test results (count checkmarks for passed, X for failed)
# grep -c returns 0 even on no matches but exits with code 1, so capture output without ||
PASSED_TESTS=$(grep -c "✓" "${LOG_DIR}/zig/test_output.txt" 2>/dev/null || true)
FAILED_TESTS=$(grep -c "✗" "${LOG_DIR}/zig/test_output.txt" 2>/dev/null || true)
# Strip any whitespace/newlines and ensure numeric (default to 0 if empty)
PASSED_TESTS=$(echo "${PASSED_TESTS}" | tr -d '[:space:]')
FAILED_TESTS=$(echo "${FAILED_TESTS}" | tr -d '[:space:]')
PASSED_TESTS="${PASSED_TESTS:-0}"
FAILED_TESTS="${FAILED_TESTS:-0}"
TOTAL_TESTS=$((PASSED_TESTS + FAILED_TESTS))

# Create summary JSON
cat > "${RESULTS_DIR}/zig/summary.json" << EOF
{
    "client": "zig",
    "timestamp": "$(date -Iseconds)",
    "server": "${GEODE_HOST}:${GEODE_PORT}",
    "total_tests": ${TOTAL_TESTS},
    "passed": ${PASSED_TESTS},
    "failed": ${FAILED_TESTS},
    "exit_code": ${TEST_EXIT_CODE}
}
EOF

echo ""
echo "==============================================="
echo "Zig Client Test Summary"
echo "==============================================="
echo "Total Tests: ${TOTAL_TESTS}"
echo "Passed: ${PASSED_TESTS}"
echo "Failed: ${FAILED_TESTS}"
echo "Exit Code: ${TEST_EXIT_CODE}"
echo "Results saved to: ${RESULTS_DIR}/zig/"
echo "Logs saved to: ${LOG_DIR}/zig/"
echo "Completed: $(date -Iseconds)"
echo "==============================================="

exit ${TEST_EXIT_CODE}
