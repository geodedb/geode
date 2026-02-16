#!/usr/bin/env bash

# REPL Persistent History Regression Test Suite
# Tests the persistent command history functionality to prevent regressions

set -euo pipefail

# CANARY: REQ=REQ-REPL-HISTORY-003; FEATURE="REPL Persistent History"; ASPECT=RegressionTesting; STATUS=TESTED; TEST=repl_history_regression_test; OWNER=repl; UPDATED=2026-02-16

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY_PATH="$PROJECT_ROOT/zig-out/bin/geode"

# shellcheck source=tests/repl_regression_common.sh
source "$SCRIPT_DIR/repl_regression_common.sh"

repl_suite_header "📚 REPL Persistent History Regression Test Suite" "=============================================="
repl_require_binary "$BINARY_PATH"

echo "1️⃣  Unit and Integration Tests"
echo "=============================="
repl_run_test "History unit tests" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_history.zig" \
    "All 9 tests passed"
repl_run_test "History integration tests" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_history_integration.zig" \
    "All 7 tests passed"

echo ""
echo "2️⃣  Targeted Regression Cases"
echo "============================="
repl_run_test "History path generation logic" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_history.zig --test-filter 'History path generation logic'"
repl_run_test "History persistence and loading" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_history.zig --test-filter 'HistoryStore persistence and loading'"
repl_run_test "History duplicate suppression" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_history.zig --test-filter 'HistoryStore append and duplicate detection'"
repl_run_test "History disabled mode" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_history.zig --test-filter 'HistoryStore disabled mode'"

echo ""
echo "3️⃣  Build and Binary Sanity"
echo "==========================="
repl_run_test "REPL history build path" \
    "cd '$PROJECT_ROOT' && zig build"
repl_run_test "Geode binary help responds" \
    "'$BINARY_PATH' --help" \
    "Usage:"

repl_suite_summary
