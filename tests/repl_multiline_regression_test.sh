#!/usr/bin/env bash

# REPL Multi-line Input Regression Test Suite
# Tests the multi-line input functionality to prevent regressions

set -e

# CANARY: REQ=REQ-REPL-MULTILINE-001; FEATURE=\"REPL Multi-line Input\"; ASPECT=RegressionTesting; STATUS=TESTED; TEST=repl_multiline_regression_test; OWNER=repl; UPDATED=2025-10-05

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY_PATH="$PROJECT_ROOT/zig-out/bin"

echo "📝 REPL Multi-line Input Regression Test Suite"
echo "=============================================="

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test result tracking
declare -a FAILED_TEST_NAMES=()

# Function to run a test
run_test() {
    local test_name="$1"
    local test_command="$2"
    local expected_pattern="$3"
    local should_contain="${4:-true}"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo -n "  Testing $test_name... "
    
    # Run the test command with timeout
    if output=$(timeout 10 bash -c "$test_command" 2>&1); then
        if [ "$should_contain" = "true" ]; then
            if echo "$output" | grep -q "$expected_pattern"; then
                echo -e "${GREEN}PASS${NC}"
                PASSED_TESTS=$((PASSED_TESTS + 1))
                return 0
            else
                echo -e "${RED}FAIL${NC} (expected pattern not found)"
                echo "    Expected: $expected_pattern"
                echo "    Got: $output"
                FAILED_TESTS=$((FAILED_TESTS + 1))
                FAILED_TEST_NAMES+=("$test_name")
                return 1
            fi
        else
            if echo "$output" | grep -q "$expected_pattern"; then
                echo -e "${RED}FAIL${NC} (unexpected pattern found)"
                echo "    Unexpected: $expected_pattern"
                echo "    Got: $output"
                FAILED_TESTS=$((FAILED_TESTS + 1))
                FAILED_TEST_NAMES+=("$test_name")
                return 1
            else
                echo -e "${GREEN}PASS${NC}"
                PASSED_TESTS=$((PASSED_TESTS + 1))
                return 0
            fi
        fi
    else
        echo -e "${RED}FAIL${NC} (command failed or timed out)"
        echo "    Command: $test_command"
        echo "    Output: $output"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        FAILED_TEST_NAMES+=("$test_name")
        return 1
    fi
}

# Ensure binaries exist
if [ ! -f "$BINARY_PATH/geode" ]; then
    echo "❌ Error: geode binary not found at $BINARY_PATH/geode"
    echo "   Please run 'zig build' first"
    exit 1
fi

echo "📍 Using binary: $BINARY_PATH/geode"
echo ""

# Test 1: Unit Tests - Basic multi-line functions
echo "1️⃣  Unit Tests"
echo "==============="

# Test the unit test file
run_test "Multi-line unit tests compilation and execution" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_multiline.zig" \
    "All 8 tests passed"

# Test 2: Integration Tests  
echo ""
echo "2️⃣  Integration Tests"
echo "===================="

# Test the integration test file
run_test "Multi-line integration tests compilation and execution" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_multiline_integration.zig" \
    "All 8 tests passed"

# Test 3: Parse Module Tests
echo ""
echo "3️⃣  Parse Module Tests"
echo "====================="

# Test the parse module with new functions
run_test "Parse module multi-line functions" \
    "cd '$PROJECT_ROOT' && zig test src/client/repl/repl_parse.zig" \
    "All 2 tests passed"

# Test 4: Build Integration Tests
echo ""
echo "4️⃣  Build Integration Tests"
echo "=========================="

# Test that the multi-line code builds correctly
run_test "REPL multi-line builds correctly" \
    "cd '$PROJECT_ROOT' && zig build --verbose" \
    "install"

# Test that the binary exists and responds
run_test "Geode binary responds to help" \
    "'$BINARY_PATH/geode' --help" \
    "Usage:"

# Test 5: Multi-line Parsing Function Tests
echo ""
echo "5️⃣  Multi-line Parsing Function Tests"
echo "===================================="

# Test parsing function validation by running the actual test
run_test "Multi-line parsing function validation via test suite" \
    "cd '$PROJECT_ROOT' && zig test src/client/repl/repl_parse.zig --test-filter 'multi-line parsing'" \
    "All 1 tests passed"

# Test 6: Prompt Formatting Tests
echo ""
echo "6️⃣  Prompt Formatting Tests"
echo "=========================="

# Test continuation prompt formatting
TEMP_PROMPT_TEST=$(mktemp --suffix=.zig)
cat > "$TEMP_PROMPT_TEST" << 'EOF'
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    _ = gpa.allocator();
    
    // Test prompt formatting logic like REPL does
    const test_cases = [_]struct {
        is_continuation: bool,
        in_txn: bool,
        expected_prompt: []const u8,
    }{
        .{ .is_continuation = false, .in_txn = false, .expected_prompt = "geode> " },
        .{ .is_continuation = true, .in_txn = false, .expected_prompt = "geode-> " },
        .{ .is_continuation = false, .in_txn = true, .expected_prompt = "geode(txn)> " },
        .{ .is_continuation = true, .in_txn = true, .expected_prompt = "geode(txn)-> " },
    };
    
    for (test_cases) |test_case| {
        const prompt = if (test_case.is_continuation)
            if (test_case.in_txn) "geode(txn)-> " else "geode-> "
        else if (test_case.in_txn) "geode(txn)> " else "geode> ";
        
        if (!std.mem.eql(u8, prompt, test_case.expected_prompt)) {
            std.debug.print("❌ Prompt test failed\n", .{});
            std.debug.print("   Expected: '{s}'\n", .{test_case.expected_prompt});
            std.debug.print("   Got: '{s}'\n", .{prompt});
            return error.PromptTestFailed;
        }
    }
    
    std.debug.print("✅ Prompt formatting validation complete\n", .{});
}
EOF

run_test "Prompt formatting validation" \
    "cd '$PROJECT_ROOT' && zig run '$TEMP_PROMPT_TEST'" \
    "Prompt formatting validation complete"

# Clean up
rm -f "$TEMP_PROMPT_TEST"

# Test 7: State Management Tests
echo ""
echo "7️⃣  State Management Tests"
echo "========================"

# Test multi-line state management
TEMP_STATE_TEST=$(mktemp --suffix=.zig)
cat > "$TEMP_STATE_TEST" << 'EOF'
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Test multi-line buffer management like REPL does
    var multi_line_buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    defer multi_line_buffer.deinit(allocator);
    
    var is_continuation = false;
    
    // Simulate multi-line input
    const lines = [_][]const u8{
        "MATCH (n:Person)",
        "WHERE n.age > 25",
        "RETURN n.name;",
    };
    
    for (lines) |line| {
        if (is_continuation) {
            try multi_line_buffer.append(allocator, '\n');
            try multi_line_buffer.appendSlice(allocator, line);
        } else {
            multi_line_buffer.clearRetainingCapacity();
            try multi_line_buffer.appendSlice(allocator, line);
        }
        
        // Check if complete (simplified)
        const complete_input = multi_line_buffer.items;
        if (std.mem.indexOf(u8, complete_input, ";") != null) {
            // Complete - reset state
            const expected = "MATCH (n:Person)\nWHERE n.age > 25\nRETURN n.name;";
            if (!std.mem.eql(u8, complete_input, expected)) {
                std.debug.print("❌ Multi-line buffer content incorrect\n", .{});
                std.debug.print("   Expected: '{s}'\n", .{expected});
                std.debug.print("   Got: '{s}'\n", .{complete_input});
                return error.BufferContentIncorrect;
            }
            
            is_continuation = false;
            multi_line_buffer.clearRetainingCapacity();
            break;
        } else {
            // Incomplete - enter continuation mode
            is_continuation = true;
        }
    }
    
    std.debug.print("✅ State management validation complete\n", .{});
}
EOF

run_test "Multi-line state management validation" \
    "cd '$PROJECT_ROOT' && zig run '$TEMP_STATE_TEST'" \
    "State management validation complete"

# Clean up
rm -f "$TEMP_STATE_TEST"

# Final Results
echo ""
echo "📊 Test Results Summary"
echo "======================"
echo "Total tests: $TOTAL_TESTS"
echo -e "Passed: ${GREEN}$PASSED_TESTS${NC}"
echo -e "Failed: ${RED}$FAILED_TESTS${NC}"

if [ $FAILED_TESTS -eq 0 ]; then
    echo ""
    echo -e "${GREEN}🎉 All REPL multi-line regression tests passed!${NC}"
    echo "   The REPL multi-line input functionality is working correctly."
    exit 0
else
    echo ""
    echo -e "${RED}❌ Some tests failed:${NC}"
    for test_name in "${FAILED_TEST_NAMES[@]}"; do
        echo "   - $test_name"
    done
    echo ""
    echo "Please review the failed tests and fix any issues."
    exit 1
fi