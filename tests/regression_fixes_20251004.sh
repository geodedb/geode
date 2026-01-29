#!/usr/bin/env bash

# Regression tests for fixes applied on 2025-10-04
# These tests ensure that previously fixed issues don't regress

set -e

GEODE_BIN="./zig-out/bin/geode"
PASSED=0
FAILED=0

# Test helper functions
test_case() {
    local test_name="$1"
    local expected_exit="$2"
    shift 2
    local cmd=("$@")

    echo -n "Testing $test_name... "

    if "${cmd[@]}" >/dev/null 2>&1; then
        actual_exit=0
    else
        actual_exit=$?
    fi

    if [ "$actual_exit" -eq "$expected_exit" ]; then
        echo "PASS"
        ((PASSED++))
    else
        echo "FAIL (expected exit $expected_exit, got $actual_exit)"
        ((FAILED++))
    fi
}

test_output_contains() {
    local test_name="$1"
    local expected_pattern="$2"
    shift 2
    local cmd=("$@")

    echo -n "Testing $test_name... "

    local output
    output=$("${cmd[@]}" 2>&1)

    if echo "$output" | grep -q "$expected_pattern"; then
        echo "PASS"
        ((PASSED++))
    else
        echo "FAIL (output does not contain '$expected_pattern')"
        echo "Output: $output"
        ((FAILED++))
    fi
}

echo "=== Regression Tests for 2025-10-04 Fixes ==="
echo

# Fix 1: Auth sessions JSON output
echo "--- Fix 1: Auth Sessions JSON Output ---"
test_output_contains "auth-sessions-json" '{"sessions"' "$GEODE_BIN" auth sessions

# Fix 2: GQL parser keyword aliases
echo "--- Fix 2: GQL Parser Keyword Aliases ---"
test_case "keyword-alias-from" 0 "$GEODE_BIN" query "RETURN 'test' AS from" --insecure
test_case "keyword-alias-to" 0 "$GEODE_BIN" query "RETURN 'test' AS to" --insecure
test_case "keyword-alias-order" 0 "$GEODE_BIN" query "RETURN 'test' AS order" --insecure

# Fix 3: Decimal type evaluation
echo "--- Fix 3: Decimal Type Evaluation ---"
test_case "decimal-literal" 0 "$GEODE_BIN" query "RETURN 123.45 AS decimal_val" --insecure
test_case "negative-decimal" 0 "$GEODE_BIN" query "RETURN -123.45 AS neg_decimal" --insecure

# Fix 4: JSON parameter validation
echo "--- Fix 4: JSON Parameter Validation ---"
test_case "valid-json-param" 0 "$GEODE_BIN" query "RETURN \$value AS result" --json-param value '"hello"' --insecure
test_case "invalid-json-param" 2 "$GEODE_BIN" query "RETURN \$value AS result" --json-param value badvalue --insecure

# Fix 5: Exit code corrections
echo "--- Fix 5: Exit Code Corrections ---"
test_case "invalid-gql-syntax" 1 "$GEODE_BIN" "MATCH (n INVALID SYNTAX" --insecure
test_case "unknown-subcommand" 2 "$GEODE_BIN" unknown-command

# Fix 6: EXPLAIN query functionality
echo "--- Fix 6: EXPLAIN Query Functionality ---"
test_output_contains "explain-output" "EXPLAIN" "$GEODE_BIN" query "EXPLAIN RETURN 1" --insecure

echo
echo "=== Regression Test Summary ==="
echo "PASSED: $PASSED"
echo "FAILED: $FAILED"
echo "TOTAL:  $((PASSED + FAILED))"

if [ "$FAILED" -eq 0 ]; then
    echo "✅ All regression tests passed!"
    exit 0
else
    echo "❌ Some regression tests failed!"
    exit 1
fi
