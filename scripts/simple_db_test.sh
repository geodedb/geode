#!/usr/bin/env nix-shell
#! nix-shell -i bash -p bash -p coreutils
# Simple Database Test to debug issues

set -e

echo "=== Simple Database Test ==="

# Test function
test_query() {
    local name="$1"
    local query="$2"
    local pattern="$3"
    
    echo -n "Testing $name... "
    if ./zig-out/bin/geodec "$query" --server 127.0.0.1:3141 --insecure 2>&1 | grep -q "$pattern"; then
        echo "PASS"
        return 0
    else
        echo "FAIL"
        echo "Query: $query"
        echo "Expected: $pattern"
        echo "Actual output:"
        ./zig-out/bin/geodec "$query" --server 127.0.0.1:3141 --insecure 2>&1 | head -3
        return 1
    fi
}

# Run a few basic tests
test_query "Simple return" "RETURN 1 AS num" '"num":1'
test_query "Basic arithmetic" "RETURN 2 + 3 AS sum" '"sum":5'
test_query "String concat" "RETURN \"hello\" + \" world\" AS greeting" '"greeting":"hello world"'

echo "Simple tests completed"