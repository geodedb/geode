#!/bin/bash

# Master regression test runner for Geode
# Runs all regression test suites

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Track results
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
declare -a FAILED_SUITES

# Function to run a test suite
run_suite() {
    local suite_name="$1"
    local suite_script="$2"
    
    echo -e "\n${BLUE}===============================================${NC}"
    echo -e "${BLUE}Running: $suite_name${NC}"
    echo -e "${BLUE}===============================================${NC}\n"
    
    if [ -f "$suite_script" ]; then
        if bash "$suite_script"; then
            echo -e "\n${GREEN}✓ $suite_name completed successfully${NC}"
            ((PASSED_TESTS++))
        else
            echo -e "\n${RED}✗ $suite_name failed${NC}"
            ((FAILED_TESTS++))
            FAILED_SUITES+=("$suite_name")
        fi
    else
        echo -e "${YELLOW}Warning: $suite_script not found${NC}"
        ((FAILED_TESTS++))
        FAILED_SUITES+=("$suite_name (not found)")
    fi
    ((TOTAL_TESTS++))
}

# Main execution
echo -e "${YELLOW}╔══════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║     Geode Regression Test Suite Runner       ║${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════════════╝${NC}"

# Check if server is built
if [ ! -f "./zig-out/bin/geoded" ]; then
    echo -e "${YELLOW}Building Geode...${NC}"
    zig build
fi

# Run existing comprehensive test
if [ -f "./tests/comprehensive_regression_test.sh" ]; then
    run_suite "Comprehensive Regression Tests" "./tests/comprehensive_regression_test.sh"
fi

# Run LIMIT/SKIP tests
if [ -f "./tests/limit_skip_regression_test.sh" ]; then
    run_suite "LIMIT/SKIP Regression Tests" "./tests/limit_skip_regression_test.sh"
fi

# Run property ordering tests
if [ -f "./tests/property_ordering_regression_test.sh" ]; then
    run_suite "Property Ordering Tests" "./tests/property_ordering_regression_test.sh"
fi

# Run count aggregation tests
if [ -f "./tests/count_aggregation_regression_test.sh" ]; then
    run_suite "Count Aggregation Tests" "./tests/count_aggregation_regression_test.sh"
fi

# Run new test suites
run_suite "Index Operations Tests" "./tests/index_regression_test.sh"
run_suite "Backup/Restore Tests" "./tests/backup_restore_regression_test.sh"
run_suite "Variable Path Tests" "./tests/variable_path_regression_test.sh"

# Summary
echo -e "\n${BLUE}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              Test Summary                    ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"

echo -e "\nTotal test suites run: ${TOTAL_TESTS}"
echo -e "${GREEN}Passed: ${PASSED_TESTS}${NC}"
echo -e "${RED}Failed: ${FAILED_TESTS}${NC}"

if [ ${#FAILED_SUITES[@]} -gt 0 ]; then
    echo -e "\n${RED}Failed suites:${NC}"
    for suite in "${FAILED_SUITES[@]}"; do
        echo -e "  ${RED}• $suite${NC}"
    done
    exit 1
else
    echo -e "\n${GREEN}✓ All regression tests passed!${NC}"
fi

# Cleanup any leftover processes
pkill -f geoded 2>/dev/null || true

echo -e "\n${GREEN}Regression testing complete!${NC}"