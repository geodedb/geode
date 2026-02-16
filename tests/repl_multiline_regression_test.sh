#!/usr/bin/env bash

# REPL Multi-line Input Regression Test Suite
# Tests multi-line input behavior to prevent regressions

set -euo pipefail

# CANARY: REQ=REQ-REPL-MULTILINE-001; FEATURE="REPL Multi-line Input"; ASPECT=RegressionTesting; STATUS=TESTED; TEST=repl_multiline_regression_test; OWNER=repl; UPDATED=2026-02-16

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY_PATH="$PROJECT_ROOT/zig-out/bin/geode"

# shellcheck source=tests/repl_regression_common.sh
source "$SCRIPT_DIR/repl_regression_common.sh"

repl_suite_header "📝 REPL Multi-line Input Regression Test Suite" "=============================================="
repl_require_binary "$BINARY_PATH"

echo "1️⃣  Unit and Integration Tests"
echo "=============================="
repl_run_test "Multi-line unit tests" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_multiline.zig" \
    "All 8 tests passed"
repl_run_test "Multi-line integration tests" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_multiline_integration.zig" \
    "All 8 tests passed"
repl_run_test "REPL parse module tests" \
    "cd '$PROJECT_ROOT' && zig test src/client/repl/repl_parse.zig" \
    "All 2 tests passed"

echo ""
echo "2️⃣  Targeted Multi-line Regression Cases"
echo "========================================"
repl_run_test "Continuation state management" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_multiline.zig --test-filter 'Continuation state management'"
repl_run_test "Prompt formatting consistency" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_multiline_integration.zig --test-filter 'Prompt formatting consistency'"
repl_run_test "Complex nested query handling" \
    "cd '$PROJECT_ROOT' && zig test tests/test_repl_multiline_integration.zig --test-filter 'Complex nested query with multiple brackets'"

echo ""
echo "3️⃣  Build and Binary Sanity"
echo "==========================="
repl_run_test "REPL multi-line build path" \
    "cd '$PROJECT_ROOT' && zig build"
repl_run_test "Geode binary help responds" \
    "'$BINARY_PATH' --help" \
    "Usage:"

repl_suite_summary
