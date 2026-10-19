const std = @import("std");
const builtin = @import("builtin");

// Zig 0.16 compat helpers for test code.
// Cross-platform: Linux uses the vDSO-accelerated std.os.linux.*; other
// platforms (macOS / BSD) go through libc via std.c.*. Matches the pattern
// used by src/admin/fle_commands.zig and src/types/evaluator_functions.zig.
fn compat_clock_gettime_realtime(ts: *std.posix.timespec) void {
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, ts);
    }
}
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    compat_clock_gettime_realtime(&ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    compat_clock_gettime_realtime(&ts);
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
fn compat_nanoTimestamp() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    compat_clock_gettime_realtime(&ts);
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}
fn compat_sleep(ns: u64) void {
    var req: std.posix.timespec = .{ .sec = 0, .nsec = @intCast(ns) };
    var rem: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.nanosleep(@ptrCast(&req), @ptrCast(&rem));
    } else {
        _ = std.c.nanosleep(&req, &rem);
    }
}

const testing = std.testing;

// CANARY: REQ=REQ-PERF-TEST-001; FEATURE="PerformanceTests"; ASPECT=UnitTests; STATUS=IMPL; OWNER=test; UPDATED=2026-01-26
// GAP-0201: Comprehensive unit tests for performance optimizations

// Import the modules being tested
const thread_pool = @import("transport/thread_pool");
const QueryWorkItem = @import("transport/query_work_item").QueryWorkItem;
const stream_scheduler = @import("transport/stream_scheduler");
const perf_gate = @import("perf_gate");

// ============================================================================
// Thread Pool Tests
// ============================================================================

test "ThreadPool: initialization with auto-detect CPU count" {
    const pool = try thread_pool.ThreadPool.init(testing.allocator, .{
        .num_threads = 0, // Auto-detect
    });
    defer pool.deinit();

    const stats = pool.getStats();
    // Should have at least 2 workers
    try testing.expect(stats.num_workers >= 2);
}

test "ThreadPool: parallel work execution" {
    const pool = try thread_pool.ThreadPool.init(testing.allocator, .{
        .num_threads = 4,
    });
    defer pool.deinit();

    var counter = std.atomic.Value(u32).init(0);
    const num_tasks = 100;

    const Context = struct {
        counter: *std.atomic.Value(u32),
    };

    var ctx = Context{ .counter = &counter };

    const callback = struct {
        fn call(context: *anyopaque) void {
            const c: *Context = @ptrCast(@alignCast(context));
            _ = c.counter.fetchAdd(1, .release);
        }
    }.call;

    // Submit many work items
    for (0..num_tasks) |_| {
        try testing.expect(pool.submit(.{
            .context = @ptrCast(&ctx),
            .callback = callback,
        }));
    }

    // Wait for completion with timeout
    var timeout: u32 = 0;
    while (counter.load(.acquire) < num_tasks and timeout < 5000) {
        compat_sleep(1 * std.time.ns_per_ms);
        timeout += 1;
    }

    try testing.expectEqual(@as(u32, num_tasks), counter.load(.acquire));

    // Verify statistics. A worker counts a task as completed only AFTER its
    // callback returns, so the callbacks' own counter can reach num_tasks
    // while the last completions are still being recorded: wait (bounded)
    // for the pool's accounting instead of reading it immediately
    // (SONNY-2394: expected 100, found 98 in a loaded aggregate shard).
    var stats = pool.getStats();
    while (stats.total_completed < num_tasks and timeout < 5000) {
        compat_sleep(1 * std.time.ns_per_ms);
        timeout += 1;
        stats = pool.getStats();
    }
    try testing.expectEqual(@as(u64, num_tasks), stats.total_submitted);
    try testing.expectEqual(@as(u64, num_tasks), stats.total_completed);
}

test "ThreadPool: shutdown while tasks pending" {
    const pool = try thread_pool.ThreadPool.init(testing.allocator, .{
        .num_threads = 2,
    });

    var counter = std.atomic.Value(u32).init(0);

    const Context = struct {
        counter: *std.atomic.Value(u32),
    };

    var ctx = Context{ .counter = &counter };

    const callback = struct {
        fn call(context: *anyopaque) void {
            const c: *Context = @ptrCast(@alignCast(context));
            // Simulate slow work
            compat_sleep(10 * std.time.ns_per_ms);
            _ = c.counter.fetchAdd(1, .release);
        }
    }.call;

    // Submit tasks
    for (0..5) |_| {
        _ = pool.submit(.{
            .context = @ptrCast(&ctx),
            .callback = callback,
        });
    }

    // Immediate shutdown - should complete gracefully
    pool.deinit();

    // Counter may or may not have completed all tasks - that's OK
    // The important thing is no crash/hang
}

test "ThreadPool: rejection when queue is full" {
    const pool = try thread_pool.ThreadPool.init(testing.allocator, .{
        .num_threads = 1,
    });
    defer pool.deinit();

    var counter = std.atomic.Value(u32).init(0);

    const Context = struct {
        counter: *std.atomic.Value(u32),
    };

    var ctx = Context{ .counter = &counter };

    const callback = struct {
        fn call(context: *anyopaque) void {
            const c: *Context = @ptrCast(@alignCast(context));
            // Very slow task to fill queue
            compat_sleep(100 * std.time.ns_per_ms);
            _ = c.counter.fetchAdd(1, .release);
        }
    }.call;

    // Try to submit more tasks than queue can hold
    var submitted: u32 = 0;
    var rejected: u32 = 0;
    for (0..10000) |_| {
        if (pool.submit(.{
            .context = @ptrCast(&ctx),
            .callback = callback,
        })) {
            submitted += 1;
        } else {
            rejected += 1;
        }
    }

    // At least some should have been submitted
    try testing.expect(submitted > 0);
    // This test may or may not hit queue full depending on timing
}

test "ThreadPool: completion callback" {
    const pool = try thread_pool.ThreadPool.init(testing.allocator, .{
        .num_threads = 2,
    });
    defer pool.deinit();

    var work_done = std.atomic.Value(bool).init(false);
    var completion_called = std.atomic.Value(bool).init(false);

    const Context = struct {
        work_done: *std.atomic.Value(bool),
        completion_called: *std.atomic.Value(bool),
    };

    var ctx = Context{
        .work_done = &work_done,
        .completion_called = &completion_called,
    };

    const work_callback = struct {
        fn call(context: *anyopaque) void {
            const c: *Context = @ptrCast(@alignCast(context));
            c.work_done.store(true, .release);
        }
    }.call;

    const completion_callback = struct {
        fn call(context: *anyopaque) void {
            const c: *Context = @ptrCast(@alignCast(context));
            c.completion_called.store(true, .release);
        }
    }.call;

    try testing.expect(pool.submit(.{
        .context = @ptrCast(&ctx),
        .callback = work_callback,
        .completion = completion_callback,
    }));

    // Wait for completion
    var timeout: u32 = 0;
    while (!completion_called.load(.acquire) and timeout < 1000) {
        compat_sleep(1 * std.time.ns_per_ms);
        timeout += 1;
    }

    try testing.expect(work_done.load(.acquire));
    try testing.expect(completion_called.load(.acquire));
}

// ============================================================================
// Bounded Queue Tests
// ============================================================================

test "BoundedQueue: concurrent push/pop" {
    const Queue = thread_pool.BoundedQueue(u32, 256);
    var queue = Queue.init();
    const pool = try thread_pool.ThreadPool.init(testing.allocator, .{
        .num_threads = 2,
        .queue_capacity = 2,
    });
    defer pool.deinit();

    var produced = std.atomic.Value(u32).init(0);
    var consumed = std.atomic.Value(u32).init(0);
    const num_items = 10000;

    const ProducerContext = struct {
        q: *Queue,
        produced: *std.atomic.Value(u32),
    };
    const ConsumerContext = struct {
        q: *Queue,
        consumed: *std.atomic.Value(u32),
    };

    var producer_ctx = ProducerContext{
        .q = &queue,
        .produced = &produced,
    };
    var consumer_ctx = ConsumerContext{
        .q = &queue,
        .consumed = &consumed,
    };

    const producer = try pool.submitTask(struct {
        fn run(ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
            _ = runtime;
            const context: *ProducerContext = @ptrCast(@alignCast(ctx));
            for (0..num_items) |_| {
                while (!context.q.tryPush(1)) {
                    compat_sleep(1 * std.time.ns_per_us);
                }
                _ = context.produced.fetchAdd(1, .release);
            }
        }
    }.run, @ptrCast(&producer_ctx), .{
        // GAP-0514 Phase 6: was `.lane = .blocking` — the pool reserves a
        // single blocking-lane worker, so producer+consumer on that lane
        // deadlocked (producer spins on a full queue; consumer never runs).
        // Same lane-misrouting class as the bench_quic_stream_registry fix.
        .lane = .default,
        .backpressure = .block,
        .waitable = true,
    });

    const consumer = try pool.submitTask(struct {
        fn run(ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
            _ = runtime;
            const context: *ConsumerContext = @ptrCast(@alignCast(ctx));
            while (context.consumed.load(.acquire) < num_items) {
                if (context.q.tryPop()) |_| {
                    _ = context.consumed.fetchAdd(1, .release);
                } else {
                    compat_sleep(1 * std.time.ns_per_us);
                }
            }
        }
    }.run, @ptrCast(&consumer_ctx), .{
        .lane = .default, // see producer note above
        .backpressure = .block,
        .waitable = true,
    });

    try pool.wait(producer);
    try pool.wait(consumer);

    try testing.expectEqual(@as(u32, num_items), produced.load(.acquire));
    try testing.expectEqual(@as(u32, num_items), consumed.load(.acquire));
}

// ============================================================================
// Stream Scheduler Tests
// ============================================================================

test "StreamScheduler: fair round-robin scheduling" {
    var scheduler = stream_scheduler.StreamScheduler.init(testing.allocator);
    defer scheduler.deinit();

    // Add streams with equal quantum
    try scheduler.addStream(1, 1000);
    try scheduler.addStream(2, 1000);
    try scheduler.addStream(3, 1000);

    // Simulate multiple rounds of scheduling
    var stream1_count: u32 = 0;
    var stream2_count: u32 = 0;
    var stream3_count: u32 = 0;

    for (0..30) |_| {
        var order: [3]u64 = undefined;
        const count = scheduler.getScheduledStreams(&order);
        try testing.expectEqual(@as(usize, 3), count);

        // Count how many times each stream appears first
        if (order[0] == 1) stream1_count += 1;
        if (order[0] == 2) stream2_count += 1;
        if (order[0] == 3) stream3_count += 1;

        // Simulate reading from the first stream
        scheduler.recordBytesRead(order[0], 500);
    }

    // With fair scheduling, each stream should be first roughly 1/3 of the time
    // Allow some variance (each should be selected at least 5 times)
    try testing.expect(stream1_count >= 5);
    try testing.expect(stream2_count >= 5);
    try testing.expect(stream3_count >= 5);
}

test "StreamScheduler: priority based on quantum" {
    var scheduler = stream_scheduler.StreamScheduler.init(testing.allocator);
    defer scheduler.deinit();

    // Stream 1 has 2x quantum (higher priority)
    try scheduler.addStream(1, 2000);
    try scheduler.addStream(2, 1000);

    var order: [2]u64 = undefined;
    const count = scheduler.getScheduledStreams(&order);
    try testing.expectEqual(@as(usize, 2), count);

    // Stream 1 should be first (higher quantum)
    try testing.expectEqual(@as(u64, 1), order[0]);
}

test "StreamScheduler: blocked streams excluded" {
    var scheduler = stream_scheduler.StreamScheduler.init(testing.allocator);
    defer scheduler.deinit();

    try scheduler.addStream(1, 1000);
    try scheduler.addStream(2, 1000);
    try scheduler.addStream(3, 1000);

    // Block stream 2
    scheduler.markBlocked(2);

    var order: [3]u64 = undefined;
    const count = scheduler.getScheduledStreams(&order);

    // Only 2 streams should be scheduled
    try testing.expectEqual(@as(usize, 2), count);

    // Stream 2 should not be in the output
    for (order[0..count]) |id| {
        try testing.expect(id != 2);
    }
}

test "StreamScheduler: statistics accuracy" {
    var scheduler = stream_scheduler.StreamScheduler.init(testing.allocator);
    defer scheduler.deinit();

    try scheduler.addStream(1, 1000);
    try scheduler.addStream(2, 1000);

    // Record some bytes
    scheduler.recordBytesRead(1, 100);
    scheduler.recordBytesRead(1, 200);
    scheduler.recordBytesRead(2, 150);
    scheduler.recordBytesRead(2, 350);

    const stats = scheduler.getStats();
    try testing.expectEqual(@as(usize, 2), stats.total_streams);
    try testing.expectEqual(@as(u64, 800), stats.total_bytes_read); // 100+200+150+350
    try testing.expectEqual(@as(u64, 4), stats.total_polls);
}

test "StreamScheduler: dynamic stream add/remove" {
    var scheduler = stream_scheduler.StreamScheduler.init(testing.allocator);
    defer scheduler.deinit();

    // Add streams
    try scheduler.addStream(1, 1000);
    try scheduler.addStream(2, 1000);
    try testing.expectEqual(@as(usize, 2), scheduler.getStats().total_streams);

    // Remove stream
    scheduler.removeStream(1);
    try testing.expectEqual(@as(usize, 1), scheduler.getStats().total_streams);
    try testing.expect(!scheduler.hasStream(1));
    try testing.expect(scheduler.hasStream(2));

    // Add new stream
    try scheduler.addStream(3, 1000);
    try testing.expectEqual(@as(usize, 2), scheduler.getStats().total_streams);
}

// ============================================================================
// Query Work Item Tests
// ============================================================================

test "QueryWorkItem: lifecycle management" {
    const item = try QueryWorkItem.init(testing.allocator, "RETURN 1 + 2", 42);
    defer item.deinit();

    try testing.expectEqualStrings("RETURN 1 + 2", item.query);
    try testing.expectEqual(@as(u64, 42), item.stream_id);
    try testing.expect(!item.isCompleted());
    try testing.expect(item.err == null);
    try testing.expect(item.result == null);
}

test "QueryWorkItem: result storage" {
    const item = try QueryWorkItem.init(testing.allocator, "MATCH (n) RETURN n", 1);
    defer item.deinit();

    try item.setResult("{\"rows\": [{\"n\": {\"id\": 1}}]}");
    item.markCompleted();

    try testing.expect(item.isCompleted());
    try testing.expectEqualStrings("{\"rows\": [{\"n\": {\"id\": 1}}]}", item.result.?);
}

test "QueryWorkItem: error handling" {
    const item = try QueryWorkItem.init(testing.allocator, "INVALID SYNTAX", 1);
    defer item.deinit();

    item.setError(error.SyntaxError);
    item.markCompleted();

    try testing.expect(item.isCompleted());
    try testing.expectEqual(error.SyntaxError, item.err.?);
}

// ============================================================================
// Adaptive Backoff Simulation Tests
// ============================================================================

test "AdaptiveBackoff: behavior simulation" {
    // Simulate the adaptive backoff logic from main.zig
    const max_idle_before_sleep: u32 = 10;
    const min_sleep_us: u64 = 10;
    const max_sleep_us: u64 = 100;

    var idle_iterations: u32 = 0;

    // Simulate idle iterations
    for (0..20) |_| {
        idle_iterations += 1;

        if (idle_iterations > max_idle_before_sleep) {
            const backoff_multiplier = @min(idle_iterations - max_idle_before_sleep, 4);
            const sleep_us = @min(min_sleep_us << @intCast(backoff_multiplier), max_sleep_us);

            // Verify sleep time is bounded
            try testing.expect(sleep_us >= min_sleep_us);
            try testing.expect(sleep_us <= max_sleep_us);
        }
    }

    // Simulate active iterations resetting counter
    idle_iterations = 0;
    try testing.expectEqual(@as(u32, 0), idle_iterations);
}

test "AdaptiveBackoff: exponential growth" {
    const min_sleep_us: u64 = 10;
    const max_sleep_us: u64 = 100;

    // Test exponential growth
    var prev_sleep: u64 = 0;
    for (1..10) |i| {
        const backoff = @min(i, 4);
        const sleep_us = @min(min_sleep_us << @intCast(backoff), max_sleep_us);

        // Should grow exponentially until capped
        if (sleep_us < max_sleep_us) {
            try testing.expect(sleep_us > prev_sleep);
        }
        prev_sleep = sleep_us;
    }

    // Final value should be capped at max
    try testing.expect(prev_sleep <= max_sleep_us);
}

// ============================================================================
// Write Stall Optimization Tests
// ============================================================================

test "WriteStall: backoff timing" {
    // Simulate the optimized write stall logic
    const initial_sleep_us: u64 = 10;
    const max_sleep_us: u64 = 100;

    // Before 5 stalls - no sleep
    for (1..6) |stalled| {
        _ = stalled;
        // In the real code, no sleep happens here
    }

    // After 5 stalls - exponential backoff
    for (6..15) |stalled| {
        const backoff = @min(stalled - 5, 4);
        const sleep_us = @min(initial_sleep_us << @intCast(backoff), max_sleep_us);

        try testing.expect(sleep_us >= initial_sleep_us);
        try testing.expect(sleep_us <= max_sleep_us);
    }
}

// ============================================================================
// Performance Regression Tests
// ============================================================================

test "Performance: thread pool throughput baseline" {
    const pool = try thread_pool.ThreadPool.init(testing.allocator, .{
        .num_threads = 4,
    });
    defer pool.deinit();

    var counter = std.atomic.Value(u64).init(0);
    const num_tasks = 10000;

    const Context = struct {
        counter: *std.atomic.Value(u64),
    };

    var ctx = Context{ .counter = &counter };

    const callback = struct {
        fn call(context: *anyopaque) void {
            const c: *Context = @ptrCast(@alignCast(context));
            _ = c.counter.fetchAdd(1, .release);
        }
    }.call;

    const start = compat_nanoTimestamp();

    for (0..num_tasks) |_| {
        while (!pool.submit(.{
            .context = @ptrCast(&ctx),
            .callback = callback,
        })) {
            compat_sleep(1 * std.time.ns_per_us);
        }
    }

    // Wait for completion
    while (counter.load(.acquire) < num_tasks) {
        compat_sleep(1 * std.time.ns_per_us);
    }

    const end = compat_nanoTimestamp();
    const elapsed_ms = @divFloor(end - start, std.time.ns_per_ms);

    // Should complete 10000 tasks in reasonable time (< 5 seconds)
    try testing.expect(elapsed_ms < 5000);

    // Calculate throughput
    const throughput = @as(u64, num_tasks) * 1000 / @as(u64, @intCast(elapsed_ms));
    std.debug.print("\nThread pool throughput: {} tasks/sec\n", .{throughput});

    // Minimum throughput requirement: 1000 tasks/sec
    try testing.expect(throughput >= 1000);
}

test "Performance: scheduler overhead" {
    var scheduler = stream_scheduler.StreamScheduler.init(testing.allocator);
    defer scheduler.deinit();

    // Add many streams
    for (0..100) |i| {
        try scheduler.addStream(@intCast(i), 1000);
    }

    const start = compat_nanoTimestamp();
    const iterations = 10000;

    var order: [100]u64 = undefined;
    for (0..iterations) |_| {
        _ = scheduler.getScheduledStreams(&order);
    }

    const end = compat_nanoTimestamp();
    const elapsed_ns = end - start;
    const per_call_ns = @divFloor(elapsed_ns, iterations);

    std.debug.print("\nScheduler overhead: {} ns/call\n", .{per_call_ns});

    // Should be fast: < 10μs per call in optimized builds. Debug builds
    // (the default for `zig build test-*`) carry ~2-3x overhead, so allow
    // 50μs there — still catches the O(n²)-regression class this test
    // exists for.
    //
    // This is a wall-clock latency claim on a 10k-iteration microbenchmark,
    // so it goes through the shared perf gate (tests/perf_gate.zig,
    // SONNY-2394/2439): reported by default, enforced by the scheduled
    // `test-perf-gates-enforced` job (ReleaseFast, GEODE_PERF_GATES=enforce).
    // On the shared CI pools it measured a loaded host, not the scheduler:
    // the same code took 3.9μs (ReleaseSafe) and 13.6μs (Debug) on an idle
    // dev box but 10.3-13.4μs (ReleaseSafe, AWS-spot release-safe shard 0)
    // and 62-179μs (Debug, k8s unit shard 0) in CI, so it failed main's
    // pipelines with no change to the scheduler.
    const threshold_ns: i128 = if (@import("builtin").mode == .Debug) 50000 else 10000;
    try perf_gate.check(
        "scheduler overhead per getScheduledStreams call (100 streams)",
        per_call_ns < threshold_ns,
        "per_call_ns={d} (max {d})",
        .{ per_call_ns, threshold_ns },
    );
}
