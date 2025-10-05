#!/usr/bin/env bash

# CANARY: REQ=REQ-CLI-WD-001; FEATURE="CLI Working Directory Handling"; ASPECT=TestInfrastructure; STATUS=TESTED; TEST=TestCANARY_REQ_CLI_WD_001_WorkingDirectory; OWNER=cli; UPDATED=2025-10-04

set -e

echo "=== CLI Working Directory Regression Tests ==="

GEODE_BIN="./zig-out/bin/geode"

# Test 1: CLI works from project root directory
echo "Test 1: CLI from project root directory"
result=$($GEODE_BIN "RETURN 'root_test' AS location" --no-quic 2>/dev/null | grep '"location":"root_test"' || echo "FAIL")
if [[ $result == *"FAIL"* ]]; then
    echo "FAIL: CLI should work from project root"
    exit 1
fi
echo "PASS: CLI works from project root directory"

# Test 2: CLI fails gracefully from zig-out directory (no geodec available)
echo "Test 2: CLI from zig-out directory (should fail gracefully)"
cd zig-out
result=$(../zig-out/bin/geode "RETURN 1" --no-quic 2>&1 | grep "geodec client not found" || echo "DIFFERENT_ERROR")
cd ..
if [[ $result == *"DIFFERENT_ERROR"* ]]; then
    echo "FAIL: CLI should show 'geodec client not found' error from zig-out directory"
    exit 1
fi
echo "PASS: CLI fails gracefully from zig-out directory"

# Test 3: CLI from subdirectory should fail gracefully (no geodec/geoded available)
echo "Test 3: CLI from subdirectory with relative path (should fail gracefully)"
mkdir -p temp_subdir
cd temp_subdir
result=$(../zig-out/bin/geode "RETURN 'subdir_test' AS location" --no-quic 2>&1 | grep "geodec client not found" || echo "DIFFERENT_ERROR")
cd ..
rmdir temp_subdir
if [[ $result == *"DIFFERENT_ERROR"* ]]; then
    echo "FAIL: CLI should show 'geodec client not found' error from subdirectory"
    exit 1
fi
echo "PASS: CLI fails gracefully from subdirectory"

# Test 4: CLI with absolute path
echo "Test 4: CLI with absolute path"
absolute_path=$(realpath $GEODE_BIN)
result=$($absolute_path "RETURN 'absolute_test' AS location" --no-quic 2>/dev/null | grep '"location":"absolute_test"' || echo "FAIL")
if [[ $result == *"FAIL"* ]]; then
    echo "FAIL: CLI should work with absolute path"
    exit 1
fi
echo "PASS: CLI works with absolute path"

# Test 5: Embedded server path resolution
echo "Test 5: Embedded server path resolution"
# Check that geoded server binary exists and is accessible from working directory
if [[ ! -f "./zig-out/bin/geoded" ]]; then
    echo "FAIL: geoded server binary not found at expected path"
    exit 1
fi
echo "PASS: Embedded server path resolution"

# Test 6: PATH environment handling
echo "Test 6: PATH environment handling"
# Ensure zig-out/bin is not in PATH, then test direct execution
export PATH=$(echo $PATH | sed 's|[^:]*zig-out/bin[^:]*:||g' | sed 's|:[^:]*zig-out/bin[^:]*||g')
result=$($GEODE_BIN "RETURN 'path_test' AS location" --no-quic 2>/dev/null | grep '"location":"path_test"' || echo "FAIL")
if [[ $result == *"FAIL"* ]]; then
    echo "FAIL: CLI should work without zig-out/bin in PATH"
    exit 1
fi
echo "PASS: CLI works without zig-out/bin in PATH"

echo "=== All Working Directory Tests Passed ==="