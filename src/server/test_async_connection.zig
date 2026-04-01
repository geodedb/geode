const std = @import("std");
const thread_pool = @import("concurrency_lib");

// CANARY: REQ=REQ-PERF-ASYNC-CONN-TEST-001; FEATURE="AsyncConnectionHandling"; ASPECT=UnitTests; STATUS=TESTED; OWNER=server; UPDATED=2026-01-27
// GAP-0202: Unit tests for async connection handling infrastructure

// Test the ConnectionContext struct layout and initialization
// Note: We can't directly import ConnectionContext from main.zig due to compilation unit constraints
// Instead, we test the underlying mechanisms that support async connection handling

test "thread pool handles concurrent connections" {
    const pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .num_threads = 4, // Simulate multiple connection handlers
    });
    defer pool.deinit();

    // Track completed "connections"
    var completed_count = std.atomic.Value(u32).init(0);
    const num_connections: u32 = 50;

    // Context for simulated connection handling
    const ConnContext = struct {
        completed: *std.atomic.Value(u32),
    };

    // Callback simulates connection handling
    const handler = struct {
        fn handle(context: *anyopaque) void {
            const ctx: *ConnContext = @ptrCast(@alignCast(context));
            // Simulate some work
            std.Thread.sleep(1 * std.time.ns_per_ms);
            _ = ctx.completed.fetchAdd(1, .release);
        }
    }.handle;

    // Submit multiple "connections" concurrently
    var contexts: [num_connections]ConnContext = undefined;
    for (&contexts) |*ctx| {
        ctx.* = ConnContext{ .completed = &completed_count };
        const submitted = pool.submit(.{
            .context = @ptrCast(ctx),
            .callback = handler,
        });
        try std.testing.expect(submitted);
    }

    // Wait for all to complete
    var timeout: u32 = 0;
    while (completed_count.load(.acquire) < num_connections and timeout < 5000) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
        timeout += 1;
    }

    try std.testing.expectEqual(num_connections, completed_count.load(.acquire));
}

test "thread pool graceful degradation under load" {
    const pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .num_threads = 2,
    });
    defer pool.deinit();

    var completed = std.atomic.Value(u32).init(0);
    var rejected: u32 = 0;

    const Context = struct {
        completed: *std.atomic.Value(u32),
    };

    var ctx = Context{ .completed = &completed };

    // Callback that takes some time
    const callback = struct {
        fn call(context: *anyopaque) void {
            const c: *Context = @ptrCast(@alignCast(context));
            std.Thread.sleep(10 * std.time.ns_per_ms);
            _ = c.completed.fetchAdd(1, .release);
        }
    }.call;

    // Try to submit many items - some may be rejected if queue fills
    const total_attempts: u32 = 100;
    var submitted: u32 = 0;
    for (0..total_attempts) |_| {
        if (pool.submit(.{
            .context = @ptrCast(&ctx),
            .callback = callback,
        })) {
            submitted += 1;
        } else {
            rejected += 1;
        }
    }

    // Wait for completion
    var timeout: u32 = 0;
    while (completed.load(.acquire) < submitted and timeout < 10000) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
        timeout += 1;
    }

    // Verify all submitted work was completed
    try std.testing.expectEqual(submitted, completed.load(.acquire));

    // If any were rejected, that's expected under extreme load
    if (rejected > 0) {
        // Queue full rejection is acceptable graceful degradation
        try std.testing.expect(submitted + rejected == total_attempts);
    }
}

test "thread pool statistics accuracy" {
    const pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .num_threads = 4,
    });
    defer pool.deinit();

    var completed = std.atomic.Value(u32).init(0);

    const Context = struct {
        completed: *std.atomic.Value(u32),
    };

    var ctx = Context{ .completed = &completed };

    const callback = struct {
        fn call(context: *anyopaque) void {
            const c: *Context = @ptrCast(@alignCast(context));
            _ = c.completed.fetchAdd(1, .release);
        }
    }.call;

    const num_tasks: u32 = 25;
    for (0..num_tasks) |_| {
        try std.testing.expect(pool.submit(.{
            .context = @ptrCast(&ctx),
            .callback = callback,
        }));
    }

    // Wait for completion
    var timeout: u32 = 0;
    while (completed.load(.acquire) < num_tasks and timeout < 2000) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
        timeout += 1;
    }

    const stats = pool.getStats();
    try std.testing.expectEqual(@as(u64, num_tasks), stats.total_submitted);
    try std.testing.expectEqual(@as(u64, num_tasks), stats.total_completed);
}

test "thread pool worker count configuration" {
    // Test auto-detection
    const pool_auto = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .num_threads = 0, // Auto-detect
    });
    defer pool_auto.deinit();
    try std.testing.expect(pool_auto.workers.len >= 2);

    // Test explicit configuration
    const pool_explicit = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .num_threads = 8,
    });
    defer pool_explicit.deinit();
    try std.testing.expectEqual(@as(usize, 8), pool_explicit.workers.len);
}

test "bounded queue capacity limits" {
    // Test the queue doesn't overflow
    const Queue = thread_pool.BoundedQueue(u32, 16);
    var queue = Queue.init();

    // Fill to capacity
    for (0..16) |i| {
        try std.testing.expect(queue.tryPush(@intCast(i)));
    }

    // Should be full
    try std.testing.expect(queue.isFull());
    try std.testing.expect(!queue.tryPush(999));

    // Drain queue
    for (0..16) |i| {
        const val = queue.tryPop();
        try std.testing.expect(val != null);
        try std.testing.expectEqual(@as(u32, @intCast(i)), val.?);
    }

    // Should be empty
    try std.testing.expect(queue.isEmpty());
    try std.testing.expect(queue.tryPop() == null);
}
