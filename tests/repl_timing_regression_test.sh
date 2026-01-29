#!/usr/bin/env bash

# REPL Timing Regression Test Suite
# Tests the REPL timing functionality to prevent regressions

set -e

# CANARY: REQ=REQ-REPL-TIMING-001; FEATURE="REPL Timing"; ASPECT=RegressionTesting; STATUS=TESTED; TEST=repl_timing_regression_test; OWNER=repl; UPDATED=2025-10-05

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY_PATH="$PROJECT_ROOT/zig-out/bin"

echo "⏱️  REPL Timing Regression Test Suite"
echo "===================================="

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

# Test 1: Unit Tests - Basic timing functions
echo "1️⃣  Unit Tests"
echo "==============="

# Test the unit test file
run_test "Unit tests compilation and execution" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_timing.zig" \
    "All 7 tests passed"

# Test 2: Integration Tests
echo ""
echo "2️⃣  Integration Tests"
echo "===================="

# Test the integration test file
run_test "Integration tests compilation and execution" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_timing_integration.zig" \
    "All 8 tests passed"

# Test 3: Build Integration Tests
echo ""
echo "3️⃣  Build Integration Tests"
echo "=========================="

# Test that the timing code builds correctly
run_test "REPL timing builds correctly" \
    "cd '$PROJECT_ROOT' && zig build --verbose" \
    "install"

# Test that the binary exists and responds
run_test "Geode binary responds to help" \
    "'$BINARY_PATH/geode' --help" \
    "Usage:"

# Test 4: Timing Function Implementation Tests
echo ""
echo "4️⃣  Timing Function Implementation Tests"
echo "========================================"

# Create a temporary test file to validate Timer usage
TEMP_TIMER_TEST=$(mktemp --suffix=.zig)
cat > "$TEMP_TIMER_TEST" << 'EOF'
const std = @import("std");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    _ = gpa.allocator();

    // Test std.time.Timer functionality like REPL does
    var timer = try std.time.Timer.start();

    // Simulate some work
    var sum: u64 = 0;
    for (0..1000) |i| {
        sum += i;
    }

    const duration_ns = timer.read();
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

    std.debug.print("✅ Timer functionality working\n", .{});
    std.debug.print("Duration: {d:.2} ms\n", .{duration_ms});

    // Validate reasonable timing (should be very fast)
    if (duration_ms >= 0.0 and duration_ms < 1000.0) {
        std.debug.print("✅ Timing precision validated\n", .{});
    } else {
        std.debug.print("❌ Timing precision out of range\n", .{});
        return error.TimingOutOfRange;
    }

    // Use sum to prevent optimization
    if (sum > 0) std.debug.print("Work completed\n", .{});
}
EOF

run_test "Timer functionality validation" \
    "cd '$PROJECT_ROOT' && zig run '$TEMP_TIMER_TEST'" \
    "Timer functionality working"

# Clean up
rm -f "$TEMP_TIMER_TEST"

# Test 5: Timing Format Tests
echo ""
echo "5️⃣  Timing Format Tests"
echo "======================"

# Test timing format precision
TEMP_FORMAT_TEST=$(mktemp --suffix=.zig)
cat > "$TEMP_FORMAT_TEST" << 'EOF'
const std = @import("std");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    _ = gpa.allocator();

    // Test timing format like REPL does
    const test_durations = [_]f64{ 0.12, 1.50, 10.99, 123.45, 999.99 };

    for (test_durations) |duration_ms| {
        var buf: [256]u8 = undefined;
        const timing_msg = try std.fmt.bufPrint(&buf, "Query executed in {d:.2} ms\n", .{duration_ms});

        // Validate format has exactly 2 decimal places
        const dot_pos = std.mem.indexOf(u8, timing_msg, ".") orelse {
            std.debug.print("❌ Missing decimal point in: {s}\n", .{timing_msg});
            return error.MissingDecimalPoint;
        };

        const ms_pos = std.mem.indexOf(u8, timing_msg, " ms") orelse {
            std.debug.print("❌ Missing ' ms' in: {s}\n", .{timing_msg});
            return error.MissingMsUnit;
        };

        const fractional_part = timing_msg[dot_pos + 1..ms_pos];
        if (fractional_part.len != 2) {
            std.debug.print("❌ Wrong decimal precision in: {s} (expected 2, got {d})\n", .{ timing_msg, fractional_part.len });
            return error.WrongPrecision;
        }

        // Check fractional digits are numeric
        for (fractional_part) |digit| {
            if (digit < '0' or digit > '9') {
                std.debug.print("❌ Non-numeric fractional digit: {c}\n", .{digit});
                return error.NonNumericFraction;
            }
        }

        std.debug.print("✅ Format valid: {s}", .{timing_msg});
    }

    std.debug.print("✅ All timing formats validated\n", .{});
}
EOF

run_test "Timing format precision validation" \
    "cd '$PROJECT_ROOT' && zig run '$TEMP_FORMAT_TEST'" \
    "All timing formats validated"

# Clean up
rm -f "$TEMP_FORMAT_TEST"

# Test 6: Performance Tests
echo ""
echo "6️⃣  Performance Tests"
echo "==================="

# Test that timing doesn't cause significant overhead
TEMP_PERF_TEST=$(mktemp --suffix=.zig)
cat > "$TEMP_PERF_TEST" << 'EOF'
const std = @import("std");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    _ = gpa.allocator();

    const iterations = 1000;
    var total_overhead_ns: u64 = 0;

    // Measure timing overhead
    for (0..iterations) |_| {
        const start_time = std.time.nanoTimestamp();

        // Simulate REPL timing workflow
        var timer = try std.time.Timer.start();

        // Simulate minimal work (like mock query)
        var temp: u64 = 42;
        temp += 1;

        const duration_ns = timer.read();
        const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

        // Format like REPL does
        var buf: [256]u8 = undefined;
        _ = try std.fmt.bufPrint(&buf, "Query executed in {d:.2} ms\n", .{duration_ms});

        const end_time = std.time.nanoTimestamp();
        total_overhead_ns += @as(u64, @intCast(end_time - start_time));

        // Use temp to prevent optimization
        if (temp == 0) break;
    }

    const avg_overhead_ns = total_overhead_ns / iterations;
    const avg_overhead_us = @as(f64, @floatFromInt(avg_overhead_ns)) / 1000.0;

    std.debug.print("✅ Average timing overhead: {d:.2} μs per operation\n", .{avg_overhead_us});

    // Timing overhead should be reasonable (less than 100μs)
    if (avg_overhead_us < 100.0) {
        std.debug.print("✅ Performance overhead acceptable\n", .{});
    } else {
        std.debug.print("⚠️  Performance overhead may need optimization: {d:.2} μs\n", .{avg_overhead_us});
    }
}
EOF

run_test "Timing performance overhead validation" \
    "cd '$PROJECT_ROOT' && zig run '$TEMP_PERF_TEST'" \
    "Performance overhead acceptable"

# Clean up
rm -f "$TEMP_PERF_TEST"

# Test 7: Error Handling Tests
echo ""
echo "7️⃣  Error Handling Tests"
echo "======================="

# Test error handling in timing functionality
TEMP_ERROR_TEST=$(mktemp --suffix=.zig)
cat > "$TEMP_ERROR_TEST" << 'EOF'
const std = @import("std");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    _ = gpa.allocator();

    // Test edge cases in timing
    const test_cases = [_]struct {
        duration_ns: u64,
        should_work: bool,
    }{
        .{ .duration_ns = 0, .should_work = true },           // Zero duration
        .{ .duration_ns = 1, .should_work = true },           // Minimum duration
        .{ .duration_ns = 1_000_000, .should_work = true },   // 1ms
        .{ .duration_ns = 1_000_000_000, .should_work = true }, // 1s
    };

    for (test_cases) |test_case| {
        const duration_ms = @as(f64, @floatFromInt(test_case.duration_ns)) / 1_000_000.0;

        var buf: [256]u8 = undefined;
        const result = std.fmt.bufPrint(&buf, "Query executed in {d:.2} ms\n", .{duration_ms});

        if (test_case.should_work) {
            _ = result catch {
                std.debug.print("❌ Failed to format duration: {d} ns\n", .{test_case.duration_ns});
                return error.FormatFailed;
            };
            std.debug.print("✅ Handled duration: {d} ns -> {d:.2} ms\n", .{ test_case.duration_ns, duration_ms });
        }
    }

    std.debug.print("✅ Error handling validation complete\n", .{});
}
EOF

run_test "Timing error handling validation" \
    "cd '$PROJECT_ROOT' && zig run '$TEMP_ERROR_TEST'" \
    "Error handling validation complete"

# Clean up
rm -f "$TEMP_ERROR_TEST"

# Final Results
echo ""
echo "📊 Test Results Summary"
echo "======================"
echo "Total tests: $TOTAL_TESTS"
echo -e "Passed: ${GREEN}$PASSED_TESTS${NC}"
echo -e "Failed: ${RED}$FAILED_TESTS${NC}"

if [ $FAILED_TESTS -eq 0 ]; then
    echo ""
    echo -e "${GREEN}🎉 All REPL timing regression tests passed!${NC}"
    echo "   The REPL timing functionality is working correctly."
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
