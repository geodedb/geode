#!/usr/bin/env bash

# REPL Formatting Regression Test Suite
# Tests REPL output formatting behavior to prevent regressions

set -euo pipefail

# CANARY: REQ=REQ-REPL-FORMAT-001; FEATURE="REPL Output Formatting"; ASPECT=RegressionTesting; STATUS=TESTED; TEST=repl_formatting_regression_test; OWNER=repl; UPDATED=2026-02-16

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY_PATH="$PROJECT_ROOT/zig-out/bin/geode"

# shellcheck source=tests/repl_regression_common.sh
source "$SCRIPT_DIR/repl_regression_common.sh"

repl_suite_header "🧪 REPL Formatting Regression Test Suite" "========================================="
repl_require_binary "$BINARY_PATH"

echo "1️⃣  Unit and Integration Tests"
echo "=============================="
repl_run_test "Formatting unit tests" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_formatting.zig" \
    "All 12 tests passed"
repl_run_test "Formatting integration tests" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_formatting_integration.zig" \
    "All 8 tests passed"

echo ""
echo "2️⃣  Targeted Formatting Regression Cases"
echo "========================================"
repl_run_test "Malformed JSON fallback" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_formatting.zig --test-filter 'Malformed JSON fallback'"
repl_run_test "Status message format detection" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_formatting.zig --test-filter 'Status message format detection'"
repl_run_test "Memory management verification" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_formatting_integration.zig --test-filter 'Memory management verification'"

echo ""
echo "3️⃣  Formatting Fixes Cross-Checks"
echo "================================="
repl_run_test "Prompt ANSI rendering" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_formatting_fixes.zig --test-filter 'Prompt rendering includes ANSI escape sequences'"
repl_run_test "Output newline consistency" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_formatting_fixes.zig --test-filter 'Output contains leading newline for query results'"

echo ""
echo "4️⃣  Build and Binary Sanity"
echo "==========================="
repl_run_test "REPL formatting build path" \
    "cd '$PROJECT_ROOT' && zig build"
repl_run_test "Geode binary help responds" \
    "'$BINARY_PATH' --help" \
    "Usage:"

repl_suite_summary
