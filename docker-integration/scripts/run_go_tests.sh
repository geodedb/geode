#!/bin/bash
# Go client integration test runner

set -e

GEODE_HOST="${GEODE_HOST:-geode-server}"
GEODE_PORT="${GEODE_PORT:-3141}"
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

# Set environment for Go client
export GEODE_SERVER="${GEODE_HOST}:${GEODE_PORT}"
export GEODE_INSECURE=true

# Run Go tests with verbose output and coverage
cd /app/clients/go/gql

echo ""
echo "Running Go client tests..."
echo ""

# Run tests with JSON output for parsing
# Note: go test -json already outputs JSON, no need for go tool test2json
go test -v -json -coverprofile="${RESULTS_DIR}/go/coverage.out" ./... 2>&1 | \
    tee "${LOG_DIR}/go/test_output.json" || true

# Generate coverage report
if [ -f "${RESULTS_DIR}/go/coverage.out" ]; then
    go tool cover -html="${RESULTS_DIR}/go/coverage.out" -o "${RESULTS_DIR}/go/coverage.html" 2>/dev/null || true
    go tool cover -func="${RESULTS_DIR}/go/coverage.out" > "${RESULTS_DIR}/go/coverage_summary.txt" 2>/dev/null || true
fi

# Parse results and create summary
# The Go test JSON output has nested JSON in the Output field, so we need to only match
# the outer-level Action fields, not the ones inside nested JSON strings.
# Use jq to properly parse the JSON and count actions at the top level.
# Fall back to grep if jq is not available.
if command -v jq &> /dev/null; then
    # Use jq to properly parse top-level Action fields
    TOTAL_TESTS=$(jq -r 'select(.Action == "run" and .Test != null) | .Action' "${LOG_DIR}/go/test_output.json" 2>/dev/null | wc -l || echo "0")
    PASSED_TESTS=$(jq -r 'select(.Action == "pass" and .Test != null) | .Action' "${LOG_DIR}/go/test_output.json" 2>/dev/null | wc -l || echo "0")
    FAILED_TESTS=$(jq -r 'select(.Action == "fail" and .Test != null) | .Action' "${LOG_DIR}/go/test_output.json" 2>/dev/null | wc -l || echo "0")
else
    # Fallback: use grep but only match at line start (top-level Action only)
    # Lines look like: {"Action":"pass","Package":"...","Test":"..."}
    # We match actions that have a "Test" field (individual test results, not package results)
    TOTAL_TESTS=$(grep -E '^{"Action":"run".*"Test":' "${LOG_DIR}/go/test_output.json" 2>/dev/null | wc -l || echo "0")
    PASSED_TESTS=$(grep -E '^{"Action":"pass".*"Test":' "${LOG_DIR}/go/test_output.json" 2>/dev/null | wc -l || echo "0")
    FAILED_TESTS=$(grep -E '^{"Action":"fail".*"Test":' "${LOG_DIR}/go/test_output.json" 2>/dev/null | wc -l || echo "0")
fi

# Strip whitespace, remove non-digits, and ensure numeric (default to 0 if empty)
TOTAL_TESTS=$(echo "${TOTAL_TESTS}" | tr -d '[:space:]' | tr -cd '0-9')
PASSED_TESTS=$(echo "${PASSED_TESTS}" | tr -d '[:space:]' | tr -cd '0-9')
FAILED_TESTS=$(echo "${FAILED_TESTS}" | tr -d '[:space:]' | tr -cd '0-9')
TOTAL_TESTS="${TOTAL_TESTS:-0}"
PASSED_TESTS="${PASSED_TESTS:-0}"
FAILED_TESTS="${FAILED_TESTS:-0}"
# Ensure they are valid integers (default to 0 if not)
[[ "$TOTAL_TESTS" =~ ^[0-9]+$ ]] || TOTAL_TESTS=0
[[ "$PASSED_TESTS" =~ ^[0-9]+$ ]] || PASSED_TESTS=0
[[ "$FAILED_TESTS" =~ ^[0-9]+$ ]] || FAILED_TESTS=0

# Calculate pass rate using bash arithmetic (avoid bc dependency)
if [ "${TOTAL_TESTS}" -gt 0 ]; then
    PASS_RATE=$((PASSED_TESTS * 100 / TOTAL_TESTS))
else
    PASS_RATE=0
fi

# Determine exit code based on failed tests
if [ "${FAILED_TESTS}" -gt 0 ] 2>/dev/null; then
    EXIT_CODE=1
else
    EXIT_CODE=0
fi

# Create summary JSON
cat > "${RESULTS_DIR}/go/summary.json" << EOF
{
    "client": "go",
    "timestamp": "$(date -Iseconds)",
    "server": "${GEODE_HOST}:${GEODE_PORT}",
    "total_tests": ${TOTAL_TESTS},
    "passed": ${PASSED_TESTS},
    "failed": ${FAILED_TESTS},
    "pass_rate": ${PASS_RATE},
    "exit_code": ${EXIT_CODE}
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
echo "Exiting with code ${EXIT_CODE}"
exit ${EXIT_CODE}
