#!/bin/bash
# Go client integration test runner

set -e

GEODE_HOST="${GEODE_HOST:-geode-server}"
GEODE_PORT="${GEODE_PORT:-8443}"
LOG_DIR="${LOG_DIR:-/logs}"
RESULTS_DIR="${RESULTS_DIR:-/results}"

echo "==============================================="
echo "Geode Go Client Integration Tests"
echo "==============================================="
echo "Server: ${GEODE_HOST}:${GEODE_PORT}"
echo "Log Dir: ${LOG_DIR}"
echo "Results Dir: ${RESULTS_DIR}"
echo "Started: $(date -Iseconds)"
echo "==============================================="

# Create output directories
mkdir -p "${LOG_DIR}/go" "${RESULTS_DIR}/go"

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

# Set environment for Go client
export GEODE_SERVER="${GEODE_HOST}:${GEODE_PORT}"
export GEODE_INSECURE=true

# Run Go tests with verbose output and coverage
cd /app/clients/go/gql

echo ""
echo "Running Go client tests..."
echo ""

# Run tests with JSON output for parsing
go test -v -json -coverprofile="${RESULTS_DIR}/go/coverage.out" ./... 2>&1 | \
    tee "${LOG_DIR}/go/test_output.json" | \
    go tool test2json 2>/dev/null || true

# Generate coverage report
if [ -f "${RESULTS_DIR}/go/coverage.out" ]; then
    go tool cover -html="${RESULTS_DIR}/go/coverage.out" -o "${RESULTS_DIR}/go/coverage.html" 2>/dev/null || true
    go tool cover -func="${RESULTS_DIR}/go/coverage.out" > "${RESULTS_DIR}/go/coverage_summary.txt" 2>/dev/null || true
fi

# Parse results and create summary
TOTAL_TESTS=$(grep -c '"Action":"run"' "${LOG_DIR}/go/test_output.json" 2>/dev/null || echo "0")
PASSED_TESTS=$(grep -c '"Action":"pass"' "${LOG_DIR}/go/test_output.json" 2>/dev/null || echo "0")
FAILED_TESTS=$(grep -c '"Action":"fail"' "${LOG_DIR}/go/test_output.json" 2>/dev/null || echo "0")

# Create summary JSON
cat > "${RESULTS_DIR}/go/summary.json" << EOF
{
    "client": "go",
    "timestamp": "$(date -Iseconds)",
    "server": "${GEODE_HOST}:${GEODE_PORT}",
    "total_tests": ${TOTAL_TESTS},
    "passed": ${PASSED_TESTS},
    "failed": ${FAILED_TESTS},
    "pass_rate": $(echo "scale=2; ${PASSED_TESTS} * 100 / (${TOTAL_TESTS} + 1)" | bc 2>/dev/null || echo "0")
}
EOF

echo ""
echo "==============================================="
echo "Go Client Test Summary"
echo "==============================================="
echo "Total Tests: ${TOTAL_TESTS}"
echo "Passed: ${PASSED_TESTS}"
echo "Failed: ${FAILED_TESTS}"
echo "Results saved to: ${RESULTS_DIR}/go/"
echo "Logs saved to: ${LOG_DIR}/go/"
echo "Completed: $(date -Iseconds)"
echo "==============================================="

# Exit with appropriate code
if [ "${FAILED_TESTS}" -gt 0 ]; then
    exit 1
fi
exit 0
