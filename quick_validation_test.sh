#!/usr/bin/env bash

# Quick validation test for the key fixes
set -e

echo "=== Quick Validation Test ==="

GEODE_BIN="./zig-out/bin/geode"

# Test 1: Unauthorized access returns exit code 3
echo "Test 1: Unauthorized access"
set +e
$GEODE_BIN query --user unauthorized --no-quic "MATCH (n) RETURN count(n)" >/dev/null 2>&1
exit_code=$?
set -e
if [[ $exit_code -eq 3 ]]; then
    echo "PASS: Unauthorized access returns exit code 3"
else
    echo "FAIL: Expected exit code 3, got $exit_code"
    exit 1
fi

# Test 2: Token auth returns exit code 0
echo "Test 2: Token authentication"
$GEODE_BIN query --token test_token --no-quic "RETURN current_user() AS user" >/dev/null 2>&1
exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    echo "PASS: Token auth returns exit code 0"
else
    echo "FAIL: Expected exit code 0, got $exit_code"
    exit 1
fi

# Test 3: Invalid command returns exit code 2
echo "Test 3: Invalid command"
set +e
$GEODE_BIN nonexistent-command >/dev/null 2>&1
exit_code=$?
set -e
if [[ $exit_code -eq 2 ]]; then
    echo "PASS: Invalid command returns exit code 2"
else
    echo "FAIL: Expected exit code 2, got $exit_code"
    exit 1
fi

# Test 4: Complex query with modified syntax
echo "Test 4: Complex query syntax"
$GEODE_BIN query --no-quic "MATCH (n:TestNode) WHERE n.category IN ['A', 'B'] WITH n.category AS cat, count(n) AS node_count RETURN cat, node_count ORDER BY node_count DESC" >/dev/null 2>&1
exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    echo "PASS: Complex query executes successfully"
else
    echo "FAIL: Expected exit code 0, got $exit_code"
    exit 1
fi

echo "=== All Tests Passed ==="