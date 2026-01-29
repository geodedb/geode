#!/usr/bin/env bash
# Regression test for LIMIT and SKIP behavior
# Tests that LIMIT alone works without ORDER BY, but SKIP requires ORDER BY

set -e

echo "=== LIMIT and SKIP Regression Tests ==="
echo "Testing pagination behavior in Geode"
echo
echo "Context: LIMIT without ORDER BY should be allowed (fixed)"
echo "Context: SKIP/OFFSET requires ORDER BY for deterministic pagination"
echo

# Build first
echo "Building Geode..."
if make build > /dev/null 2>&1; then
    echo "✅ Build successful"
else
    echo "❌ Build failed"
    exit 1
fi
echo

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

run_test() {
    local test_name="$1"
    local query="$2"
    local should_succeed="$3"  # true or false

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo -n "Test $TOTAL_TESTS: $test_name... "

    OUTPUT=$(timeout 3 ./zig-out/bin/geodec "$query" --insecure 2>&1 || true)

    if [ "$should_succeed" = "true" ]; then
        # Should succeed - check for SCHEMA or valid result
        if echo "$OUTPUT" | grep -q '"type":"SCHEMA"\|"type":"BINDINGS"'; then
            echo "✅ PASSED (query succeeded as expected)"
            PASSED_TESTS=$((PASSED_TESTS + 1))
        else
            echo "❌ FAILED (query should have succeeded)"
            echo "   Got: $(echo "$OUTPUT" | grep -E "(ERROR|US001)" | head -1)"
            FAILED_TESTS=$((FAILED_TESTS + 1))
        fi
    else
        # Should fail with US001 error
        if echo "$OUTPUT" | grep -q 'US001\|unordered pagination'; then
            echo "✅ PASSED (correctly rejected with US001)"
            PASSED_TESTS=$((PASSED_TESTS + 1))
        else
            echo "❌ FAILED (should have been rejected with US001)"
            echo "   Got: $(echo "$OUTPUT" | head -1)"
            FAILED_TESTS=$((FAILED_TESTS + 1))
        fi
    fi
}

echo "=== TEST GROUP 1: LIMIT without ORDER BY (should work) ==="
echo

run_test "Simple LIMIT without ORDER BY" \
    "MATCH (n) RETURN n LIMIT 5" \
    "true"

run_test "LIMIT with WHERE but no ORDER BY" \
    "MATCH (n) WHERE n.id > 0 RETURN n LIMIT 10" \
    "true"

run_test "LIMIT on aggregation without ORDER BY" \
    "MATCH (n) RETURN count(n) LIMIT 1" \
    "true"

run_test "LIMIT with complex pattern, no ORDER BY" \
    "MATCH (a)-[r]->(b) RETURN a, b LIMIT 3" \
    "true"

run_test "Small LIMIT without ORDER BY" \
    "MATCH (n) RETURN n.name LIMIT 1" \
    "true"

run_test "LIMIT with properties, no ORDER BY" \
    "MATCH (n) RETURN n.id, n.name, n.age LIMIT 20" \
    "true"

echo
echo "=== TEST GROUP 2: SKIP/OFFSET without ORDER BY (should fail with US001) ==="
echo

run_test "SKIP without ORDER BY" \
    "MATCH (n) RETURN n SKIP 5" \
    "false"

run_test "OFFSET without ORDER BY" \
    "MATCH (n) RETURN n OFFSET 10" \
    "false"

run_test "SKIP with LIMIT but no ORDER BY" \
    "MATCH (n) RETURN n SKIP 5 LIMIT 10" \
    "false"

run_test "OFFSET with LIMIT but no ORDER BY" \
    "MATCH (n) RETURN n OFFSET 10 LIMIT 20" \
    "false"

run_test "SKIP with WHERE but no ORDER BY" \
    "MATCH (n) WHERE n.id > 0 RETURN n SKIP 3" \
    "false"

echo
echo "=== TEST GROUP 3: SKIP/OFFSET with ORDER BY (should work) ==="
echo

run_test "SKIP with ORDER BY" \
    "MATCH (n) RETURN n ORDER BY n.id SKIP 5" \
    "true"

run_test "OFFSET with ORDER BY" \
    "MATCH (n) RETURN n ORDER BY n.name OFFSET 10" \
    "true"

run_test "SKIP and LIMIT with ORDER BY" \
    "MATCH (n) RETURN n ORDER BY n.id SKIP 5 LIMIT 10" \
    "true"

run_test "OFFSET and LIMIT with ORDER BY" \
    "MATCH (n) RETURN n ORDER BY n.age DESC OFFSET 10 LIMIT 20" \
    "true"

run_test "LIMIT and OFFSET with ORDER BY (reverse order)" \
    "MATCH (n) RETURN n ORDER BY n.id LIMIT 20 OFFSET 10" \
    "true"

echo
echo "=== TEST GROUP 4: Edge cases ==="
echo

run_test "LIMIT 0 without ORDER BY" \
    "MATCH (n) RETURN n LIMIT 0" \
    "true"

run_test "SKIP 0 without ORDER BY (still requires ORDER)" \
    "MATCH (n) RETURN n SKIP 0" \
    "false"

run_test "Large LIMIT without ORDER BY" \
    "MATCH (n) RETURN n LIMIT 1000000" \
    "true"

run_test "ORDER BY without LIMIT or SKIP" \
    "MATCH (n) RETURN n ORDER BY n.id" \
    "true"

echo
echo "=== TEST GROUP 5: Complex queries ==="
echo

run_test "Multiple MATCH with LIMIT, no ORDER BY" \
    "MATCH (a), (b) RETURN a, b LIMIT 1" \
    "true"

run_test "Subquery with LIMIT, no ORDER BY" \
    "MATCH (n) WHERE n.id IN [1,2,3] RETURN n LIMIT 2" \
    "true"

run_test "Aggregation with LIMIT, no ORDER BY" \
    "MATCH (n) RETURN count(n) LIMIT 1" \
    "true"

echo
echo "======================================="
echo "    LIMIT/SKIP REGRESSION TEST SUMMARY"
echo "======================================="
echo
echo "Total Tests: $TOTAL_TESTS"
echo "Passed: $PASSED_TESTS"
echo "Failed: $FAILED_TESTS"
echo

if [ $FAILED_TESTS -eq 0 ]; then
    echo "🎉 ALL TESTS PASSED!"
    echo
    echo "=== Behavior Verified ==="
    echo "✅ LIMIT without ORDER BY: ALLOWED (working correctly)"
    echo "✅ SKIP/OFFSET without ORDER BY: REJECTED with US001 (working correctly)"
    echo "✅ SKIP/OFFSET with ORDER BY: ALLOWED (working correctly)"
    echo "✅ Edge cases handled properly"
    echo
    echo "=== Implementation Notes ==="
    echo "• LIMIT alone provides 'top N' results without requiring ordering"
    echo "• SKIP/OFFSET requires ORDER BY for deterministic pagination"
    echo "• This aligns with common database behavior (e.g., PostgreSQL)"
    echo "• US001 error only triggered for SKIP/OFFSET without ORDER BY"
else
    echo "⚠️  REGRESSION DETECTED!"
    echo "$FAILED_TESTS tests failed. Please review the failures above."
    echo
    echo "=== Expected Behavior ==="
    echo "• LIMIT without ORDER BY should succeed"
    echo "• SKIP/OFFSET without ORDER BY should fail with US001"
    echo "• Any query with ORDER BY should succeed"
    exit 1
fi

echo
echo "Regression test completed successfully!"
exit 0
