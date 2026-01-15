#!/usr/bin/env bash

# CANARY: REQ=REQ-CLI-EXIT-001; FEATURE="CLI Exit Code Mapping"; ASPECT=ErrorHandling; STATUS=TESTED; TEST=TestCANARY_REQ_CLI_EXIT_001_ExitCodes; OWNER=cli; UPDATED=2025-10-04

set -e

echo "=== CLI Exit Code Mapping Regression Tests ==="

GEODE_BIN="./zig-out/bin/geode"

# Test 1: Success should return exit code 0
echo "Test 1: Success exit code (0)"
$GEODE_BIN "RETURN 1 AS success_test" --insecure >/dev/null 2>&1
exit_code=$?
if [[ $exit_code -ne 0 ]]; then
    echo "FAIL: Successful query should return exit code 0, got $exit_code"
    exit 1
fi
echo "PASS: Success returns exit code 0"

# Test 2: Parse errors should return exit code 1 (general_error)
echo "Test 2: Parse error exit code (1)"
timeout 5 $GEODE_BIN "INVALID" --insecure >/dev/null 2>&1
exit_code=$?
if [[ $exit_code -ne 1 ]]; then
    echo "FAIL: Parse error should return exit code 1, got $exit_code"
    exit 1
fi
echo "PASS: Parse error returns exit code 1"

# Test 3: Unknown subcommand should return exit code 2 (usage_error)
echo "Test 3: Unknown subcommand exit code (2)"
$GEODE_BIN "nonexistent-command" >/dev/null 2>&1
exit_code=$?
if [[ $exit_code -ne 2 ]]; then
    echo "FAIL: Unknown subcommand should return exit code 2, got $exit_code"
    exit 1
fi
echo "PASS: Unknown subcommand returns exit code 2"

# Test 4: Unknown option should return exit code 2 (usage_error)
echo "Test 4: Unknown option exit code (2)"
$GEODE_BIN --nonexistent-option >/dev/null 2>&1
exit_code=$?
if [[ $exit_code -ne 2 ]]; then
    echo "FAIL: Unknown option should return exit code 2, got $exit_code"
    exit 1
fi
echo "PASS: Unknown option returns exit code 2"

# Test 5: Help should return exit code 0
echo "Test 5: Help exit code (0)"
$GEODE_BIN --help >/dev/null 2>&1
exit_code=$?
if [[ $exit_code -ne 0 ]]; then
    echo "FAIL: Help should return exit code 0, got $exit_code"
    exit 1
fi
echo "PASS: Help returns exit code 0"

# Test 6: Version should return exit code 0
echo "Test 6: Version exit code (0)"
$GEODE_BIN --version >/dev/null 2>&1
exit_code=$?
if [[ $exit_code -ne 0 ]]; then
    echo "FAIL: Version should return exit code 0, got $exit_code"
    exit 1
fi
echo "PASS: Version returns exit code 0"

# Test 7: Subcommand help should return exit code 0
echo "Test 7: Subcommand help exit code (0)"
$GEODE_BIN query --help >/dev/null 2>&1
exit_code=$?
if [[ $exit_code -ne 0 ]]; then
    echo "FAIL: Subcommand help should return exit code 0, got $exit_code"
    exit 1
fi
echo "PASS: Subcommand help returns exit code 0"

# Test 8: Various GQL syntax errors should return exit code 1
echo "Test 8: GQL syntax errors exit code (1)"
syntax_errors=("INVALID" "BADKEYWORD" "SYNTAX ERROR" "UNKNOWN COMMAND")
for error in "${syntax_errors[@]}"; do
    timeout 5 $GEODE_BIN "$error" --insecure >/dev/null 2>&1
    exit_code=$?
    if [[ $exit_code -ne 1 ]]; then
        echo "FAIL: GQL syntax error '$error' should return exit code 1, got $exit_code"
        exit 1
    fi
done
echo "PASS: GQL syntax errors return exit code 1"

# Test 9: CLI usage errors should return exit code 2
echo "Test 9: CLI usage errors exit code (2)"
usage_errors=("query" "query --invalid-flag query-text" "serve --invalid-option")
for error in "${usage_errors[@]}"; do
    $GEODE_BIN $error >/dev/null 2>&1
    exit_code=$?
    if [[ $exit_code -ne 2 ]]; then
        echo "FAIL: CLI usage error '$error' should return exit code 2, got $exit_code"
        exit 1
    fi
done
echo "PASS: CLI usage errors return exit code 2"

# Test 10: Auto-detected queries maintain proper exit codes
echo "Test 10: Auto-detected queries exit codes"
# Valid auto-detected query should return 0
$GEODE_BIN "RETURN 'auto_detected' AS test" --insecure >/dev/null 2>&1
exit_code=$?
if [[ $exit_code -ne 0 ]]; then
    echo "FAIL: Auto-detected valid query should return exit code 0, got $exit_code"
    exit 1
fi

# Invalid auto-detected query should return 1
timeout 5 $GEODE_BIN "INVALID" --insecure >/dev/null 2>&1
exit_code=$?
if [[ $exit_code -ne 1 ]]; then
    echo "FAIL: Auto-detected invalid query should return exit code 1, got $exit_code"
    exit 1
fi
echo "PASS: Auto-detected queries maintain proper exit codes"

echo "=== All Exit Code Mapping Tests Passed ==="