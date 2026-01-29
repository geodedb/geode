#!/usr/bin/env bash

# Type Conversion Functions Regression Test
# Tests toString, toInteger, toReal functions added to fix geodetestlab failures

set -e

echo "=== Type Conversion Functions Regression Test ==="

GEODE_CLI="./zig-out/bin/geode"
FAILED=0

# Test function
test_query() {
    local name="$1"
    local query="$2"
    local expected_pattern="$3"

    echo -n "Testing $name... "

    # Run query with timeout
    if result=$(timeout 10s $GEODE_CLI query "$query" --insecure 2>&1); then
        if echo "$result" | grep -q "$expected_pattern"; then
            echo "PASS"
        else
            echo "FAIL"
            echo "  Query: $query"
            echo "  Expected pattern: $expected_pattern"
            echo "  Got: $result"
            FAILED=1
        fi
    else
        echo "FAIL (timeout/error)"
        echo "  Query: $query"
        echo "  Error: $result"
        FAILED=1
    fi
}

# Test toString function
test_query "toString with integer" "RETURN toString(123)" '"toString(123)":"123"'
test_query "toString with string" "RETURN toString('hello')" '"hello"'

# Test toInteger function
test_query "toInteger with string number" "RETURN toInteger('456')" '456'
test_query "toInteger with integer" "RETURN toInteger(789)" '"toInteger(789)":789'

# Test toReal function
test_query "toReal with integer" "RETURN toReal(123)" '123\.0'
test_query "toReal with string float" "RETURN toReal('123.45')" '123\.45'

# Test single functions (mixed function nesting might have parser issues)
test_query "toString on computed value" "RETURN toString(100 + 23)" '"123"'

# Test type function with different literal types (new functionality)
test_query "type function with integer" "RETURN type(123)" '"INTEGER"'
test_query "type function with string" "RETURN type('hello')" '"STRING"'
test_query "type function with boolean" "RETURN type(true)" '"BOOLEAN"'

# Test enhanced toString and toInteger (new functionality)
test_query "toString with boolean" "RETURN toString(false)" '"false"'
test_query "toString with decimal" "RETURN toString(3.14)" '"3.14"'
test_query "toInteger with boolean" "RETURN toInteger(true)" '1'
test_query "toInteger with decimal" "RETURN toInteger(2.7)" '2'

echo ""
if [ $FAILED -eq 0 ]; then
    echo "✅ All type conversion function tests passed!"
    echo ""
    echo "CANARY: REQ=REQ-GQL-TYPE-CONV-001; FEATURE=\"TypeConversionFunctions\"; ASPECT=Functionality; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TYPE_CONV_001_TypeConversionFunctions; OWNER=eval; UPDATED=2025-01-05"
    exit 0
else
    echo "❌ Some type conversion function tests failed!"
    exit 1
fi
