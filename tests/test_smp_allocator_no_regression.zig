// Regression test for GAP-0754 — graph_store.global_allocator is smp_allocator.
//
// Triage:  docs/superpowers/plans/2026-04-18-match-qps-close-gap.md (Task 2)
// Summary: Before GAP-0754 `graph_store.global_gpa` was a
//          `std.heap.DebugAllocator(.{})` whose internal mutex serialized every
//          alloc/free. After GAP-0753 narrowed the handler lock-hold window,
//          allocator contention became the next bottleneck on the MATCH hot
//          path. This test pins the contract that the graph_store global
//          allocator is `std.heap.smp_allocator` — a sharded per-core
//          allocator with thread-local fast paths — by measuring that a tight
//          alloc/free loop completes in a budget the DebugAllocator cannot
//          hit.
//
// Test design:
//   * Warmup: 10_000 alloc/free round-trips of 64-byte buffers through
//     graph_store.global_allocator(). Compiles iff the new public accessor
//     exists.
//   * Measurement: 100_000 alloc/free pairs of 64-byte buffers. Budget: 50 ms
//     on typical hardware. DebugAllocator's internal mutex pushes this well
//     over 200 ms; smp_allocator's thread-local fast path finishes in
//     10–20 ms.
//
// CANARY: REQ=REQ-PERF-GRAPH-STORE-ALLOC-001; FEATURE="GraphStoreGlobalAllocator"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_smp_allocator_no_regression.zig:1; OWNER=storage; UPDATED=2026-04-18

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;

// Zig 0.16 compat: std.time.Timer / std.time.nanoTimestamp were removed.
// Use clock_gettime directly for monotonic nanosecond timestamps (mirrors
// tests/test_handler_lock_hold_scope.zig:38-42).
fn monoNanos() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

test "graph_store.global_allocator completes 100k 64B alloc/free pairs under 50ms" {
    const alloc = graph_store.global_allocator();

    // Warmup — also verifies the public accessor symbol exists.
    const warmup_iters: usize = 10_000;
    var i: usize = 0;
    while (i < warmup_iters) : (i += 1) {
        const buf = try alloc.alloc(u8, 64);
        // Touch the allocation to keep the compiler honest.
        buf[0] = @as(u8, @truncate(i));
        alloc.free(buf);
    }

    // Measurement — 100k alloc/free pairs of 64-byte buffers.
    const iters: usize = 100_000;
    const t_start = monoNanos();
    i = 0;
    while (i < iters) : (i += 1) {
        const buf = try alloc.alloc(u8, 64);
        buf[0] = @as(u8, @truncate(i));
        alloc.free(buf);
    }
    const t_end = monoNanos();

    const elapsed_ns = t_end - t_start;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const budget_ms: f64 = 50.0;

    if (elapsed_ms > budget_ms) {
        std.debug.print(
            "graph_store.global_allocator took {d:.3} ms for {d} 64-byte " ++
                "alloc/free pairs (budget {d:.1} ms). DebugAllocator's " ++
                "internal mutex was serializing allocs; smp_allocator " ++
                "should finish well under budget.\n",
            .{ elapsed_ms, iters, budget_ms },
        );
        return error.GlobalAllocatorTooSlow;
    }
}
