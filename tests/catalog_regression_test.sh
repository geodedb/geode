#!/bin/bash
set -euo pipefail

# CANARY: REQ=REQ-GQL-CATALOG-005; FEATURE="Catalog Regression Test Suite"; ASPECT=TestAutomation; STATUS=EXEMPT; TEST=CatalogRegressionSuite; OWNER=testing; UPDATED=2025-10-04

echo "=== Geode Catalog Operations Regression Test Suite ==="
echo "Testing enhanced GQL catalog operations functionality"
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
GEODE_ROOT="$(dirname "$SCRIPT_DIR")"
GEODE_BIN="$GEODE_ROOT/zig-out/bin/geode"

# Check if geode binary exists
if [ ! -f "$GEODE_BIN" ]; then
    echo -e "${RED}ERROR: Geode binary not found at $GEODE_BIN${NC}"
    echo "Please run 'zig build' first"
    exit 1
fi

SERVER_PORT=8454
ADMIN_USER="${GEODE_ADMIN_USERNAME:-geode}"
ADMIN_PASS="${GEODE_DEFAULT_PASSWORD:-Geode Test Admin Passphrase}"
DATA_DIR=$(mktemp -d /tmp/geode_catalog_regression_XXXXXX)
GEODE_ADMIN_USERNAME="${ADMIN_USER}" GEODE_DEFAULT_PASSWORD="${ADMIN_PASS}" \
    "$GEODE_BIN" serve --listen 127.0.0.1:${SERVER_PORT} --data-dir "${DATA_DIR}" > /tmp/geode_catalog_regression.log 2>&1 &
SERVER_PID=$!
sleep 2

cleanup() {
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
    rm -rf "${DATA_DIR}"
    rm -f /tmp/geode_catalog_regression.log
}
trap cleanup EXIT

SERVER_ADDR="127.0.0.1:${SERVER_PORT}"

# Test counter
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Function to run a test
run_test() {
    local test_name="$1"
    local query="$2"
    local expected_pattern="$3"
    local should_fail="${4:-false}"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo -n "Test $TOTAL_TESTS: $test_name... "

    # Run the query
    if [ "$should_fail" = "true" ]; then
        # Test should fail
        if "$GEODE_BIN" query --server "$SERVER_ADDR" "$query" --insecure --user "${ADMIN_USER}" --password "${ADMIN_PASS}" >/dev/null 2>&1; then
            echo -e "${RED}FAIL${NC} (expected failure but succeeded)"
            FAILED_TESTS=$((FAILED_TESTS + 1))
            return 1
        else
            echo -e "${GREEN}PASS${NC} (correctly failed)"
            PASSED_TESTS=$((PASSED_TESTS + 1))
            return 0
        fi
    else
        # Test should succeed
        local output
        output=$("$GEODE_BIN" query --server "$SERVER_ADDR" "$query" --insecure --user "${ADMIN_USER}" --password "${ADMIN_PASS}" 2>&1)
        local exit_code=$?

        if [ $exit_code -eq 0 ]; then
            if echo "$output" | grep -q "$expected_pattern"; then
                echo -e "${GREEN}PASS${NC}"
                PASSED_TESTS=$((PASSED_TESTS + 1))
                return 0
            else
                echo -e "${RED}FAIL${NC} (success but wrong output)"
                echo "Expected: $expected_pattern"
                echo "Got: $output"
                FAILED_TESTS=$((FAILED_TESTS + 1))
                return 1
            fi
        else
            echo -e "${RED}FAIL${NC} (exit code: $exit_code)"
            echo "Output: $output"
            FAILED_TESTS=$((FAILED_TESTS + 1))
            return 1
        fi
    fi
}

echo "=== Testing Enhanced Catalog Operations ==="
echo

# Test 1: TYPED clause
run_test "CREATE GRAPH with TYPED ANY" \
    "CREATE GRAPH typed_regression_test TYPED ANY" \
    "\"status_class\":\"00000\""

# Test 2: AS COPY OF clause (need source graph first)
run_test "CREATE source graph for COPY OF test" \
    "CREATE GRAPH copy_source_regression ANY" \
    "\"status_class\":\"00000\""

run_test "CREATE GRAPH with AS COPY OF" \
    "CREATE GRAPH copy_target_regression ANY AS COPY OF copy_source_regression" \
    "\"status_class\":\"00000\""

# Test 3: OR REPLACE with TYPED
run_test "CREATE initial graph for REPLACE test" \
    "CREATE GRAPH replace_regression_test TYPED ANY" \
    "\"status_class\":\"00000\""

run_test "CREATE OR REPLACE GRAPH with TYPED" \
    "CREATE OR REPLACE GRAPH replace_regression_test TYPED ANY" \
    "\"status_class\":\"00000\""

# Test 4: PROPERTY GRAPH with TYPED
run_test "CREATE PROPERTY GRAPH with TYPED" \
    "CREATE PROPERTY GRAPH property_regression_test TYPED ANY PROPERTY GRAPH" \
    "\"status_class\":\"00000\""

# Test 5: Backward compatibility
run_test "Traditional CREATE GRAPH (backward compatibility)" \
    "CREATE GRAPH backward_regression_test ANY" \
    "\"status_class\":\"00000\""

# Test 6: IF NOT EXISTS with TYPED
run_test "CREATE GRAPH IF NOT EXISTS with TYPED" \
    "CREATE GRAPH IF NOT EXISTS conditional_regression_test TYPED ANY" \
    "\"status_class\":\"00000\""

# Test 7: Error cases
echo
echo "=== Testing Error Cases ==="
echo

run_test "Invalid TYPED syntax (should fail)" \
    "CREATE GRAPH invalid_typed_test TYPED" \
    "" \
    "true"

run_test "Invalid AS COPY OF syntax (should fail)" \
    "CREATE GRAPH invalid_copy_test AS COPY" \
    "" \
    "true"

run_test "Incomplete AS COPY OF syntax (should fail)" \
    "CREATE GRAPH incomplete_copy AS COPY" \
    "" \
    "true"

# Test 8: Schema operations (ensure still working)
echo
echo "=== Testing Schema Operations (regression) ==="
echo

run_test "CREATE SCHEMA" \
    "CREATE SCHEMA regression_test_schema" \
    "\"status_class\":\"00000\""

run_test "CREATE and DROP SCHEMA (single operation)" \
    "CREATE SCHEMA temp_schema; DROP SCHEMA temp_schema" \
    "\"status_class\":\"00000\""

# Test 9: Basic graph operations (ensure still working)
echo
echo "=== Testing Basic Graph Operations (regression) ==="
echo

run_test "CREATE basic GRAPH" \
    "CREATE GRAPH basic_regression_test ANY" \
    "\"status_class\":\"00000\""

run_test "DROP GRAPH IF EXISTS" \
    "DROP GRAPH IF EXISTS basic_regression_test" \
    "\"status_class\":\"00000\""

# Summary
echo
echo "=== Test Results Summary ==="
echo "Total tests: $TOTAL_TESTS"
echo -e "Passed: ${GREEN}$PASSED_TESTS${NC}"
echo -e "Failed: ${RED}$FAILED_TESTS${NC}"

if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}$FAILED_TESTS test(s) failed${NC}"
    exit 1
fi
