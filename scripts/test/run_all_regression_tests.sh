#!/usr/bin/env bash

# CANARY: REQ=REQ-TEST-SUITE-001; FEATURE="Comprehensive Regression Test Suite"; ASPECT=QualityAssurance; STATUS=TESTED; TEST=TestCANARY_REQ_TEST_SUITE_001_AllRegressionTests; OWNER=testing; UPDATED=2025-10-04

set -e

echo "=== Comprehensive Geode Regression Test Suite ==="
echo "Testing CLI improvements, working directory handling, and core functionality"
echo

# Ensure we're in the project root
if [[ ! -f "./zig-out/bin/geode" ]]; then
    echo "ERROR: Must run from Geode project root directory"
    echo "Current directory: $(pwd)"
    echo "Expected: geode binary at ./zig-out/bin/geode"
    exit 1
fi

# Build the project first
echo "Building Geode..."
if ! zig build; then
    echo "ERROR: Build failed"
    exit 1
fi
echo "✓ Build successful"
echo

# Track test results
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
FAILED_TEST_NAMES=()

# Function to run a test and track results
run_test() {
    local test_name="$1"
    local test_script="$2"
    
    echo "Running $test_name..."
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    if $test_script; then
        echo "✓ $test_name PASSED"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo "✗ $test_name FAILED"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        FAILED_TEST_NAMES+=("$test_name")
    fi
    echo
}

# 1. Basic CLI working directory tests
if [[ -f "./tests/cli_working_directory_regression_test.sh" ]]; then
    run_test "CLI Working Directory" "./tests/cli_working_directory_regression_test.sh"
else
    echo "⚠ CLI Working Directory test not found"
fi

# 2. Query option auto-routing tests  
if [[ -f "./tests/query_option_autorouting_regression_test.sh" ]]; then
    run_test "Query Option Auto-routing" "./tests/query_option_autorouting_regression_test.sh"
else
    echo "⚠ Query Option Auto-routing test not found"
fi

# 3. Basic GQL auto-detection (simplified version to avoid hanging issues)
if [[ -f "./tests/cli_gql_autodetection_basic_test.sh" ]]; then
    run_test "Basic GQL Auto-detection" "timeout 30 ./tests/cli_gql_autodetection_basic_test.sh"
else
    echo "⚠ Basic GQL Auto-detection test not found"
fi

# 4. Catalog operations regression tests
if [[ -f "./tests/catalog_regression_test.sh" ]]; then
    run_test "Catalog Operations" "./tests/catalog_regression_test.sh"
else
    echo "⚠ Catalog Operations test not found"
fi

# 5. Quick overall test suite (geodetestlab)
echo "Running Quick Test Suite (representative sample)..."
TOTAL_TESTS=$((TOTAL_TESTS + 1))
if python3 quick_test_runner.py > /tmp/quick_test_results.txt 2>&1; then
    pass_rate=$(grep "Pass rate:" /tmp/quick_test_results.txt | tail -1 | cut -d: -f2 | tr -d ' %')
    echo "✓ Quick Test Suite PASSED (Pass rate: ${pass_rate}%)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    echo "✗ Quick Test Suite FAILED"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("Quick Test Suite")
    # Show last few lines of output for debugging
    echo "Last 10 lines of output:"
    tail -10 /tmp/quick_test_results.txt
fi
echo

# Summary
echo "=== Regression Test Results ==="
echo "Total Tests: $TOTAL_TESTS"
echo "Passed: $PASSED_TESTS"
echo "Failed: $FAILED_TESTS"

if [[ $FAILED_TESTS -eq 0 ]]; then
    echo "🎉 ALL REGRESSION TESTS PASSED!"
    exit 0
else
    echo "❌ Some tests failed:"
    for test_name in "${FAILED_TEST_NAMES[@]}"; do
        echo "  - $test_name"
    done
    exit 1
fi