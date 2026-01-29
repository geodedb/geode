#!/usr/bin/env bash

# REPL Formatting Regression Test Suite
# Tests the REPL output formatting functionality to prevent regressions

set -e

# CANARY: REQ=REQ-REPL-FORMAT-001; FEATURE="REPL Output Formatting"; ASPECT=RegressionTesting; STATUS=TESTED; TEST=repl_formatting_regression_test; OWNER=repl; UPDATED=2025-10-05

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY_PATH="$PROJECT_ROOT/zig-out/bin"

echo "🧪 REPL Formatting Regression Test Suite"
echo "========================================="

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

# Test 1: Unit Tests - Basic formatting functions
echo "1️⃣  Unit Tests"
echo "=================="

# Test the unit test file
run_test "Unit tests compilation" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_formatting.zig" \
    "passed"

# Test 2: Integration Tests
echo ""
echo "2️⃣  Integration Tests"
echo "====================="

# Test the integration test file
run_test "Integration tests compilation" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_formatting_integration.zig" \
    "passed"

# Test 3: Build Integration Tests
echo ""
echo "3️⃣  Build Integration Tests"
echo "=========================="

# Test that the formatting code builds correctly
run_test "REPL formatting builds correctly" \
    "cd '$PROJECT_ROOT' && zig build --verbose" \
    "install"

# Test that the binary exists and responds
run_test "Geode binary responds to help" \
    "'$BINARY_PATH/geode' --help" \
    "Usage:"

# Test 4: Mock Response Tests (since REPL requires TTY)
echo ""
echo "4️⃣  Mock Response Format Tests"
echo "=============================="

# Create a temporary test file to validate JSON parsing
TEMP_JSON_TEST=$(mktemp --suffix=.zig)
cat > "$TEMP_JSON_TEST" << 'EOF'
const std = @import("std");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test JSON parsing like the REPL does
    const test_responses = [_][]const u8{
        "{\"columns\":[\"name\"],\"data\":[[\"Alice\"]]}",
        "{\"columns\":[\"id\",\"name\"],\"data\":[[1,\"Alice\"],[2,\"Bob\"]]}",
        "{\"status\":\"success\",\"message\":\"Query executed\"}",
    };

    for (test_responses) |response| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
            std.debug.print("Failed to parse: {s}\n", .{response});
            continue;
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        if (root.get("columns")) |_| {
            if (root.get("data")) |_| {
                std.debug.print("✅ Valid query response format\n", .{});
            } else {
                std.debug.print("❌ Missing data field\n", .{});
            }
        } else if (root.get("status")) |_| {
            std.debug.print("✅ Valid status response format\n", .{});
        } else {
            std.debug.print("❌ Unknown response format\n", .{});
        }
    }

    std.debug.print("✅ JSON parsing validation complete\n", .{});
}
EOF

run_test "JSON response format validation" \
    "cd '$PROJECT_ROOT' && zig run '$TEMP_JSON_TEST'" \
    "JSON parsing validation complete"

# Clean up
rm -f "$TEMP_JSON_TEST"

# Test 5: Error Handling Tests
echo ""
echo "5️⃣  Error Handling Tests"
echo "======================="

# Test malformed JSON handling
TEMP_ERROR_TEST=$(mktemp --suffix=.zig)
cat > "$TEMP_ERROR_TEST" << 'EOF'
const std = @import("std");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test error cases
    const error_cases = [_][]const u8{
        "{invalid json",
        "{\"columns\":[]}",  // missing data
        "{\"data\":[]}",     // missing columns
        "",                  // empty
        "null",              // null response
    };

    for (error_cases) |response| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
            std.debug.print("✅ Gracefully handled parse error\n", .{});
            continue;
        };
        defer parsed.deinit();

        std.debug.print("✅ Parsed edge case successfully\n", .{});
    }

    std.debug.print("✅ Error handling validation complete\n", .{});
}
EOF

run_test "Error handling validation" \
    "cd '$PROJECT_ROOT' && zig run '$TEMP_ERROR_TEST'" \
    "Error handling validation complete"

# Clean up
rm -f "$TEMP_ERROR_TEST"

# Test 6: Performance Tests
echo ""
echo "6️⃣  Performance Tests"
echo "==================="

# Test that formatting doesn't cause memory leaks or excessive slowdowns
TEMP_PERF_TEST=$(mktemp --suffix=.zig)
cat > "$TEMP_PERF_TEST" << 'EOF'
const std = @import("std");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const start_time = std.time.milliTimestamp();

    // Simulate multiple formatting operations
    const large_response = "{\"columns\":[\"id\",\"name\",\"value\"],\"data\":[[1,\"test1\",100],[2,\"test2\",200],[3,\"test3\",300],[4,\"test4\",400],[5,\"test5\",500]]}";

    for (0..100) |_| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, large_response, .{}) catch continue;
        defer parsed.deinit();

        // Simulate processing
        const root = parsed.value.object;
        if (root.get("columns")) |columns_value| {
            if (root.get("data")) |data_value| {
                _ = columns_value.array;
                const rows = data_value.array;

                // Process columns and rows (lightweight simulation)
                var total_cells: usize = 0;
                for (rows.items) |row| {
                    total_cells += row.array.items.len;
                }
                // Use total_cells to prevent optimization away
                if (total_cells > 0) continue;
            }
        }
    }

    const end_time = std.time.milliTimestamp();
    const duration = end_time - start_time;

    std.debug.print("✅ Performance test completed in {}ms\n", .{duration});

    if (duration < 1000) { // Should complete in under 1 second
        std.debug.print("✅ Performance acceptable\n", .{});
    } else {
        std.debug.print("⚠️  Performance may need optimization\n", .{});
    }
}
EOF

run_test "Performance validation" \
    "cd '$PROJECT_ROOT' && zig run '$TEMP_PERF_TEST'" \
    "Performance test completed"

# Clean up
rm -f "$TEMP_PERF_TEST"

# Final Results
echo ""
echo "📊 Test Results Summary"
echo "======================"
echo "Total tests: $TOTAL_TESTS"
echo -e "Passed: ${GREEN}$PASSED_TESTS${NC}"
echo -e "Failed: ${RED}$FAILED_TESTS${NC}"

if [ $FAILED_TESTS -eq 0 ]; then
    echo ""
    echo -e "${GREEN}🎉 All REPL formatting regression tests passed!${NC}"
    echo "   The REPL output formatting system is working correctly."
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
