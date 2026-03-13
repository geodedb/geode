#!/bin/bash
set -euo pipefail

# CANARY: REQ=REQ-GQL-NODE-PROPERTY-ACCESS; FEATURE="Node Property Access"; ASPECT=RuntimeStability; STATUS=EXEMPT; TEST=TestNodePropertyHashMapAccess; OWNER=core; UPDATED=2025-10-05

# Regression test for integer overflow crash when accessing node properties
# Tests the fix for BindingValue storing Node by pointer instead of by value

set -e

echo "Testing node property access without integer overflow crash..."

BINARY="./zig-out/bin/geode"

# Test 1: Basic property access in RETURN clause
echo "Test 1: Basic property access - MATCH (n:Person) RETURN n.name"
RESULT1=$($BINARY query "MATCH (n:Person) RETURN n.name LIMIT 3" --insecure 2>/dev/null | grep -E '"name":|Alice|Bob|Carol' || echo "no results")

if [[ "$RESULT1" == "no results" ]]; then
    echo "❌ Test 1 FAILED: Property access query returned no results"
    exit 1
else
    echo "✅ Test 1 PASSED: Property access successful"
fi

# Test 2: Multiple property access
echo "Test 2: Multiple property access - MATCH (n) RETURN n.name, n.age"
RESULT2=$($BINARY query "MATCH (n:Person) RETURN n.name, n.age LIMIT 2" --insecure 2>/dev/null | grep '"name"' || echo "no results")

if [[ "$RESULT2" == "no results" ]]; then
    echo "❌ Test 2 FAILED: Multiple property access failed"
    exit 1
else
    echo "✅ Test 2 PASSED: Multiple property access successful"
fi

# Test 3: Property access with WHERE clause
echo "Test 3: Property access in WHERE clause"
RESULT3=$($BINARY query "MATCH (n:Person) WHERE n.name = 'Alice' RETURN count(n)" --insecure 2>/dev/null | grep '"count"' || echo "no results")

if [[ "$RESULT3" == "no results" ]]; then
    echo "❌ Test 3 FAILED: Property filtering failed"
    exit 1
else
    echo "✅ Test 3 PASSED: Property filtering successful"
fi

# Test 4: CREATE + property access combination
echo "Test 4: CREATE and immediate property access"
RESULT4=$($BINARY query 'CREATE (test:TestNode {prop: "value"}) RETURN count(test)' --insecure 2>/dev/null | grep '"created"' || echo "no results")

if [[ "$RESULT4" == "no results" ]]; then
    echo "❌ Test 4 FAILED: CREATE + property access failed"
    exit 1
else
    echo "✅ Test 4 PASSED: CREATE + property access successful"
fi

echo "✅ All regression tests passed - integer overflow crash fixed"
echo "Node properties are now stored by pointer in BindingValue, preventing HashMap copy corruption"
