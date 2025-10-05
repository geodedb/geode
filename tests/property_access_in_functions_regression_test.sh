#!/bin/bash

# Property Access in Functions Regression Test
# Tests that property access within function calls works correctly 
# e.g., toString(n.name), type(n.property), toInteger(n.age)

set -e
set -o pipefail

echo "=== Property Access in Functions Regression Test ==="

# Define geode command
GEODE_CMD="./zig-out/bin/geode query"

# Create test data
echo "Setting up test data..."
$GEODE_CMD "CREATE (test:TestNode {name: 'Alice', age: 30, active: true})" --no-quic > /dev/null 2>&1

# Test toString with property access
echo -n "Testing toString(n.name)... "
result=$($GEODE_CMD "MATCH (n:TestNode {name: 'Alice'}) RETURN toString(n.name)" --no-quic --format table 2>/dev/null | grep "Alice" | wc -l)
if [ "$result" -gt 0 ]; then
    echo "PASS"
else
    echo "FAIL - toString(n.name) did not return expected result"
    exit 1
fi

# Test type function with property access
echo -n "Testing type(n.name)... "
result=$($GEODE_CMD "MATCH (n:TestNode {name: 'Alice'}) RETURN type(n.name)" --no-quic --format table 2>/dev/null | grep "STRING" | wc -l)
if [ "$result" -gt 0 ]; then
    echo "PASS"
else
    echo "FAIL - type(n.name) did not return STRING"
    exit 1
fi

# Test toInteger with property access
echo -n "Testing toInteger(n.age)... "
result=$($GEODE_CMD "MATCH (n:TestNode {name: 'Alice'}) RETURN toInteger(n.age)" --no-quic --format table 2>/dev/null | grep "30" | wc -l)
if [ "$result" -gt 0 ]; then
    echo "PASS"
else
    echo "FAIL - toInteger(n.age) did not return 30"
    exit 1
fi

# Test multiple function calls with property access
echo -n "Testing multiple functions with properties... "
output=$($GEODE_CMD "MATCH (n:TestNode {name: 'Alice'}) RETURN toString(n.name), type(n.age), toInteger(n.age)" --no-quic 2>/dev/null)
alice_count=$(echo "$output" | grep -o "Alice" | wc -l)
integer_count=$(echo "$output" | grep -o "INTEGER" | wc -l)
thirty_count=$(echo "$output" | grep -o "30" | wc -l)
if [ "$alice_count" -gt 0 ] && [ "$integer_count" -gt 0 ] && [ "$thirty_count" -gt 0 ]; then
    echo "PASS"
else
    echo "FAIL - Multiple property function calls failed (Alice: $alice_count, INTEGER: $integer_count, 30: $thirty_count)"
    exit 1
fi

# Test function call with missing property (should return null)
echo -n "Testing function with missing property... "
result=$($GEODE_CMD "MATCH (n:TestNode {name: 'Alice'}) RETURN toString(n.missing_prop)" --no-quic --format table 2>/dev/null | grep "null" | wc -l)
if [ "$result" -gt 0 ]; then
    echo "PASS"
else
    echo "FAIL - Function call with missing property should return null"
    exit 1
fi

# Test type function with boolean property
echo -n "Testing type(n.active) with boolean... "
result=$($GEODE_CMD "MATCH (n:TestNode {name: 'Alice'}) RETURN type(n.active)" --no-quic --format table 2>/dev/null | grep "BOOLEAN" | wc -l)
if [ "$result" -gt 0 ]; then
    echo "PASS"
else
    echo "FAIL - type(n.active) did not return BOOLEAN"
    exit 1
fi

# Test nested property access expressions
echo -n "Testing complex property expressions... "
result=$($GEODE_CMD "MATCH (n:TestNode) WHERE toString(n.name) = 'Alice' RETURN n.name" --no-quic --format table 2>/dev/null | grep "Alice" | wc -l)
if [ "$result" -gt 0 ]; then
    echo "PASS"
else
    echo "FAIL - Complex property expression in WHERE clause failed"
    exit 1
fi

echo ""
echo "✅ All property access in functions tests passed!"
echo ""
echo "CANARY: REQ=REQ-GQL-PROP-FUNC-001; FEATURE=\"PropertyAccessInFunctions\"; ASPECT=Functionality; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_PROP_FUNC_001_PropertyAccessInFunctions; OWNER=eval; UPDATED=2025-01-05"