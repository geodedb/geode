#!/usr/bin/env bash
# Master Test Runner for Geode
# Executes all comprehensive test suites and provides aggregate results

set -e

echo "=========================================="
echo "    GEODE COMPREHENSIVE TEST SUITE"
echo "=========================================="
echo "Running complete validation of all Geode features"
echo "Started: $(date)"
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Test suite paths
TESTS_DIR="$(dirname "$0")"
TEST_SUITES=(
    "comprehensive_working_features_test.sh"
    "advanced_graph_patterns_test.sh"
    "performance_validation_test.sh"
    "comprehensive_data_types_test.sh"
    "complex_query_patterns_test.sh"
    "gql_language_features_test.sh"
    "error_handling_edge_cases_test.sh"
    "advanced_graph_algorithms_test.sh"
    "security_validation_test.sh"
)

# Results tracking
TOTAL_SUITES=${#TEST_SUITES[@]}
PASSED_SUITES=0
FAILED_SUITES=0
SKIPPED_SUITES=0

# Aggregate statistics
TOTAL_TESTS=0
TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_ERRORS_HANDLED=0

# Individual suite results
declare -A SUITE_RESULTS
declare -A SUITE_SCORES
declare -A SUITE_TIMES

# Function to run a test suite
run_test_suite() {
    local suite_name="$1"
    local suite_path="$TESTS_DIR/$suite_name"

    echo -e "${CYAN}================================================${NC}"
    echo -e "${BOLD}Running: $suite_name${NC}"
    echo -e "${CYAN}================================================${NC}"

    if [ ! -f "$suite_path" ]; then
        echo -e "${RED}ERROR: Test suite not found: $suite_path${NC}"
        SKIPPED_SUITES=$((SKIPPED_SUITES + 1))
        SUITE_RESULTS["$suite_name"]="SKIPPED"
        return 1
    fi

    if [ ! -x "$suite_path" ]; then
        echo "Making test suite executable..."
        chmod +x "$suite_path"
    fi

    local start_time=$(date +%s)
    local output_file="/tmp/geode_test_output_$$_$(echo $suite_name | tr '.' '_')"

    # Run the test suite and capture output
    if timeout 600 bash "$suite_path" > "$output_file" 2>&1; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        SUITE_TIMES["$suite_name"]="${duration}s"

        echo -e "${GREEN}✓ $suite_name completed successfully${NC}"
        PASSED_SUITES=$((PASSED_SUITES + 1))
        SUITE_RESULTS["$suite_name"]="PASSED"

        # Extract statistics from output
        extract_suite_stats "$suite_name" "$output_file"

    else
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        SUITE_TIMES["$suite_name"]="${duration}s (failed)"

        echo -e "${RED}✗ $suite_name failed${NC}"
        FAILED_SUITES=$((FAILED_SUITES + 1))
        SUITE_RESULTS["$suite_name"]="FAILED"

        # Show last few lines of output for debugging
        echo -e "${YELLOW}Last 10 lines of output:${NC}"
        tail -10 "$output_file" | sed 's/^/  /'
    fi

    # Always show the summary section if present
    if grep -q "Summary\|Results\|Score" "$output_file"; then
        echo -e "${BLUE}Suite Summary:${NC}"
        grep -A 20 -E "Summary|Results.*Summary|=== .*Results|Score.*:" "$output_file" | head -20 | sed 's/^/  /'
    fi

    echo
    rm -f "$output_file"
}

# Function to extract statistics from test suite output
extract_suite_stats() {
    local suite_name="$1"
    local output_file="$2"

    # Try to extract test counts and scores
    local passed=$(grep -o "passed: [0-9]*\|PASS.*[0-9]*\|✓.*[0-9]*" "$output_file" | grep -o "[0-9]*" | tail -1)
    local failed=$(grep -o "failed: [0-9]*\|FAIL.*[0-9]*\|✗.*[0-9]*" "$output_file" | grep -o "[0-9]*" | tail -1)
    local error_handled=$(grep -o "correctly handled: [0-9]*\|handled: [0-9]*" "$output_file" | grep -o "[0-9]*" | tail -1)
    local score=$(grep -o "[0-9]*%" "$output_file" | tail -1 | tr -d '%')

    # Update totals if we found numbers
    if [[ "$passed" =~ ^[0-9]+$ ]]; then
        TOTAL_PASSED=$((TOTAL_PASSED + passed))
        TOTAL_TESTS=$((TOTAL_TESTS + passed))
    fi

    if [[ "$failed" =~ ^[0-9]+$ ]]; then
        TOTAL_FAILED=$((TOTAL_FAILED + failed))
        TOTAL_TESTS=$((TOTAL_TESTS + failed))
    fi

    if [[ "$error_handled" =~ ^[0-9]+$ ]]; then
        TOTAL_ERRORS_HANDLED=$((TOTAL_ERRORS_HANDLED + error_handled))
        TOTAL_TESTS=$((TOTAL_TESTS + error_handled))
    fi

    if [[ "$score" =~ ^[0-9]+$ ]]; then
        SUITE_SCORES["$suite_name"]="${score}%"
    else
        SUITE_SCORES["$suite_name"]="N/A"
    fi
}

# Main execution
echo "Building Geode before running tests..."
if ! make build > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Failed to build Geode${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Build successful${NC}"
echo

# Run all test suites
for suite in "${TEST_SUITES[@]}"; do
    run_test_suite "$suite"

    # Brief pause between suites
    sleep 2
done

echo
echo "=========================================="
echo "           FINAL RESULTS SUMMARY"
echo "=========================================="
echo

# Test Suites Summary
echo -e "${BOLD}Test Suites Results:${NC}"
echo "┌─────────────────────────────────────────────┬─────────┬─────────┬──────────┐"
echo "│ Test Suite                                  │ Status  │ Score   │ Duration │"
echo "├─────────────────────────────────────────────┼─────────┼─────────┼──────────┤"

for suite in "${TEST_SUITES[@]}"; do
    local status="${SUITE_RESULTS[$suite]:-UNKNOWN}"
    local score="${SUITE_SCORES[$suite]:-N/A}"
    local time="${SUITE_TIMES[$suite]:-N/A}"

    # Color code the status
    local status_colored
    case "$status" in
        "PASSED") status_colored="${GREEN}PASSED${NC}" ;;
        "FAILED") status_colored="${RED}FAILED${NC}" ;;
        "SKIPPED") status_colored="${YELLOW}SKIPPED${NC}" ;;
        *) status_colored="$status" ;;
    esac

    printf "│ %-43s │ %-15s │ %-7s │ %-8s │\n" "$suite" "$status_colored" "$score" "$time"
done

echo "└─────────────────────────────────────────────┴─────────┴─────────┴──────────┘"
echo

# Overall Statistics
echo -e "${BOLD}Overall Test Statistics:${NC}"
echo "┌─────────────────────────────────┬───────────┐"
echo "│ Metric                          │ Count     │"
echo "├─────────────────────────────────┼───────────┤"
printf "│ %-31s │ %-9s │\n" "Total Test Suites" "$TOTAL_SUITES"
printf "│ %-31s │ ${GREEN}%-9s${NC} │\n" "Suites Passed" "$PASSED_SUITES"
printf "│ %-31s │ ${RED}%-9s${NC} │\n" "Suites Failed" "$FAILED_SUITES"
printf "│ %-31s │ ${YELLOW}%-9s${NC} │\n" "Suites Skipped" "$SKIPPED_SUITES"
echo "├─────────────────────────────────┼───────────┤"
printf "│ %-31s │ %-9s │\n" "Total Individual Tests" "$TOTAL_TESTS"
printf "│ %-31s │ ${GREEN}%-9s${NC} │\n" "Tests Passed" "$TOTAL_PASSED"
printf "│ %-31s │ ${RED}%-9s${NC} │\n" "Tests Failed" "$TOTAL_FAILED"
printf "│ %-31s │ ${BLUE}%-9s${NC} │\n" "Errors Correctly Handled" "$TOTAL_ERRORS_HANDLED"
echo "└─────────────────────────────────┴───────────┘"
echo

# Calculate overall scores
suite_success_rate=0
test_success_rate=0

if [ $TOTAL_SUITES -gt 0 ]; then
    suite_success_rate=$((PASSED_SUITES * 100 / TOTAL_SUITES))
fi

if [ $TOTAL_TESTS -gt 0 ]; then
    local successful_tests=$((TOTAL_PASSED + TOTAL_ERRORS_HANDLED))
    test_success_rate=$((successful_tests * 100 / TOTAL_TESTS))
fi

echo -e "${BOLD}Success Rates:${NC}"
echo "┌─────────────────────────────────┬───────────┐"
echo "│ Category                        │ Rate      │"
echo "├─────────────────────────────────┼───────────┤"

# Color code success rates
local suite_rate_colored
if [ $suite_success_rate -ge 90 ]; then
    suite_rate_colored="${GREEN}${suite_success_rate}%${NC}"
elif [ $suite_success_rate -ge 75 ]; then
    suite_rate_colored="${YELLOW}${suite_success_rate}%${NC}"
else
    suite_rate_colored="${RED}${suite_success_rate}%${NC}"
fi

local test_rate_colored
if [ $test_success_rate -ge 90 ]; then
    test_rate_colored="${GREEN}${test_success_rate}%${NC}"
elif [ $test_success_rate -ge 75 ]; then
    test_rate_colored="${YELLOW}${test_success_rate}%${NC}"
else
    test_rate_colored="${RED}${test_success_rate}%${NC}"
fi

printf "│ %-31s │ %-15s │\n" "Test Suite Success Rate" "$suite_rate_colored"
printf "│ %-31s │ %-15s │\n" "Individual Test Success Rate" "$test_rate_colored"
echo "└─────────────────────────────────┴───────────┘"
echo

# Feature Coverage Assessment
echo -e "${BOLD}Feature Coverage Assessment:${NC}"

declare -A coverage_areas=(
    ["Core GQL Language"]="gql_language_features_test.sh"
    ["Data Types"]="comprehensive_data_types_test.sh"
    ["Graph Patterns"]="advanced_graph_patterns_test.sh"
    ["Query Complexity"]="complex_query_patterns_test.sh"
    ["Performance"]="performance_validation_test.sh"
    ["Error Handling"]="error_handling_edge_cases_test.sh"
    ["Graph Algorithms"]="advanced_graph_algorithms_test.sh"
    ["Security"]="security_validation_test.sh"
    ["Core Features"]="comprehensive_working_features_test.sh"
)

echo "┌─────────────────────────────────┬─────────────────┐"
echo "│ Feature Area                    │ Coverage Status │"
echo "├─────────────────────────────────┼─────────────────┤"

for area in "${!coverage_areas[@]}"; do
    local suite="${coverage_areas[$area]}"
    local status="${SUITE_RESULTS[$suite]:-UNKNOWN}"

    local status_icon
    case "$status" in
        "PASSED") status_icon="${GREEN}✓ Covered${NC}" ;;
        "FAILED") status_icon="${RED}✗ Issues${NC}" ;;
        "SKIPPED") status_icon="${YELLOW}○ Skipped${NC}" ;;
        *) status_icon="? Unknown" ;;
    esac

    printf "│ %-31s │ %-23s │\n" "$area" "$status_icon"
done

echo "└─────────────────────────────────┴─────────────────┘"
echo

# Overall Assessment
echo -e "${BOLD}OVERALL GEODE ASSESSMENT:${NC}"
echo

if [ $suite_success_rate -ge 90 ] && [ $test_success_rate -ge 90 ]; then
    echo -e "${GREEN}🎉 EXCELLENT: Geode demonstrates excellent stability and feature completeness!${NC}"
    echo -e "${GREEN}   All major features are working correctly with comprehensive test coverage.${NC}"
elif [ $suite_success_rate -ge 75 ] && [ $test_success_rate -ge 75 ]; then
    echo -e "${YELLOW}✅ GOOD: Geode shows good overall functionality with minor issues.${NC}"
    echo -e "${YELLOW}   Most features work correctly, with some areas needing attention.${NC}"
elif [ $suite_success_rate -ge 50 ] && [ $test_success_rate -ge 50 ]; then
    echo -e "${YELLOW}⚠️  ACCEPTABLE: Geode has basic functionality but needs improvement.${NC}"
    echo -e "${YELLOW}   Several features need fixes before production readiness.${NC}"
else
    echo -e "${RED}❌ POOR: Geode has significant stability and functionality issues.${NC}"
    echo -e "${RED}   Major development work needed before deployment.${NC}"
fi

echo
echo "Test Coverage Areas:"
echo "✓ Graph Query Language (GQL) compliance"
echo "✓ Comprehensive data type support (50+ types)"
echo "✓ Advanced graph pattern matching"
echo "✓ Complex query optimization"
echo "✓ Performance validation"
echo "✓ Error handling and robustness"
echo "✓ Graph algorithms and analytics"
echo "✓ Security and input validation"
echo "✓ Core database functionality"

echo
echo "=========================================="
echo "Completed: $(date)"
echo "Total Runtime: $(printf '%02d:%02d' $((SECONDS/60)) $((SECONDS%60)))"
echo "=========================================="

# Exit with appropriate code
if [ $FAILED_SUITES -eq 0 ] && [ $suite_success_rate -ge 75 ]; then
    exit 0
else
    exit 1
fi
