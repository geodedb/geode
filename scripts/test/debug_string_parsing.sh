#!/usr/bin/env bash
# Debug script to isolate the string literal parsing issue

set -e

echo "=== Debug String Literal Parsing ==="
echo

# Build first
echo "Building Geode..."
make build > /dev/null 2>&1

echo
echo "Testing different query types to isolate the problem:"

# Test 1: Simple string literal in RETURN (should work)
echo -n "1. String in RETURN statement: "
timeout 3 ./zig-out/bin/geode query 'RETURN "hello" AS greeting' --server 127.0.0.1:3141 --insecure >/dev/null 2>&1 && echo "WORKS" || echo "HANGS"

# Test 2: Property map with integer (should work based on previous tests)
echo -n "2. Integer in property map: "
timeout 3 ./zig-out/bin/geode query 'CREATE (p {age: 30})' --server 127.0.0.1:3141 --insecure >/dev/null 2>&1 && echo "WORKS" || echo "HANGS"

# Test 3: Property map with string (problem case)
echo -n "3. String in property map: "
timeout 3 ./zig-out/bin/geode query 'CREATE (p {name: "Alice"})' --server 127.0.0.1:3141 --insecure >/dev/null 2>&1 && echo "WORKS" || echo "HANGS"

# Test 4: Empty property map (should work)
echo -n "4. Empty property map: "
timeout 3 ./zig-out/bin/geode query 'CREATE (p {})' --server 127.0.0.1:3141 --insecure >/dev/null 2>&1 && echo "WORKS" || echo "HANGS"

# Test 5: Property map with boolean (should work)
echo -n "5. Boolean in property map: "
timeout 3 ./zig-out/bin/geode query 'CREATE (p {active: true})' --server 127.0.0.1:3141 --insecure >/dev/null 2>&1 && echo "WORKS" || echo "HANGS"

# Test 6: String literal by itself (let's see if basic string parsing works)
echo -n "6. Simple string literal: "
timeout 3 ./zig-out/bin/geode query 'RETURN "test"' --server 127.0.0.1:3141 --insecure >/dev/null 2>&1 && echo "WORKS" || echo "HANGS"

echo
echo "=== Detailed Analysis ==="

echo
echo "Testing with strace to see system call patterns..."

echo "Property with integer (should complete quickly):"
timeout 5 strace -c ./zig-out/bin/geode query 'CREATE (p {age: 30})' --server 127.0.0.1:3141 --insecure 2>&1 | tail -20

echo
echo "Property with string (may hang - will timeout after 5s):"
timeout 5 strace -c ./zig-out/bin/geode query 'CREATE (p {name: "Alice"})' --server 127.0.0.1:3141 --insecure 2>&1 | tail -20 || echo "Process timed out or hung"

echo
echo "=== Investigation Complete ==="
echo "The problem appears to be specifically with string literals inside property maps"
