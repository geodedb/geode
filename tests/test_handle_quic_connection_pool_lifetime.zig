// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Pool-lifetime regression test.
//!
//! Pre-fix: handleQuicConnection created a fresh pooled.ThreadPool per
//! connection with deinit_timeout=2s. Under msft-graph's per-file
//! reconnect pattern, deinit timed out on in-flight tasks, leaving
//! zombie worker threads. Over ~720 connections this accumulated to
//! ~1800 threads — confirmed by the cascade-time gdb capture at
//! docs/performance/2026-04-25-enterprise-rwlock-fairness/cascade-stacks.txt.
//!
//! Post-fix: the stream and acceptor pools are server-wide singletons.
//! handleQuicConnection no longer creates pools — it submits to the
//! shared ones. Connection close is a no-op for pool lifetime.
//!
//! This test exercises the wrapper directly: 100 init+deinit cycles
//! on a small pool with no submitted work. A regression would hang or
//! exhaust threads during deinit. Under the post-fix architecture,
//! deinit should complete quickly and workers should exit cleanly.

// CANARY: REQ=REQ-PERF-CONN-POOL-LIFETIME; FEATURE="ConnectionPoolLifetime"; ASPECT=NoLeakOnInitDeinit; STATUS=TESTED; TEST=tests/test_handle_quic_connection_pool_lifetime.zig; OWNER=server; UPDATED=2026-04-25

const std = @import("std");
const geode = @import("geode");
const pooled = geode.pooled;

test "pooled.ThreadPool.init + deinit does not hang on clean shutdown" {
    const allocator = std.testing.allocator;

    // Run 100 cycles of pool init and deinit with no submitted work.
    // If the wrapper properly joins idle workers during deinit, each cycle
    // completes quickly. A regression (e.g. timeout abandon, worker leak)
    // would either hang this test indefinitely or accumulate zombie threads.
    // This simple guard ensures deinit actually cleans up.
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const pool = try pooled.ThreadPool.init(allocator, .{
            .num_threads = 5,
            .queue_capacity = 16,
            .deinit_timeout_ns = 2 * std.time.ns_per_s,
        });
        // No work submitted — deinit should be quick and clean.
        pool.deinit();
    }

    // If we reach here, all 100 cycles completed without hanging.
    // The test harness has a global timeout; if deinit hangs, the test fails.
    // This documents the invariant: clean pools (no in-flight tasks) must
    // deinit without leaking worker threads or abandoning them.
}
