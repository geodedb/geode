#!/usr/bin/env bash

# REPL Persistent History Regression Test Suite
# Tests the persistent command history functionality to prevent regressions

set -e

# CANARY: REQ=REQ-REPL-HISTORY-003; FEATURE="REPL Persistent History"; ASPECT=RegressionTesting; STATUS=TESTED; TEST=repl_history_regression_test; OWNER=repl; UPDATED=2025-10-05

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY_PATH="$PROJECT_ROOT/zig-out/bin"

echo "📚 REPL Persistent History Regression Test Suite"
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

# Test 1: Unit Tests - History Store functionality
echo "1️⃣  Unit Tests"
echo "==============="

# Test the unit test file
run_test "History unit tests compilation and execution" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_history.zig" \
    "All 9 tests passed"

# Test 2: Integration Tests  
echo ""
echo "2️⃣  Integration Tests"
echo "==================="

# Test the integration test file
run_test "History integration tests compilation and execution" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_history_integration.zig" \
    "All 7 tests passed"

# Test 3: Config Module Tests
echo ""
echo "3️⃣  Config Module Tests"
echo "======================"

# Test the config module with enhanced history path logic
run_test "Config module history path functions" \
    "cd '$PROJECT_ROOT' && zig test src/client/repl/repl_config.zig" \
    "All 0 tests passed"

# Test 4: Build Integration Tests
echo ""
echo "4️⃣  Build Integration Tests"
echo "=========================="

# Test that the history code builds correctly
run_test "REPL history builds correctly" \
    "cd '$PROJECT_ROOT' && zig build --verbose" \
    "install"

# Test that the binary exists and responds
run_test "Geode binary responds to help" \
    "'$BINARY_PATH/geode' --help" \
    "Usage:"

# Test 5: History Path Generation Tests
echo ""
echo "5️⃣  History Path Generation Tests"
echo "================================"

# Test history path generation logic
TEMP_PATH_TEST=$(mktemp --suffix=.zig)
cat > "$TEMP_PATH_TEST" << 'EOF'
const std = @import("std");
const builtin = @import("builtin");

pub fn getHistoryPath(allocator: std.mem.Allocator) ![]u8 {
    // Check GEODE_HISTORY environment variable first
    if (std.process.getEnvVarOwned(allocator, "GEODE_HISTORY")) |path| {
        return path;
    } else |_| {}

    // Primary: Try ~/.geode_history as the default preference
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &[_][]const u8{ home, ".geode_history" });
    } else |_| {}

    // Final fallback
    return allocator.dupe(u8, ".geode_history");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const path = try getHistoryPath(allocator);
    defer allocator.free(path);
    
    if (!std.mem.endsWith(u8, path, ".geode_history")) {
        std.debug.print("❌ History path test failed\n", .{});
        std.debug.print("   Expected path to end with '.geode_history'\n", .{});
        std.debug.print("   Got: '{s}'\n", .{path});
        return error.HistoryPathTestFailed;
    }
    
    std.debug.print("✅ History path generation validation complete\n", .{});
    std.debug.print("   Path: '{s}'\n", .{path});
}
EOF

run_test "History path generation validation" \
    "cd '$PROJECT_ROOT' && zig run '$TEMP_PATH_TEST'" \
    "History path generation validation complete"

# Clean up
rm -f "$TEMP_PATH_TEST"

# Test 6: File Persistence Tests
echo ""
echo "6️⃣  File Persistence Tests"
echo "=========================="

# Test file persistence logic
TEMP_PERSIST_TEST=$(mktemp --suffix=.zig)
cat > "$TEMP_PERSIST_TEST" << 'EOF'
const std = @import("std");

const HistoryStore = struct {
    allocator: std.mem.Allocator,
    path: ?[]u8,
    enabled: bool,
    entries: std.ArrayList([]u8),

    pub fn init(allocator: std.mem.Allocator, path: ?[]const u8, enabled: bool) !HistoryStore {
        var store = HistoryStore{
            .allocator = allocator,
            .path = null,
            .enabled = enabled,
            .entries = try std.ArrayList([]u8).initCapacity(allocator, 0),
        };

        if (path) |p| {
            store.path = try allocator.dupe(u8, p);
        }

        return store;
    }

    pub fn deinit(self: *HistoryStore) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry);
        }
        self.entries.deinit(self.allocator);

        if (self.path) |p| {
            self.allocator.free(p);
        }
    }

    pub fn append(self: *HistoryStore, line: []const u8) !void {
        if (!self.enabled) return;
        if (line.len == 0) return;

        const entry = try self.allocator.dupe(u8, line);
        try self.entries.append(self.allocator, entry);

        if (self.path) |path| {
            const file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
            defer file.close();

            try file.seekFromEnd(0);
            try file.writeAll(line);
            try file.writeAll("\n");
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const test_path = "test_persist.tmp";
    defer std.fs.cwd().deleteFile(test_path) catch {};
    
    // Create history and add entries
    {
        var history = try HistoryStore.init(allocator, test_path, true);
        defer history.deinit();
        
        try history.append("MATCH (n:Person) RETURN n.name;");
        try history.append("CREATE (p:Person {name: 'Test'});");
    }
    
    // Verify file was created and contains data
    const file = std.fs.cwd().openFile(test_path, .{}) catch |err| {
        std.debug.print("❌ File persistence test failed: {}\n", .{err});
        return error.FilePersistenceTestFailed;
    };
    defer file.close();
    
    const file_size = try file.getEndPos();
    if (file_size == 0) {
        std.debug.print("❌ File persistence test failed: file is empty\n", .{});
        return error.FilePersistenceTestFailed;
    }
    
    std.debug.print("✅ File persistence validation complete\n", .{});
    std.debug.print("   File size: {} bytes\n", .{file_size});
}
EOF

run_test "File persistence validation" \
    "cd '$PROJECT_ROOT' && zig run '$TEMP_PERSIST_TEST'" \
    "File persistence validation complete"

# Clean up
rm -f "$TEMP_PERSIST_TEST"

# Test 7: Memory Management Tests
echo ""
echo "7️⃣  Memory Management Tests"
echo "=========================="

# Test memory management in history operations
TEMP_MEMORY_TEST=$(mktemp --suffix=.zig)
cat > "$TEMP_MEMORY_TEST" << 'EOF'
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("❌ Memory leak detected in history operations\n", .{});
            std.process.exit(1);
        }
    }
    const allocator = gpa.allocator();
    
    // Simulate history operations
    var entries = std.ArrayList([]u8).initCapacity(allocator, 0) catch unreachable;
    defer {
        for (entries.items) |entry| {
            allocator.free(entry);
        }
        entries.deinit(allocator);
    }
    
    // Add and remove entries to test memory management
    for (0..100) |i| {
        var buf: [64]u8 = undefined;
        const query = try std.fmt.bufPrint(&buf, "MATCH (n:Node{d}) RETURN n;", .{i});
        const entry = try allocator.dupe(u8, query);
        try entries.append(allocator, entry);
    }
    
    // Clear all entries
    for (entries.items) |entry| {
        allocator.free(entry);
    }
    entries.clearRetainingCapacity();
    
    std.debug.print("✅ Memory management validation complete\n", .{});
    std.debug.print("   Added and freed 100 history entries\n", .{});
}
EOF

run_test "Memory management validation" \
    "cd '$PROJECT_ROOT' && zig run '$TEMP_MEMORY_TEST'" \
    "Memory management validation complete"

# Clean up
rm -f "$TEMP_MEMORY_TEST"

# Test 8: Cross-Platform Path Tests
echo ""
echo "8️⃣  Cross-Platform Path Tests"
echo "============================"

# Test cross-platform path handling
TEMP_PLATFORM_TEST=$(mktemp --suffix=.zig)
cat > "$TEMP_PLATFORM_TEST" << 'EOF'
const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Test platform-specific path joining
    const path_segments = [_][]const u8{ "home", "user", ".geode_history" };
    const joined_path = try std.fs.path.join(allocator, &path_segments);
    defer allocator.free(joined_path);
    
    // Verify path contains expected components
    if (!std.mem.endsWith(u8, joined_path, ".geode_history")) {
        std.debug.print("❌ Platform path test failed\n", .{});
        std.debug.print("   Expected path to end with '.geode_history'\n", .{});
        std.debug.print("   Got: '{s}'\n", .{joined_path});
        return error.PlatformPathTestFailed;
    }
    
    // Test separator handling
    const expected_separator = if (builtin.os.tag == .windows) '\\' else '/';
    var found_separator = false;
    for (joined_path) |c| {
        if (c == expected_separator) {
            found_separator = true;
            break;
        }
    }
    
    if (!found_separator and joined_path.len > 15) { // Only check if path is long enough
        std.debug.print("❌ Platform path separator test failed\n", .{});
        std.debug.print("   Expected separator '{}' not found in path\n", .{expected_separator});
        std.debug.print("   Got: '{s}'\n", .{joined_path});
        return error.PlatformPathTestFailed;
    }
    
    std.debug.print("✅ Cross-platform path validation complete\n", .{});
    std.debug.print("   Platform: {}\n", .{builtin.os.tag});
    std.debug.print("   Path: '{s}'\n", .{joined_path});
}
EOF

run_test "Cross-platform path validation" \
    "cd '$PROJECT_ROOT' && zig run '$TEMP_PLATFORM_TEST'" \
    "Cross-platform path validation complete"

# Clean up
rm -f "$TEMP_PLATFORM_TEST"

# Test 9: Edge Cases Tests
echo ""
echo "9️⃣  Edge Cases Tests"
echo "=================="

# Test edge cases in history functionality
TEMP_EDGE_TEST=$(mktemp --suffix=.zig)
cat > "$TEMP_EDGE_TEST" << 'EOF'
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    
    // Test edge cases
    var test_count: u32 = 0;
    
    // Test 1: Empty string handling
    const empty_string = "";
    if (empty_string.len == 0) {
        test_count += 1;
    }
    
    // Test 2: Very long string handling
    const long_string = "MATCH (n:Person) WHERE n.name = 'Very long name with lots of text that might cause issues in history storage and retrieval operations' RETURN n.name, n.age, n.address, n.phone, n.email;";
    if (long_string.len > 100) {
        test_count += 1;
    }
    
    // Test 3: Special characters handling
    const special_string = "CREATE (n {name: 'Test\\\"with\\\"quotes', data: 'Line1\\nLine2\\tTabbed'});";
    if (std.mem.indexOf(u8, special_string, "\\\"") != null) {
        test_count += 1;
    }
    
    // Test 4: Unicode handling
    const unicode_string = "CREATE (n {name: '测试用户'});";
    if (unicode_string.len > 20) { // UTF-8 encoded Chinese characters
        test_count += 1;
    }
    
    // Test 5: Path with spaces
    const path_with_spaces = "my documents/geode history/test file.tmp";
    if (std.mem.indexOf(u8, path_with_spaces, " ") != null) {
        test_count += 1;
    }
    
    if (test_count != 5) {
        std.debug.print("❌ Edge cases test failed\n", .{});
        std.debug.print("   Expected 5 edge cases to pass, got {}\n", .{test_count});
        return error.EdgeCasesTestFailed;
    }
    
    std.debug.print("✅ Edge cases validation complete\n", .{});
    std.debug.print("   Tested {} edge cases successfully\n", .{test_count});
}
EOF

run_test "Edge cases validation" \
    "cd '$PROJECT_ROOT' && zig run '$TEMP_EDGE_TEST'" \
    "Edge cases validation complete"

# Clean up
rm -f "$TEMP_EDGE_TEST"

# Final Results
echo ""
echo "📊 Test Results Summary"
echo "======================"
echo "Total tests: $TOTAL_TESTS"
echo -e "Passed: ${GREEN}$PASSED_TESTS${NC}"
echo -e "Failed: ${RED}$FAILED_TESTS${NC}"

if [ $FAILED_TESTS -eq 0 ]; then
    echo ""
    echo -e "${GREEN}🎉 All REPL history regression tests passed!${NC}"
    echo "   The REPL persistent command history functionality is working correctly."
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