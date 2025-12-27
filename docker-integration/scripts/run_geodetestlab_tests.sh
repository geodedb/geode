#!/bin/bash
# GeodeTestLab integration test runner

set -e

GEODE_HOST="${GEODE_HOST:-geode-server}"
GEODE_PORT="${GEODE_PORT:-8443}"
LOG_DIR="${LOG_DIR:-/logs}"
RESULTS_DIR="${RESULTS_DIR:-/results}"
SPECS_DIR="${SPECS_DIR:-/geodetestlab/specs}"

echo "==============================================="
echo "Geode GeodeTestLab Integration Tests"
echo "==============================================="
echo "Server: ${GEODE_HOST}:${GEODE_PORT}"
echo "Specs Dir: ${SPECS_DIR}"
echo "Log Dir: ${LOG_DIR}"
echo "Results Dir: ${RESULTS_DIR}"
echo "Started: $(date -Iseconds)"
echo "==============================================="

# Create output directories
mkdir -p "${LOG_DIR}/geodetestlab" "${RESULTS_DIR}/geodetestlab"

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

# Set environment for GeodeTestLab
export GEODE_SERVER="${GEODE_HOST}:${GEODE_PORT}"
export GEODE_INSECURE=true

# Select test specs to run (basic tests for integration)
TEST_SPECS=(
    "${SPECS_DIR}/geode_basic.yml"
    "${SPECS_DIR}/geode_basic_test.yml"
    "${SPECS_DIR}/geode_current_capabilities.yml"
)

echo ""
echo "Running GeodeTestLab tests..."
echo ""

echo "DEBUG: Checking for geode binary..."
ls -l /usr/local/bin/geode || echo "Binary not found at /usr/local/bin/geode"
which geode || echo "geode not in PATH"
echo "PATH is: $PATH"

# Run GeodeTestLab specs using the runner module

TOTAL_SPECS=0
PASSED_SPECS=0
FAILED_SPECS=0

for spec in "${TEST_SPECS[@]}"; do
    if [ ! -f "$spec" ]; then
        echo "WARNING: Spec file not found: $spec"
        continue
    fi

    TOTAL_SPECS=$((TOTAL_SPECS + 1))
    SPEC_NAME=$(basename "$spec")

    echo "-----------------------------------------------"
    echo "Running spec: ${SPEC_NAME}"
    echo "-----------------------------------------------"

    # Run geodetestlab CLI (server management is handled by the CLI itself)
    # Use PIPESTATUS to get the actual command exit code, not the tee exit code
    python3 -m geodetestlab.cli run \
        --spec "$spec" \
        --llm-provider mock \
        2>&1 | tee "${LOG_DIR}/geodetestlab/${SPEC_NAME}.log"

    SPEC_EXIT_CODE=${PIPESTATUS[0]}

    if [ "$SPEC_EXIT_CODE" -eq 0 ]; then
        echo "✓ ${SPEC_NAME} PASSED"
        PASSED_SPECS=$((PASSED_SPECS + 1))
    else
        echo "✗ ${SPEC_NAME} FAILED (exit code: $SPEC_EXIT_CODE)"
        FAILED_SPECS=$((FAILED_SPECS + 1))
    fi
    echo ""
done

# Aggregate all logs
cat "${LOG_DIR}/geodetestlab/"*.log > "${LOG_DIR}/geodetestlab/test_output.txt" 2>/dev/null || true

# Create summary JSON
cat > "${RESULTS_DIR}/geodetestlab/summary.json" << EOF
{
    "client": "geodetestlab",
    "timestamp": "$(date -Iseconds)",
    "server": "${GEODE_HOST}:${GEODE_PORT}",
    "total_specs": ${TOTAL_SPECS},
    "passed_specs": ${PASSED_SPECS},
    "failed_specs": ${FAILED_SPECS},
    "exit_code": $((FAILED_SPECS > 0 ? 1 : 0))
}
EOF

echo ""
echo "==============================================="
echo "GeodeTestLab Test Summary"
echo "==============================================="
echo "Total Specs: ${TOTAL_SPECS}"
echo "Passed: ${PASSED_SPECS}"
echo "Failed: ${FAILED_SPECS}"
echo "Results saved to: ${RESULTS_DIR}/geodetestlab/"
echo "Logs saved to: ${LOG_DIR}/geodetestlab/"
echo "Completed: $(date -Iseconds)"
echo "==============================================="

exit $((FAILED_SPECS > 0 ? 1 : 0))
