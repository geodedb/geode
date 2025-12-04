#!/bin/bash
# Collect and display integration test results

set -e

RESULTS_DIR="${RESULTS_DIR:-/results}"
LOG_DIR="${LOG_DIR:-/logs}"

echo "==============================================="
echo "Integration Test Results Collector"
echo "==============================================="
echo "Results Dir: ${RESULTS_DIR}"
echo "Timestamp: $(date -Iseconds)"
echo "==============================================="

# Wait a bit for all clients to finish writing results
sleep 5

TOTAL_CLIENTS=0
PASSED_CLIENTS=0
FAILED_CLIENTS=0

declare -A CLIENT_RESULTS

for client in go python rust zig geodetestlab; do
    SUMMARY_FILE="${RESULTS_DIR}/${client}/summary.json"

    if [ -f "$SUMMARY_FILE" ]; then
        TOTAL_CLIENTS=$((TOTAL_CLIENTS + 1))

        # Extract exit code from summary
        EXIT_CODE=$(python3 -c "import json; d=json.load(open('$SUMMARY_FILE')); print(d.get('exit_code', 1))" 2>/dev/null || echo "1")

        if [ "$EXIT_CODE" -eq 0 ]; then
            PASSED_CLIENTS=$((PASSED_CLIENTS + 1))
            CLIENT_RESULTS[$client]="✓ PASSED"
        else
            FAILED_CLIENTS=$((FAILED_CLIENTS + 1))
            CLIENT_RESULTS[$client]="✗ FAILED (exit code: ${EXIT_CODE})"
        fi
    else
        echo "WARNING: No results found for ${client}"
        TOTAL_CLIENTS=$((TOTAL_CLIENTS + 1))
        FAILED_CLIENTS=$((FAILED_CLIENTS + 1))
        CLIENT_RESULTS[$client]="✗ NO RESULTS"
    fi
done

echo ""
echo "==============================================="
echo "Client Results Summary"
echo "==============================================="

for client in go python rust zig geodetestlab; do
    if [ -n "${CLIENT_RESULTS[$client]}" ]; then
        printf "%-15s %s\n" "${client}:" "${CLIENT_RESULTS[$client]}"
    fi
done

echo ""
echo "==============================================="
echo "Overall Summary"
echo "==============================================="
echo "Total Clients: ${TOTAL_CLIENTS}"
echo "Passed: ${PASSED_CLIENTS}"
echo "Failed: ${FAILED_CLIENTS}"
echo "==============================================="

# Generate consolidated JSON report
cat > "${RESULTS_DIR}/integration_summary.json" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "total_clients": ${TOTAL_CLIENTS},
    "passed_clients": ${PASSED_CLIENTS},
    "failed_clients": ${FAILED_CLIENTS},
    "pass_rate": $(python3 -c "print(f'{${PASSED_CLIENTS}/${TOTAL_CLIENTS}*100:.1f}' if ${TOTAL_CLIENTS} > 0 else '0.0')" 2>/dev/null || echo "0.0"),
    "clients": {
EOF

FIRST=true
for client in go python rust zig geodetestlab; do
    SUMMARY_FILE="${RESULTS_DIR}/${client}/summary.json"
    if [ -f "$SUMMARY_FILE" ]; then
        if [ "$FIRST" = true ]; then
            FIRST=false
        else
            echo "," >> "${RESULTS_DIR}/integration_summary.json"
        fi
        echo -n "        \"${client}\": " >> "${RESULTS_DIR}/integration_summary.json"
        cat "$SUMMARY_FILE" >> "${RESULTS_DIR}/integration_summary.json"
    fi
done

cat >> "${RESULTS_DIR}/integration_summary.json" << EOF

    }
}
EOF

echo ""
echo "Results saved to: ${RESULTS_DIR}/integration_summary.json"
echo ""

# Exit with failure if any client failed
exit $((FAILED_CLIENTS > 0 ? 1 : 0))
