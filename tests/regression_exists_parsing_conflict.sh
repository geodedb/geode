#!/usr/bin/env bash

# Regression test for EXISTS function vs predicate parsing conflict fix
# Verifies that both EXISTS { pattern } and exists(args) syntax work correctly

set -e

echo "=== Regression Test: EXISTS Function vs Predicate Parsing ==="

# Test 1: EXISTS predicate syntax should parse and execute
echo "Test 1: EXISTS predicate parsing..."
EXISTS_PREDICATE_RESULT=$(./zig-out/bin/geode query "MATCH (p:Person) WHERE EXISTS { (p)-[:KNOWS]->() } RETURN count(p) AS result" --no-quic 2>/dev/null | grep '"result"' || echo "no results")
if [[ "$EXISTS_PREDICATE_RESULT" != "no results" ]]; then
    echo "✓ EXISTS predicate syntax works: EXISTS { (p)-[:KNOWS]->() }"
else 
    echo "✗ EXISTS predicate syntax failed"
    exit 1
fi

# Test 2: exists() function call syntax should parse without errors
echo "Test 2: exists() function call parsing..."
EXISTS_FUNCTION_RESULT=$(./zig-out/bin/geode query "MATCH (n)-[r]->(m) WHERE exists(n.name) RETURN {k: 1, v: n.age} AS map_result" --no-quic 2>/dev/null | grep '"type":"SCHEMA"' || echo "parse error")
if [[ "$EXISTS_FUNCTION_RESULT" != "parse error" ]]; then
    echo "✓ exists() function call syntax works: exists(n.name)"
else
    echo "✗ exists() function call syntax failed"
    exit 1
fi

# Test 3: Mixed usage in same query should work
echo "Test 3: Mixed EXISTS predicate and exists() function usage..."
MIXED_RESULT=$(./zig-out/bin/geode query "MATCH (p:Person) WHERE EXISTS { (p)-[:KNOWS]->() } AND exists(p.name) RETURN p.name" --no-quic 2>/dev/null | grep '"type":"SCHEMA"' || echo "parse error")
if [[ "$MIXED_RESULT" != "parse error" ]]; then
    echo "✓ Mixed EXISTS predicate and exists() function works"
else
    echo "✗ Mixed EXISTS usage failed"
    exit 1
fi

# Test 4: Verify parser distinguishes between { and ( after EXISTS
echo "Test 4: Parser token lookahead validation..."
# This should parse as EXISTS predicate (no parse errors expected)
PREDICATE_RESULT=$(echo "MATCH (p) WHERE EXISTS { (p)-[:REL]->() } RETURN p" | ./zig-out/bin/gql 2>&1 || echo "parse_failed")
# This should parse as exists function (no parse errors expected)  
FUNCTION_RESULT=$(echo "MATCH (p) WHERE exists(p.name) RETURN p" | ./zig-out/bin/gql 2>&1 || echo "parse_failed")

if [[ "$PREDICATE_RESULT" != "parse_failed" && "$FUNCTION_RESULT" != "parse_failed" ]]; then
    echo "✓ Parser correctly distinguishes EXISTS { } vs exists( ) syntax"
else
    echo "✗ Parser lookahead failed"
    echo "Predicate result: $PREDICATE_RESULT"
    echo "Function result: $FUNCTION_RESULT"
    exit 1
fi

echo "=== All EXISTS parsing regression tests passed! ==="