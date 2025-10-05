#!/usr/bin/env bash

# Regression test for fixes applied to EXISTS parsing, scientific notation, and stderr patterns
# This test verifies that all three critical fixes are working correctly

set -e

echo "=== Regression Test: EXISTS Parsing, Scientific Notation, and Stderr Patterns ==="

# Test 1: EXISTS predicate should parse and execute correctly
echo "Test 1: EXISTS predicate parsing..."
RESULT=$(./zig-out/bin/geode query "MATCH (p:Person) WHERE EXISTS { (p)-[:KNOWS]->() } RETURN count(p) AS result" --no-quic 2>/dev/null | grep '"result"' || echo "no results")
if [[ "$RESULT" != "no results" ]]; then
    echo "✓ EXISTS predicate parsing works"
else 
    echo "✗ EXISTS predicate parsing failed"
    exit 1
fi

# Test 2: Scientific notation should parse correctly
echo "Test 2: Scientific notation parsing..."
SCIENTIFIC_RESULT=$(./zig-out/bin/geode query "RETURN 1.5e3 AS value" --no-quic 2>/dev/null | grep '"value":1500.000000' || echo "not found")
if [[ "$SCIENTIFIC_RESULT" != "not found" ]]; then
    echo "✓ Scientific notation parsing works (1.5e3 = 1500)"
else
    echo "✗ Scientific notation parsing failed"
    exit 1
fi

# Test 3: Stderr patterns should be human-readable
echo "Test 3: Human-readable error messages..."
ERROR_OUTPUT=$(./zig-out/bin/geode query "INVALID SYNTAX" --no-quic 2>&1 >/dev/null | grep "Error: syntax error" || echo "raw json")
if [[ "$ERROR_OUTPUT" != "raw json" ]]; then
    echo "✓ Human-readable error messages work"
else
    echo "✗ Human-readable error messages failed"
    exit 1
fi

echo "=== All regression tests passed! ==="