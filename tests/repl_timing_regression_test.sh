#!/usr/bin/env bash
set -euo pipefail

# REPL Timing Regression Test Suite
# Tests timing behavior and command handling to prevent regressions

set -euo pipefail

# CANARY: REQ=REQ-REPL-TIMING-001; FEATURE="REPL Timing"; ASPECT=RegressionTesting; STATUS=TESTED; TEST=repl_timing_regression_test; OWNER=repl; UPDATED=2026-02-16

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY_PATH="$PROJECT_ROOT/zig-out/bin/geode"

# shellcheck source=tests/repl_regression_common.sh
source "$SCRIPT_DIR/repl_regression_common.sh"

repl_suite_header "⏱️  REPL Timing Regression Test Suite" "===================================="
repl_require_binary "$BINARY_PATH"

echo "1️⃣  Unit and Integration Tests"
echo "=============================="
repl_run_test "Timing unit tests" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_timing.zig" \
    "All 7 tests passed"
repl_run_test "Timing integration tests" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_timing_integration.zig" \
    "All 8 tests passed"

echo ""
echo "2️⃣  Targeted Timing Regression Cases"
echo "===================================="
repl_run_test "Timing precision validation" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_timing.zig --test-filter 'Timing precision validation'"
repl_run_test "Timing format validation" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_timing.zig --test-filter 'Timing format validation'"
repl_run_test "Timing toggle functionality" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_timing_integration.zig --test-filter 'Timing command - toggle functionality'"
repl_run_test "Timing state persistence" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_timing_integration.zig --test-filter 'Timing state persistence'"

echo ""
echo "3️⃣  Build and Binary Sanity"
echo "==========================="
repl_run_test "REPL timing build path" \
    "cd '$PROJECT_ROOT' && zig build"
repl_run_test "Geode binary help responds" \
    "'$BINARY_PATH' --help" \
    "Usage:"

repl_suite_summary
