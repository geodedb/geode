#!/usr/bin/env bash

# Shared helpers for REPL regression shell suites.
# Eliminates duplicated harness logic across repl_*_regression_test.sh scripts.

set -euo pipefail

REPL_TOTAL_TESTS=0
REPL_PASSED_TESTS=0
REPL_FAILED_TESTS=0
declare -a REPL_FAILED_TEST_NAMES=()

REPL_RED='\033[0;31m'
REPL_GREEN='\033[0;32m'
REPL_NC='\033[0m'

: "${REPL_TEST_TIMEOUT:=30}"

repl_suite_header() {
    local title="$1"
    local divider="$2"
    echo "$title"
    echo "$divider"
}

repl_require_binary() {
    local binary_path="$1"
    if [ ! -x "$binary_path" ]; then
        echo "❌ Error: geode binary not found at $binary_path"
        echo "   Please run 'zig build' first"
        exit 1
    fi
    echo "📍 Using binary: $binary_path"
    echo ""
}

repl_run_test() {
    local test_name="$1"
    local test_command="$2"
    local expected_pattern="${3:-}"
    local should_contain="${4:-true}"

    REPL_TOTAL_TESTS=$((REPL_TOTAL_TESTS + 1))
    echo -n "  Testing $test_name... "

    local output=""
    if ! output=$(timeout "$REPL_TEST_TIMEOUT" bash -lc "$test_command" 2>&1); then
        echo -e "${REPL_RED}FAIL${REPL_NC} (command failed or timed out)"
        echo "    Command: $test_command"
        echo "    Output: $output"
        REPL_FAILED_TESTS=$((REPL_FAILED_TESTS + 1))
        REPL_FAILED_TEST_NAMES+=("$test_name")
        return 1
    fi

    if [ -n "$expected_pattern" ]; then
        local has_match="false"
        if echo "$output" | grep -Eq "$expected_pattern"; then
            has_match="true"
        fi

        if [ "$should_contain" = "true" ] && [ "$has_match" != "true" ]; then
            echo -e "${REPL_RED}FAIL${REPL_NC} (expected pattern not found)"
            echo "    Expected: $expected_pattern"
            echo "    Got: $output"
            REPL_FAILED_TESTS=$((REPL_FAILED_TESTS + 1))
            REPL_FAILED_TEST_NAMES+=("$test_name")
            return 1
        fi

        if [ "$should_contain" != "true" ] && [ "$has_match" = "true" ]; then
            echo -e "${REPL_RED}FAIL${REPL_NC} (unexpected pattern found)"
            echo "    Unexpected: $expected_pattern"
            echo "    Got: $output"
            REPL_FAILED_TESTS=$((REPL_FAILED_TESTS + 1))
            REPL_FAILED_TEST_NAMES+=("$test_name")
            return 1
        fi
    fi

    echo -e "${REPL_GREEN}PASS${REPL_NC}"
    REPL_PASSED_TESTS=$((REPL_PASSED_TESTS + 1))
    return 0
}

repl_suite_summary() {
    echo ""
    echo "📊 Test Results"
    echo "==============="
    echo "Total tests: $REPL_TOTAL_TESTS"
    echo -e "Passed: ${REPL_GREEN}$REPL_PASSED_TESTS${REPL_NC}"
    echo -e "Failed: ${REPL_RED}$REPL_FAILED_TESTS${REPL_NC}"
    echo ""

    if [ "$REPL_FAILED_TESTS" -eq 0 ]; then
        echo -e "${REPL_GREEN}✅ All REPL regression tests passed!${REPL_NC}"
        return 0
    fi

    echo -e "${REPL_RED}❌ Some REPL regression tests failed${REPL_NC}"
    echo "Failed tests:"
    for test_name in "${REPL_FAILED_TEST_NAMES[@]}"; do
        echo "  - $test_name"
    done
    return 1
}
