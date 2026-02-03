#!/usr/bin/env bash
# Simple stdio mode test for Geode
# Tests the specific fix for field name issue ("text" vs "gql")

set -e

echo "=== Simple Stdio Mode Test ==="

# Build first
make build > /dev/null 2>&1

echo "Test 1: Integer query with correct field name"
output1=$(echo '{"type":"RUN_GQL","text":"RETURN 1 AS num"}' | timeout 3 ./zig-out/bin/geode serve 2>/dev/null | head -1)
if echo "$output1" | grep -q '"name":"num"'; then
    echo "✓ PASS: Integer query works"
else
    echo "✗ FAIL: Integer query failed"
    echo "Output: $output1"
    exit 1
fi

echo "Test 2: String literal query"
output2=$(echo '{"type":"RUN_GQL","text":"RETURN \"hello\" AS greeting"}' | timeout 3 ./zig-out/bin/geode serve 2>/dev/null | head -1)
if echo "$output2" | grep -q '"name":"greeting"'; then
    echo "✓ PASS: String literal query works"
else
    echo "✗ FAIL: String literal query failed"
    echo "Output: $output2"
    exit 1
fi

echo "Test 3: Wrong field name should be ignored"
output3=$(echo '{"type":"RUN_GQL","gql":"RETURN 1 AS num"}' | timeout 3 ./zig-out/bin/geode serve 2>/dev/null | wc -l)
if [ "$output3" = "0" ]; then
    echo "✓ PASS: Wrong field name correctly ignored"
else
    echo "✗ FAIL: Wrong field name should be ignored"
    exit 1
fi

echo
echo "All stdio mode tests passed! ✨"
echo "The fix correctly handles:"
echo "  - String literal queries work properly"
echo "  - Server uses 'text' field (not 'gql') in JSON protocol"
echo "  - Invalid messages are silently ignored"
