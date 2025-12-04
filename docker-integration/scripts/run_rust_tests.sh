#!/bin/bash
# Rust client integration test runner

set -e

GEODE_HOST="${GEODE_HOST:-geode-server}"
GEODE_PORT="${GEODE_PORT:-8443}"
LOG_DIR="${LOG_DIR:-/logs}"
RESULTS_DIR="${RESULTS_DIR:-/results}"

echo "==============================================="
echo "Geode Rust Client Integration Tests"
echo "==============================================="
echo "Server: ${GEODE_HOST}:${GEODE_PORT}"
echo "Log Dir: ${LOG_DIR}"
echo "Results Dir: ${RESULTS_DIR}"
echo "Started: $(date -Iseconds)"
echo "==============================================="

# Create output directories
mkdir -p "${LOG_DIR}/rust" "${RESULTS_DIR}/rust"

# Wait for server to be ready (QUIC uses UDP)
echo "Waiting for Geode server..."
MAX_RETRIES=60
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    # Use UDP check for QUIC server (-u flag)
    if nc -z -u -w 2 "${GEODE_HOST}" "${GEODE_PORT}" 2>/dev/null; then
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

# Set environment for Rust client
export GEODE_SERVER="${GEODE_HOST}:${GEODE_PORT}"
export GEODE_INSECURE=true
export RUST_BACKTRACE=1
export RUST_LOG=debug

# Run Rust tests
cd /app/clients/rust

echo ""
echo "Running Rust client tests..."
echo ""

# Run tests with detailed output
cargo test --release -- --nocapture 2>&1 | tee "${LOG_DIR}/rust/test_output.txt"
TEST_EXIT_CODE=${PIPESTATUS[0]}

# Parse test results from output
TOTAL_TESTS=$(grep -E "^test result:" "${LOG_DIR}/rust/test_output.txt" | grep -oP '\d+ passed' | grep -oP '\d+' || echo "0")
PASSED_TESTS=$(grep -E "^test result:" "${LOG_DIR}/rust/test_output.txt" | grep -oP '\d+ passed' | grep -oP '\d+' || echo "0")
FAILED_TESTS=$(grep -E "^test result:" "${LOG_DIR}/rust/test_output.txt" | grep -oP '\d+ failed' | grep -oP '\d+' || echo "0")

# Create summary JSON
cat > "${RESULTS_DIR}/rust/summary.json" << EOF
{
    "client": "rust",
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
echo "Rust Client Test Summary"
echo "==============================================="
echo "Total Tests: ${TOTAL_TESTS}"
echo "Passed: ${PASSED_TESTS}"
echo "Failed: ${FAILED_TESTS}"
echo "Exit Code: ${TEST_EXIT_CODE}"
echo "Results saved to: ${RESULTS_DIR}/rust/"
echo "Logs saved to: ${LOG_DIR}/rust/"
echo "Completed: $(date -Iseconds)"
echo "==============================================="

exit ${TEST_EXIT_CODE}
