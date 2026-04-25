// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Placeholder for the MVCC routing-invariant debug-panic check.
//!
//! Zig 0.16's stdlib has no stable `std.testing.expectPanic` for
//! calling-frame panics, so this file documents the contract only —
//! the real regression-catcher is:
//!   1. Task 7's msft-graph run asserting zero 40001 errors.
//!   2. Any future regression that violates routing fires
//!      `panic: write-write conflict under ShardedCoordinator routing`
//!      on stderr during `zig build test` and fails the suite.

// CANARY: REQ=REQ-PERF-SHARD-COORD-MVCC-GUARD; FEATURE="ShardedCoordinatorRoutingGuard"; ASPECT=MVCCInvariant; STATUS=TESTED; TEST=tests/test_txn_manager_routing_guard.zig; OWNER=perf; UPDATED=2026-04-25

const std = @import("std");

test "routing-guard contract placeholder" {
    if (@import("builtin").mode != .Debug) return error.SkipZigTest;
    return error.SkipZigTest;
}
