#!/usr/bin/env bash
set -euo pipefail

# REPL Formatting Fixes Regression Test Suite
# Tests output formatting fixes for terminal display regressions

set -euo pipefail

# CANARY: REQ=REQ-REPL-FORMAT-003; FEATURE="REPL Formatting Fixes"; ASPECT=RegressionTesting; STATUS=TESTED; TEST=repl_formatting_fixes_regression_test; OWNER=repl; UPDATED=2026-02-16

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY_PATH="$PROJECT_ROOT/zig-out/bin/geode"

# shellcheck source=tests/repl_regression_common.sh
source "$SCRIPT_DIR/repl_regression_common.sh"

repl_suite_header "🧪 REPL Formatting Fixes Regression Test Suite" "=============================================="
repl_require_binary "$BINARY_PATH"

echo "1️⃣  Core Formatting Fixes Test File"
echo "==================================="
repl_run_test "Formatting fixes full suite" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_formatting_fixes.zig" \
    "All 13 tests passed"

echo ""
echo "2️⃣  Targeted Regression Cases"
echo "============================="
repl_run_test "CSV newline behavior" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_formatting_fixes.zig --test-filter 'CSV format includes proper newlines'"
repl_run_test "Table line ending consistency" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_formatting_fixes.zig --test-filter 'Table format has consistent line endings'"
repl_run_test "ANSI prompt rendering" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_formatting_fixes.zig --test-filter 'Prompt rendering includes ANSI escape sequences'"
repl_run_test "Welcome formatting consistency" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_formatting_fixes.zig --test-filter 'Welcome message formatting consistency'"
repl_run_test "Flush simulation" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_formatting_fixes.zig --test-filter 'Output flushing simulation'"

echo ""
echo "3️⃣  Build and Binary Sanity"
echo "==========================="
repl_run_test "Formatting fixes build path" \
    "cd '$PROJECT_ROOT' && zig build"
repl_run_test "Geode binary help responds" \
    "'$BINARY_PATH' --help" \
    "Usage:"

repl_suite_summary
