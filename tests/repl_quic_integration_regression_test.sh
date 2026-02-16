#!/usr/bin/env bash

# REPL QUIC Integration Regression Test Suite

set -euo pipefail

# CANARY: REQ=REQ-REPL-QUIC-001; FEATURE="REPL QUIC Integration"; ASPECT=RegressionTesting; STATUS=TESTED; TEST=repl_quic_integration_regression_test; OWNER=repl; UPDATED=2026-02-16

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY_PATH="$PROJECT_ROOT/zig-out/bin/geode"

# shellcheck source=tests/repl_regression_common.sh
source "$SCRIPT_DIR/repl_regression_common.sh"

repl_suite_header "=== REPL QUIC Integration Regression Test Suite ===" "==============================================="
repl_require_binary "$BINARY_PATH"

echo "1️⃣  Module Compilation Checks"
echo "============================="
repl_run_test "QUIC transport module compiles" \
    "cd '$PROJECT_ROOT' && zig test src/transport/quic.zig"
repl_run_test "Project test build validates REPL modules" \
    "cd '$PROJECT_ROOT' && zig build test --summary all" \
    "566/566 tests passed"

echo ""
echo "2️⃣  Static Integration Assertions"
echo "==============================="
repl_run_test "QUIC packet encode/decode paths" \
    "cd '$PROJECT_ROOT' && grep -q 'ClientPacket{ \\.quic = msg }' src/client/repl/repl_dispatch.zig && grep -q 'ServerPacket{ \\.quic = msg }' src/client/repl/repl_dispatch.zig"
repl_run_test "ClientSession state fields" \
    "cd '$PROJECT_ROOT' && grep -q 'connected: bool = false' src/client/repl/repl_dispatch.zig && grep -q 'last_response: ?\\[\\]u8 = null' src/client/repl/repl_dispatch.zig"
repl_run_test "QUIC CANARY marker exists" \
    "cd '$PROJECT_ROOT' && grep -q 'REQ-REPL-QUIC-001' src/client/repl/repl_dispatch.zig"
repl_run_test "ClientSession connect signature" \
    "cd '$PROJECT_ROOT' && grep -q 'pub fn connect(self: \\*ClientSession) !void' src/client/repl/repl_dispatch.zig"
repl_run_test "ClientSession transaction API" \
    "cd '$PROJECT_ROOT' && grep -q 'pub fn begin(self: \*ClientSession)' src/client/repl/repl_dispatch.zig && grep -q 'pub fn commit(self: \*ClientSession)' src/client/repl/repl_dispatch.zig && grep -q 'pub fn rollback(self: \*ClientSession)' src/client/repl/repl_dispatch.zig"

echo ""
echo "3️⃣  Build and REPL Binary Sanity"
echo "==============================="
repl_run_test "Main project debug build" \
    "cd '$PROJECT_ROOT' && zig build -Doptimize=Debug"
repl_run_test "Geode binary help responds" \
    "'$BINARY_PATH' --help" \
    "Usage:"

repl_suite_summary
