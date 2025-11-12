#!/usr/bin/env bash
# Compare test results to baseline for modularization tracking
# Usage: ./compare_to_baseline.sh <new_test_log>

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

BASELINE_FILE="${BASELINE_FILE:-baseline_tests.log}"
NEW_TEST_LOG="${1:-}"

if [ -z "$NEW_TEST_LOG" ]; then
    echo -e "${RED}Error: Please provide a test log file to compare${NC}"
    echo "Usage: $0 <new_test_log>"
    echo ""
    echo "Example:"
    echo "  python3 scripts/test/extended_test_runner.py > after_refactor.log"
    echo "  $0 after_refactor.log"
    exit 1
fi

if [ ! -f "$NEW_TEST_LOG" ]; then
    echo -e "${RED}Error: Test log file not found: $NEW_TEST_LOG${NC}"
    exit 1
fi

if [ ! -f "$BASELINE_FILE" ]; then
    echo -e "${YELLOW}Warning: Baseline file not found: $BASELINE_FILE${NC}"
    echo "Creating baseline from documented metrics..."

    # Create a synthetic baseline based on documented metrics
    cat > "$BASELINE_FILE" << 'EOF'
============================================================
TOTAL: 1644 passed, 9 failed, 46 skipped
============================================================
EOF
fi

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   Test Results Comparison${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Extract metrics from baseline
baseline_passed=$(grep "TOTAL:" "$BASELINE_FILE" | grep -oP '\d+ passed' | grep -oP '\d+' || echo "1644")
baseline_failed=$(grep "TOTAL:" "$BASELINE_FILE" | grep -oP '\d+ failed' | grep -oP '\d+' || echo "9")
baseline_skipped=$(grep "TOTAL:" "$BASELINE_FILE" | grep -oP '\d+ skipped' | grep -oP '\d+' || echo "46")
baseline_total=$((baseline_passed + baseline_failed + baseline_skipped))

# Extract metrics from new log
new_passed=$(grep "TOTAL:" "$NEW_TEST_LOG" | grep -oP '\d+ passed' | grep -oP '\d+' || echo "0")
new_failed=$(grep "TOTAL:" "$NEW_TEST_LOG" | grep -oP '\d+ failed' | grep -oP '\d+' || echo "0")
new_skipped=$(grep "TOTAL:" "$NEW_TEST_LOG" | grep -oP '\d+ skipped' | grep -oP '\d+' || echo "0")
new_total=$((new_passed + new_failed + new_skipped))

# Calculate pass rates
if [ "$baseline_total" -gt 0 ]; then
    baseline_pass_rate=$(awk "BEGIN {printf \"%.1f\", ($baseline_passed / $baseline_total) * 100}")
else
    baseline_pass_rate="0.0"
fi

if [ "$new_total" -gt 0 ]; then
    new_pass_rate=$(awk "BEGIN {printf \"%.1f\", ($new_passed / $new_total) * 100}")
else
    new_pass_rate="0.0"
fi

# Calculate differences
diff_passed=$((new_passed - baseline_passed))
diff_failed=$((new_failed - baseline_failed))
diff_skipped=$((new_skipped - baseline_skipped))
diff_total=$((new_total - baseline_total))

# Format difference strings
format_diff() {
    local diff=$1
    if [ "$diff" -gt 0 ]; then
        echo -e "${GREEN}+$diff${NC}"
    elif [ "$diff" -lt 0 ]; then
        echo -e "${RED}$diff${NC}"
    else
        echo -e "${NC}±0${NC}"
    fi
}

# Display comparison table
echo -e "${BLUE}Metric                 Baseline      Current       Difference${NC}"
echo "================================================================"
printf "%-22s %-13s %-13s %s\n" "Total Tests" "$baseline_total" "$new_total" "$(format_diff $diff_total)"
printf "%-22s %-13s %-13s %s\n" "Passed" "$baseline_passed" "$new_passed" "$(format_diff $diff_passed)"
printf "%-22s %-13s %-13s %s\n" "Failed" "$baseline_failed" "$new_failed" "$(format_diff $diff_failed)"
printf "%-22s %-13s %-13s %s\n" "Skipped" "$baseline_skipped" "$new_skipped" "$(format_diff $diff_skipped)"
printf "%-22s %-13s %-13s\n" "Pass Rate" "${baseline_pass_rate}%" "${new_pass_rate}%"
echo ""

# Determine overall status
status="UNKNOWN"
status_color=$NC

if [ "$new_passed" -ge "$baseline_passed" ] && [ "$new_failed" -le "$baseline_failed" ]; then
    if [ "$new_passed" -gt "$baseline_passed" ] || [ "$new_failed" -lt "$baseline_failed" ]; then
        status="✅ IMPROVED"
        status_color=$GREEN
    else
        status="✅ MAINTAINED"
        status_color=$GREEN
    fi
elif [ "$new_passed" -eq "$baseline_passed" ] && [ "$new_failed" -eq "$baseline_failed" ]; then
    status="✅ MAINTAINED"
    status_color=$GREEN
else
    status="❌ REGRESSION"
    status_color=$RED
fi

echo -e "${BLUE}Overall Status:${NC} ${status_color}${status}${NC}"
echo ""

# Check critical constraints
echo -e "${BLUE}Critical Constraints Check:${NC}"
echo "================================================================"

# Constraint 1: Pass rate >= 97.4%
pass_rate_check="FAIL"
pass_rate_color=$RED
if [ "$(echo "$new_pass_rate >= 97.4" | bc)" -eq 1 ]; then
    pass_rate_check="PASS"
    pass_rate_color=$GREEN
fi
echo -e "  Pass Rate ≥97.4%:        ${pass_rate_color}${pass_rate_check}${NC} (${new_pass_rate}%)"

# Constraint 2: No new test failures
new_failures_check="FAIL"
new_failures_color=$RED
if [ "$new_failed" -le "$baseline_failed" ]; then
    new_failures_check="PASS"
    new_failures_color=$GREEN
fi
echo -e "  No New Failures:         ${new_failures_color}${new_failures_check}${NC} ($diff_failed)"

# Constraint 3: Passing tests maintained
passing_maintained_check="FAIL"
passing_maintained_color=$RED
if [ "$new_passed" -ge "$baseline_passed" ]; then
    passing_maintained_check="PASS"
    passing_maintained_color=$GREEN
fi
echo -e "  Passing Tests ≥Baseline: ${passing_maintained_color}${passing_maintained_check}${NC} ($new_passed ≥ $baseline_passed)"

echo ""

# Extract newly failing tests
echo -e "${BLUE}Analysis:${NC}"
echo "================================================================"

# Check if we have detailed test results
if grep -q "✗" "$NEW_TEST_LOG"; then
    new_failing_count=$(grep "✗" "$NEW_TEST_LOG" | wc -l)
    echo -e "  Detected ${RED}$new_failing_count${NC} failing test cases in log"

    if [ "$new_failing_count" -gt 10 ]; then
        echo -e "  ${YELLOW}Showing first 10 failures:${NC}"
        grep "✗" "$NEW_TEST_LOG" | head -10
        echo -e "  ${YELLOW}... and $(($new_failing_count - 10)) more${NC}"
    else
        echo -e "  ${YELLOW}Failing tests:${NC}"
        grep "✗" "$NEW_TEST_LOG"
    fi
else
    echo "  No detailed test failure information available"
fi

echo ""

# Final recommendation
echo -e "${BLUE}Recommendation:${NC}"
echo "================================================================"

if [ "$status" = "✅ IMPROVED" ] || [ "$status" = "✅ MAINTAINED" ]; then
    echo -e "${GREEN}✓ Changes are acceptable for merge${NC}"
    echo "  All critical constraints satisfied."
    echo "  Test suite stability maintained or improved."
    exit 0
else
    echo -e "${RED}✗ Changes require fixes before merge${NC}"
    echo "  Critical constraints violated:"

    if [ "$pass_rate_check" = "FAIL" ]; then
        echo "    - Pass rate below 97.4%"
    fi
    if [ "$new_failures_check" = "FAIL" ]; then
        echo "    - New test failures introduced"
    fi
    if [ "$passing_maintained_check" = "FAIL" ]; then
        echo "    - Previously passing tests now failing"
    fi

    echo ""
    echo "  Action required:"
    echo "    1. Investigate failing tests in: $NEW_TEST_LOG"
    echo "    2. Fix root causes (never mock responses)"
    echo "    3. Rerun tests until all constraints satisfied"
    echo "    4. Update this comparison when tests pass"

    exit 1
fi
