#!/bin/bash
# Python client integration test runner

set -e

GEODE_HOST="${GEODE_HOST:-geode-server}"
GEODE_PORT="${GEODE_PORT:-3141}"
LOG_DIR="${LOG_DIR:-/logs}"
RESULTS_DIR="${RESULTS_DIR:-/results}"

echo "==============================================="
echo "Geode Python Client Integration Tests"
echo "==============================================="
echo "Server: ${GEODE_HOST}:${GEODE_PORT}"
echo "Log Dir: ${LOG_DIR}"
echo "Results Dir: ${RESULTS_DIR}"
echo "Started: $(date -Iseconds)"
echo "==============================================="

# Create output directories
mkdir -p "${LOG_DIR}/python" "${RESULTS_DIR}/python"

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

# Set environment for Python client
export GEODE_SERVER="${GEODE_HOST}:${GEODE_PORT}"
export GEODE_INSECURE=true

# Run Python tests
cd /app

echo ""
echo "Running Python client tests..."
echo ""

# Run pytest with verbose output
python3 -m pytest \
    --tb=short \
    -v \
    clients/python/tests/ 2>&1 | tee "${LOG_DIR}/python/test_output.txt"

TEST_EXIT_CODE=${PIPESTATUS[0]}

# Parse test results (grep -c returns exit code 1 on zero matches)
PASSED_TESTS=$(grep -c "PASSED" "${LOG_DIR}/python/test_output.txt" 2>/dev/null || true)
FAILED_TESTS=$(grep -c "FAILED" "${LOG_DIR}/python/test_output.txt" 2>/dev/null || true)

# Strip whitespace and ensure numeric (default to 0 if empty)
PASSED_TESTS=$(echo "${PASSED_TESTS}" | tr -d '[:space:]')
FAILED_TESTS=$(echo "${FAILED_TESTS}" | tr -d '[:space:]')
PASSED_TESTS="${PASSED_TESTS:-0}"
FAILED_TESTS="${FAILED_TESTS:-0}"
TOTAL_TESTS=$((PASSED_TESTS + FAILED_TESTS))

# Create summary JSON
cat > "${RESULTS_DIR}/python/summary.json" << EOF
{
    "client": "python",
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
echo "Python Client Test Summary"
echo "==============================================="
echo "Total Tests: ${TOTAL_TESTS}"
echo "Passed: ${PASSED_TESTS}"
echo "Failed: ${FAILED_TESTS}"
echo "Exit Code: ${TEST_EXIT_CODE}"
echo "Results saved to: ${RESULTS_DIR}/python/"
echo "Logs saved to: ${LOG_DIR}/python/"
echo "Completed: $(date -Iseconds)"
echo "==============================================="

exit ${TEST_EXIT_CODE}
