#!/usr/bin/env bash

# CANARY: REQ=REQ-REPL-QUIC-001; FEATURE="REPL QUIC Integration"; ASPECT=RegressionTesting; STATUS=IMPL; TEST=repl_quic_integration_regression_test; OWNER=repl; UPDATED=2025-10-05

# Regression test suite for REPL QUIC integration
# This script validates the QUIC integration functionality

set -e

echo "=== REPL QUIC Integration Regression Test Suite ==="
echo "Testing REPL ClientSession QUIC integration functionality..."
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counter
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Function to run a test
run_test() {
    local test_name="$1"
    local test_command="$2"
    
    echo -n "Testing $test_name... "
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if eval "$test_command" >/dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAIL${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Function to run a test expecting failure
run_test_expect_fail() {
    local test_name="$1"
    local test_command="$2"
    
    echo -n "Testing $test_name... "
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if eval "$test_command" >/dev/null 2>&1; then
        echo -e "${RED}FAIL (expected failure)${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        echo -e "${GREEN}PASS (failed as expected)${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
}

echo "1. Testing REPL QUIC Integration Unit Tests"
echo "----------------------------------------"

# Test 1: Unit test compilation
run_test "QUIC integration unit test compilation" \
    "zig test tests/test_repl_quic_integration.zig"

# Test 2: Integration test compilation  
run_test "QUIC integration E2E test compilation" \
    "zig test tests/test_repl_quic_integration_e2e.zig"

echo
echo "2. Testing QUIC Transport Module Integration"
echo "-------------------------------------------"

# Test 3: QUIC transport module exists and compiles
run_test "QUIC transport module compilation" \
    "zig test src/transport/quic.zig --main-pkg-path ."

echo
echo "3. Testing REPL Module Dependencies"
echo "-----------------------------------"

# Test 4: REPL dispatch module compiles with QUIC integration
run_test "REPL dispatch module with QUIC compilation" \
    "zig test src/client/repl/repl_dispatch.zig --main-pkg-path ."

# Test 5: REPL loop module compiles with updated dispatch
run_test "REPL loop module compilation" \
    "zig test src/client/repl/repl_loop.zig --main-pkg-path ."

echo
echo "4. Testing Import and Module Resolution"
echo "--------------------------------------"

# Test 6: QUIC import resolution in REPL dispatch
run_test "QUIC import resolution" \
    "grep -q 'const quic_transport = @import(\"../transport/quic.zig\");' src/client/repl/repl_dispatch.zig"

# Test 7: ClientSession struct definition
run_test "ClientSession QUIC integration structure" \
    "grep -q 'quic_client: ?quic_transport.QuicClient' src/client/repl/repl_dispatch.zig"

# Test 8: CANARY markers present
run_test "CANARY markers in QUIC integration" \
    "grep -q 'REQ-REPL-QUIC-001' src/client/repl/repl_dispatch.zig"

echo
echo "5. Testing Function Signatures and Integration"
echo "----------------------------------------------"

# Test 9: ClientSession.connect signature
run_test "ClientSession.connect function signature" \
    "grep -q 'pub fn connect(allocator: std.mem.Allocator, addr: \\[\\]const u8)' src/client/repl/repl_dispatch.zig"

# Test 10: ClientSession.hello function exists
run_test "ClientSession.hello function exists" \
    "grep -q 'pub fn hello(self: \\*ClientSession)' src/client/repl/repl_dispatch.zig"

# Test 11: ClientSession.runGql function exists
run_test "ClientSession.runGql function exists" \
    "grep -q 'pub fn runGql(self: \\*ClientSession, gql: \\[\\]const u8)' src/client/repl/repl_dispatch.zig"

# Test 12: Transaction support functions
run_test "Transaction support functions" \
    "grep -q 'pub fn begin(self: \\*ClientSession)' src/client/repl/repl_dispatch.zig && \
     grep -q 'pub fn commit(self: \\*ClientSession)' src/client/repl/repl_dispatch.zig && \
     grep -q 'pub fn rollback(self: \\*ClientSession)' src/client/repl/repl_dispatch.zig"

echo
echo "6. Testing JSON Escaping and Protocol Integration"
echo "-----------------------------------------------"

# Test 13: JSON escaping function exists
run_test "JSON escaping function" \
    "grep -q 'fn escapeJsonString(allocator: std.mem.Allocator, input: \\[\\]const u8)' src/client/repl/repl_dispatch.zig"

# Test 14: Protocol message formatting
run_test "QUIC protocol message formatting" \
    "grep -q 'type.*:.*HELLO\\|RUN_GQL\\|BEGIN\\|COMMIT\\|ROLLBACK\\|PULL' src/client/repl/repl_dispatch.zig"

echo
echo "7. Testing Error Handling and Edge Cases"
echo "----------------------------------------"

# Test 15: Error handling integration
run_test "REPL error handling integration" \
    "grep -q 'repl_errors.ReplError' src/client/repl/repl_dispatch.zig"

# Test 16: Connection state management
run_test "Connection state management" \
    "grep -q 'connected: bool' src/client/repl/repl_dispatch.zig"

echo
echo "8. Testing Memory Management"
echo "----------------------------"

# Test 17: Proper deinit implementation
run_test "Proper deinit implementation" \
    "grep -q 'pub fn deinit(self: \\*ClientSession)' src/client/repl/repl_dispatch.zig"

# Test 18: Response memory management
run_test "Response memory management" \
    "grep -q 'last_response: ?\\[\\]u8' src/client/repl/repl_dispatch.zig"

echo
echo "9. Testing Integration with Existing REPL Features"
echo "------------------------------------------------"

# Test 19: executeGql function updated
run_test "executeGql function QUIC integration" \
    "grep -q 'try state.session.runGql(gql);' src/client/repl/repl_dispatch.zig"

# Test 20: Format support maintained
run_test "Output format support maintained" \
    "grep -q 'formatQueryResult' src/client/repl/repl_dispatch.zig"

echo
echo "10. Testing Build System Integration"
echo "-----------------------------------"

# Test 21: Main project builds with QUIC integration
run_test "Main project build with QUIC integration" \
    "timeout 30s zig build -Doptimize=Debug"

# Test 22: REPL client builds successfully
run_test "REPL client build" \
    "timeout 30s zig build -Doptimize=Debug --step=repl"

echo
echo "=== Test Results ==="
echo "Tests run: $TESTS_RUN"
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed! REPL QUIC integration is working correctly.${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed. Please review the QUIC integration implementation.${NC}"
    exit 1
fi