#!/usr/bin/env bash

# CANARY: REQ=REQ-CLI-AUTO-001; FEATURE="GQL Query Auto-detection"; ASPECT=UserExperience; STATUS=TESTED; TEST=TestCANARY_REQ_CLI_AUTO_001_GqlAutoDetection; OWNER=cli; UPDATED=2025-10-04

set -e

echo "=== GQL Query Auto-detection Regression Tests ==="

GEODE_BIN="./zig-out/bin/geode"
# Note: Tests must run from the project root directory where ./zig-out/bin/geoded is available

# Test 1: Basic RETURN query without 'query' subcommand
echo "Test 1: Basic RETURN query auto-detection"
result=$($GEODE_BIN "RETURN 1 AS result" --no-quic 2>/dev/null | grep '"result".*1' || echo "FAIL")
if [[ $result == *"FAIL"* ]]; then
    echo "FAIL: Basic RETURN query auto-detection"
    exit 1
fi
echo "PASS: Basic RETURN query auto-detection"

# Test 2: MATCH query auto-detection
echo "Test 2: MATCH query auto-detection"
result=$($GEODE_BIN "MATCH (n) RETURN count(n) AS node_count" --no-quic 2>/dev/null | grep '"node_count"' || echo "FAIL")
if [[ $result == *"FAIL"* ]]; then
    echo "FAIL: MATCH query auto-detection"
    exit 1
fi
echo "PASS: MATCH query auto-detection"

# Test 3: CREATE query auto-detection
echo "Test 3: CREATE query auto-detection"
$GEODE_BIN "CREATE (n:TestNode {name: 'autotest'})" --no-quic >/dev/null 2>&1
if [[ $? -ne 0 ]]; then
    echo "FAIL: CREATE query auto-detection"
    exit 1
fi
echo "PASS: CREATE query auto-detection"

# Test 4: Invalid GQL syntax should return exit code 1
echo "Test 4: Invalid GQL syntax exit code"
timeout 10 $GEODE_BIN "INVALID GQL SYNTAX HERE" --no-quic >/dev/null 2>&1
exit_code=$?
if [[ $exit_code -ne 1 ]]; then
    echo "FAIL: Invalid GQL syntax should return exit code 1, got $exit_code"
    exit 1
fi
echo "PASS: Invalid GQL syntax returns correct exit code 1"

# Test 5: Format flag auto-detection
echo "Test 5: Format flag auto-detection"
result=$($GEODE_BIN --format json "RETURN 'hello' AS greeting" --no-quic 2>/dev/null | grep '"greeting".*hello' || echo "FAIL")
if [[ $result == *"FAIL"* ]]; then
    echo "FAIL: Format flag auto-detection"
    exit 1
fi
echo "PASS: Format flag auto-detection"

# Test 6: Server flag auto-detection
echo "Test 6: Server flag auto-detection"
result=$($GEODE_BIN --server localhost:8443 "RETURN 2 AS num" --no-quic 2>/dev/null | grep '"num".*2' || echo "FAIL")
if [[ $result == *"FAIL"* ]]; then
    echo "FAIL: Server flag auto-detection"
    exit 1
fi
echo "PASS: Server flag auto-detection"

# Test 7: Case insensitive keyword detection
echo "Test 7: Case insensitive keyword detection"
result=$($GEODE_BIN "return 42 as answer" --no-quic 2>/dev/null | grep '"answer".*42' || echo "FAIL")
if [[ $result == *"FAIL"* ]]; then
    echo "FAIL: Case insensitive keyword detection"
    exit 1
fi
echo "PASS: Case insensitive keyword detection"

# Test 8: Non-GQL command should still show help
echo "Test 8: Non-GQL command error handling"
result=$($GEODE_BIN "nonexistent-command" 2>&1 | grep "unknown subcommand" || echo "FAIL")
if [[ $result == *"FAIL"* ]]; then
    echo "FAIL: Non-GQL command should show error"
    exit 1
fi
echo "PASS: Non-GQL command error handling"

# Test 9: Mixed flags and query
echo "Test 9: Mixed flags and query handling"
result=$($GEODE_BIN --format json "RETURN 'test' AS value" --no-quic 2>/dev/null | grep '"value".*test' || echo "FAIL")
if [[ $result == *"FAIL"* ]]; then
    echo "FAIL: Mixed flags and query handling"
    exit 1
fi
echo "PASS: Mixed flags and query handling"

# Test 10: Complex GQL keywords
echo "Test 10: Complex GQL keywords detection"
keywords=("EXPLAIN" "PROFILE" "MERGE" "OPTIONAL" "DETACH" "CONSTRAINT" "INDEX")
for keyword in "${keywords[@]}"; do
    # These might fail due to syntax, but should be detected as GQL queries (not unknown subcommands)
    result=$($GEODE_BIN "$keyword test" --no-quic 2>&1 | grep -E "(ParseError|unknown subcommand)" || echo "UNKNOWN")
    if [[ $result == *"unknown subcommand"* ]]; then
        echo "FAIL: $keyword should be detected as GQL query"
        exit 1
    fi
done
echo "PASS: Complex GQL keywords detection"

echo "=== All GQL Auto-detection Tests Passed ==="