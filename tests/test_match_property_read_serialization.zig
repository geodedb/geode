// Reproduction tests for the MATCH-by-property write-lock serialization bug.
//
// Triage:  docs/audit/LOADTEST_REPORT_2026_04_18_v0.3.5.md
// Summary: src/server/quic_connection_handler.zig:2302-2325 computes
//          `is_mutation` from `query_traits.isMutatingProgram` but
//          never consumes it.  Every non-EXPLAIN query, including
//          read-only MATCH-by-property, acquires the exclusive writer
//          lock via `graph_store.acquireGraphWriteLock`, which forces
//          concurrent point-reads to serialize through one thread.
//          The same bug is mirrored at src/transport/grpc_server.zig:
//          1992-2020.
//
// Observed impact on the loadtest harness (see report above):
//   point_read @ c=1  : 28.6 QPS
//   point_read @ c=2  : 21 QPS   (regression)
//   point_read @ c=4  : 17 QPS   (regression)
//   point_read @ c=8  : 18 QPS   (regression)
//   pure ping @ c=8   : 940 QPS  (transport is fine — serialization is in
//                                 the handler lock)
//
// These tests are intentionally red against commit 0704009b.  They turn
// green when the handler is fixed to pick `acquireGraphReadLock` for
// read-only queries.  The expected fix also updates
// tests/helpers/handler_lock_seam.zig — the mirror exists precisely so
// the reproduction tests exercise the real lock primitives without the
// full QUIC stack.
//
// Test layout:
//   Test A — handler selects READ lock for read-only MATCH  (fails now)
//   Test B — handler selects WRITE lock for MATCH…SET       (already passes)
//   Test C — handler selects NONE for EXPLAIN               (already passes)
//   Test D — concurrent MATCH-by-property scales with threads (fails now)
//   Test E — two MATCH-by-property threads overlap          (fails now)

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;
const seam = @import("handler_lock_seam");

// Zig 0.16 compat: std.time.Timer / std.time.nanoTimestamp were removed.
// Use clock_gettime directly for monotonic nanosecond timestamps (mirrors
// tests/test_thread_pool_lane_parallelism.zig:34-38).
fn monoNanos() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// -------------------------------------------------------------------
// Test A — lock-choice classifier, read-only path
// -------------------------------------------------------------------

test "MATCH-by-property read-only query takes a shared read lock" {
    var result = try geode.parse(
        testing.allocator,
        "MATCH (n:Person {id: 42}) RETURN n",
        .{},
    );
    defer result.deinit();

    const choice = seam.decideLockChoice(&result.program, true);
    if (choice != .read) {
        std.debug.print(
            "MATCH-by-property read-only query took lock={s} (expected 'read'). " ++
                "Handler is still calling acquireGraphWriteLock unconditionally; " ++
                "see src/server/quic_connection_handler.zig:2302-2325 and mirror " ++
                "in tests/helpers/handler_lock_seam.zig.\n",
            .{@tagName(choice)},
        );
        return error.ReadOnlyMatchTookWriteLock;
    }
}

test "bare MATCH / RETURN takes a shared read lock" {
    var result = try geode.parse(
        testing.allocator,
        "MATCH (n:Person) RETURN n LIMIT 10",
        .{},
    );
    defer result.deinit();

    const choice = seam.decideLockChoice(&result.program, true);
    try testing.expectEqual(seam.LockChoice.read, choice);
}

test "RETURN 1 AS x takes a shared read lock" {
    var result = try geode.parse(testing.allocator, "RETURN 1 AS x", .{});
    defer result.deinit();

    const choice = seam.decideLockChoice(&result.program, true);
    try testing.expectEqual(seam.LockChoice.read, choice);
}

// -------------------------------------------------------------------
// Test B — lock-choice classifier, mutation path
// (these should pass today AND after the fix)
// -------------------------------------------------------------------

test "MATCH ... SET takes exclusive write lock" {
    var result = try geode.parse(
        testing.allocator,
        "MATCH (n:Person) SET n.age = 30 RETURN n",
        .{},
    );
    defer result.deinit();

    const choice = seam.decideLockChoice(&result.program, true);
    try testing.expectEqual(seam.LockChoice.write, choice);
}

test "CREATE takes exclusive write lock" {
    var result = try geode.parse(
        testing.allocator,
        "CREATE (n:Person {name: 'Alice'})",
        .{},
    );
    defer result.deinit();

    const choice = seam.decideLockChoice(&result.program, true);
    try testing.expectEqual(seam.LockChoice.write, choice);
}

test "MERGE takes exclusive write lock" {
    var result = try geode.parse(
        testing.allocator,
        "MERGE (n:Person {name: 'Alice'})",
        .{},
    );
    defer result.deinit();

    const choice = seam.decideLockChoice(&result.program, true);
    try testing.expectEqual(seam.LockChoice.write, choice);
}

test "DELETE takes exclusive write lock" {
    var result = try geode.parse(
        testing.allocator,
        "MATCH (n:Person) DELETE n",
        .{},
    );
    defer result.deinit();

    const choice = seam.decideLockChoice(&result.program, true);
    try testing.expectEqual(seam.LockChoice.write, choice);
}

test "MATCH ... REMOVE takes exclusive write lock" {
    var result = try geode.parse(
        testing.allocator,
        "MATCH (n:Person) REMOVE n.age RETURN n",
        .{},
    );
    defer result.deinit();

    const choice = seam.decideLockChoice(&result.program, true);
    try testing.expectEqual(seam.LockChoice.write, choice);
}

test "CREATE GRAPH takes exclusive write lock" {
    var result = try geode.parse(testing.allocator, "CREATE GRAPH g1", .{});
    defer result.deinit();

    const choice = seam.decideLockChoice(&result.program, true);
    try testing.expectEqual(seam.LockChoice.write, choice);
}

test "DROP GRAPH takes exclusive write lock" {
    var result = try geode.parse(testing.allocator, "DROP GRAPH g1", .{});
    defer result.deinit();

    const choice = seam.decideLockChoice(&result.program, true);
    try testing.expectEqual(seam.LockChoice.write, choice);
}

// -------------------------------------------------------------------
// Test C — EXPLAIN bypasses locking entirely
// -------------------------------------------------------------------

test "EXPLAIN bypasses store lock (needs_store_lock=false)" {
    var result = try geode.parse(
        testing.allocator,
        "EXPLAIN MATCH (n) RETURN n",
        .{},
    );
    defer result.deinit();

    // Simulates `analysis.kind == .explain` → `needs_store_lock = false`.
    const choice = seam.decideLockChoice(&result.program, false);
    try testing.expectEqual(seam.LockChoice.none, choice);
}

// -------------------------------------------------------------------
// Test D — concurrent MATCH-by-property scales when the handler takes a
// read lock, serializes when it takes a write lock.
//
// We parse a real read-only MATCH program, then use the seam to acquire
// whichever lock the handler would acquire.  Inside the critical section
// each thread walks a small seeded graph — identical work on every
// thread — for a fixed wall-clock budget.  With a shared read lock the
// wall time is roughly equal to one thread's work time; with an
// exclusive write lock it is N × that.
// -------------------------------------------------------------------

const ConcurrencyCtx = struct {
    query_graph: []const u8,
    program: *const geode.ast.Program,
    per_thread_work_ns: u64,
    iterations_each: u32,
    start_gate: *std.atomic.Value(u32),
    waiting: *std.atomic.Value(u32),
};

fn workUnderHandlerLock(ctx: *ConcurrencyCtx) void {
    // Signal readiness, then busy-wait until every worker is staged.
    _ = ctx.waiting.fetchAdd(1, .acq_rel);
    while (ctx.start_gate.load(.acquire) == 0) {
        std.atomic.spinLoopHint();
    }

    var i: u32 = 0;
    while (i < ctx.iterations_each) : (i += 1) {
        const acquired = seam.acquireHandlerLock(ctx.program, true, ctx.query_graph);
        defer seam.releaseHandlerLock(acquired);

        // Simulate the bounded per-query CPU work a MATCH-by-property
        // performs inside the critical section.  Use a spin — not
        // std.time.sleep — so we actually burn CPU, which is what the
        // serialization penalty applies to.
        const start = monoNanos();
        while (true) {
            const now = monoNanos();
            if (now - start >= ctx.per_thread_work_ns) break;
            std.atomic.spinLoopHint();
        }
    }
}

test "concurrent MATCH-by-property scales across threads" {
    // Seed a small in-process store so the seam's lock calls operate
    // against the real global lock surface.  We are testing the lock
    // itself, not the storage engine, so a mini graph is plenty.
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    const query_graph = "test_match_read_serial_scales";
    store.createGraph(query_graph) catch |err| switch (err) {
        error.GraphAlreadyExists => {},
        else => return err,
    };

    const labels = [_][]const u8{"Person"};
    var seed_i: u32 = 0;
    while (seed_i < 32) : (seed_i += 1) {
        _ = try store.createNodeWithGraph(&labels, query_graph);
    }

    var parse_result = try geode.parse(
        allocator,
        "MATCH (n:Person {id: 1}) RETURN n",
        .{},
    );
    defer parse_result.deinit();

    const n_threads: u32 = 4;
    const iterations_each: u32 = 20;
    const per_thread_work_ns: u64 = 5 * std.time.ns_per_ms; // 5ms per query

    // Measured single-thread baseline. The previous implementation
    // derived a serialized bound from `per_thread_work_ns × N_threads ×
    // iters`, which flaked on contended hosts because the spin-loop's
    // wall-clock stretches under scheduler preemption (CVAT workers,
    // background builds, etc.) while the hardcoded bound stayed fixed.
    // Measuring one thread's actual wall time first makes the ratio
    // host-independent: fully-serialized is ~N×, fully-parallel is ~1×,
    // and the 2× threshold rejects the former while absorbing honest
    // scheduler jitter on any host.
    var baseline_gate = std.atomic.Value(u32).init(1);
    var baseline_waiting = std.atomic.Value(u32).init(0);
    var baseline_ctx = ConcurrencyCtx{
        .query_graph = query_graph,
        .program = &parse_result.program,
        .per_thread_work_ns = per_thread_work_ns,
        .iterations_each = iterations_each,
        .start_gate = &baseline_gate,
        .waiting = &baseline_waiting,
    };
    const baseline_start = monoNanos();
    workUnderHandlerLock(&baseline_ctx);
    const baseline_ns = monoNanos() - baseline_start;

    var start_gate = std.atomic.Value(u32).init(0);
    var waiting = std.atomic.Value(u32).init(0);
    var ctx = ConcurrencyCtx{
        .query_graph = query_graph,
        .program = &parse_result.program,
        .per_thread_work_ns = per_thread_work_ns,
        .iterations_each = iterations_each,
        .start_gate = &start_gate,
        .waiting = &waiting,
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, workUnderHandlerLock, .{&ctx});
    }

    // Wait until every worker reports ready.
    while (waiting.load(.acquire) < n_threads) std.atomic.spinLoopHint();

    const wall_start = monoNanos();
    start_gate.store(1, .release);

    for (&threads) |*t| t.join();
    const wall_end = monoNanos();

    const wall_ns = wall_end - wall_start;

    // Ratio check: parallel wall must be under 2× single-thread baseline.
    // Fully-serialized (the bug) would land near N×baseline = 4×.
    // Perfectly-parallel lands near 1×baseline. The 2× bound cleanly
    // separates the two even with honest scheduler jitter.
    const max_allowed_ns = baseline_ns * 2;

    if (wall_ns > max_allowed_ns) {
        std.debug.print(
            "concurrent MATCH-by-property did NOT scale.  wall={d}ms " ++
                "baseline_1thread={d}ms bound=2×baseline={d}ms threads={d} " ++
                "iters/thread={d} work/query={d}ms.  Handler is serializing " ++
                "reads behind the exclusive writer lock — see " ++
                "src/server/quic_connection_handler.zig:2302-2325.\n",
            .{
                wall_ns / std.time.ns_per_ms,
                baseline_ns / std.time.ns_per_ms,
                max_allowed_ns / std.time.ns_per_ms,
                n_threads,
                iterations_each,
                per_thread_work_ns / std.time.ns_per_ms,
            },
        );
        return error.ConcurrentReadsSerialized;
    }
}

// -------------------------------------------------------------------
// Test E — narrow overlap check: two threads each take the handler's
// lock simultaneously.  With a read lock they overlap; with a write
// lock the second strictly serializes after the first.
// -------------------------------------------------------------------

const OverlapCtx = struct {
    query_graph: []const u8,
    program: *const geode.ast.Program,
    hold_ns: u64,
    entered: *std.atomic.Value(u32),
    exited: *std.atomic.Value(u32),
    max_concurrent: *std.atomic.Value(u32),
    start_gate: *std.atomic.Value(u32),
    ready: *std.atomic.Value(u32),
};

fn holdLockAndRecord(ctx: *OverlapCtx) void {
    _ = ctx.ready.fetchAdd(1, .acq_rel);
    while (ctx.start_gate.load(.acquire) == 0) std.atomic.spinLoopHint();

    const acquired = seam.acquireHandlerLock(ctx.program, true, ctx.query_graph);
    defer seam.releaseHandlerLock(acquired);

    // Update the running "how many threads are inside the critical
    // section right now" counter.  With a shared read lock this can
    // reach 2; with an exclusive write lock it must stay at 1.
    const inside = ctx.entered.fetchAdd(1, .acq_rel) + 1;
    var prev = ctx.max_concurrent.load(.monotonic);
    while (prev < inside) {
        if (ctx.max_concurrent.cmpxchgWeak(prev, inside, .acq_rel, .monotonic)) |actual| {
            prev = actual;
        } else {
            break;
        }
    }

    // Hold the lock long enough for the other thread to try to enter.
    const start = monoNanos();
    while (true) {
        const now = monoNanos();
        if (now - start >= ctx.hold_ns) break;
        std.atomic.spinLoopHint();
    }

    _ = ctx.entered.fetchSub(1, .acq_rel);
    _ = ctx.exited.fetchAdd(1, .acq_rel);
}

test "two concurrent read-only MATCH queries overlap inside the handler lock" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    const query_graph = "test_match_read_serial_overlap";
    store.createGraph(query_graph) catch |err| switch (err) {
        error.GraphAlreadyExists => {},
        else => return err,
    };

    var parse_result = try geode.parse(
        allocator,
        "MATCH (n:Person {id: 1}) RETURN n",
        .{},
    );
    defer parse_result.deinit();

    var entered = std.atomic.Value(u32).init(0);
    var exited = std.atomic.Value(u32).init(0);
    var max_concurrent = std.atomic.Value(u32).init(0);
    var start_gate = std.atomic.Value(u32).init(0);
    var ready = std.atomic.Value(u32).init(0);

    var ctx = OverlapCtx{
        .query_graph = query_graph,
        .program = &parse_result.program,
        .hold_ns = 50 * std.time.ns_per_ms,
        .entered = &entered,
        .exited = &exited,
        .max_concurrent = &max_concurrent,
        .start_gate = &start_gate,
        .ready = &ready,
    };

    var t1 = try std.Thread.spawn(.{}, holdLockAndRecord, .{&ctx});
    var t2 = try std.Thread.spawn(.{}, holdLockAndRecord, .{&ctx});

    while (ready.load(.acquire) < 2) std.atomic.spinLoopHint();
    start_gate.store(1, .release);

    t1.join();
    t2.join();

    const peak = max_concurrent.load(.monotonic);
    if (peak < 2) {
        std.debug.print(
            "max concurrent threads inside handler lock = {d} (expected 2 for " ++
                "a read-only MATCH).  Handler is holding an exclusive writer " ++
                "lock — see src/server/quic_connection_handler.zig:2302-2325.\n",
            .{peak},
        );
        return error.ReadsDidNotOverlap;
    }
}
