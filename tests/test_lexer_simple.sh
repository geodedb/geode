#!/usr/bin/env bash
# Simple lexer test to debug double quote issue

echo "Testing lexer with different inputs..."

# Test 1: Simple return with single quotes
echo "Test 1: RETURN 'test'"
echo "RETURN 'test'" | timeout 1 ./zig-out/bin/geoded 2>&1 | grep -E "status_class|error" | head -1

# Test 2: Simple return with double quotes
echo "Test 2: RETURN \"test\""
echo 'RETURN "test"' | timeout 1 ./zig-out/bin/geoded 2>&1 | grep -E "status_class|error|timeout" | head -1 || echo "TIMEOUT/HANG"

# Test 3: Property with single quotes
echo "Test 3: CREATE (n {name: 'test'})"
echo "CREATE (n {name: 'test'})" | timeout 1 ./zig-out/bin/geoded 2>&1 | grep -E "status_class|error" | head -1

# Test 4: Property with double quotes
echo "Test 4: CREATE (n {name: \"test\"})"
echo 'CREATE (n {name: "test"})' | timeout 1 ./zig-out/bin/geoded 2>&1 | grep -E "status_class|error|timeout" | head -1 || echo "TIMEOUT/HANG"

echo
echo "If Test 2 or Test 4 show TIMEOUT/HANG, the double quote bug persists"