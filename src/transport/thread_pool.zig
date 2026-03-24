const std = @import("std");
const concurrency = @import("concurrency_lib");

// CANARY: REQ=REQ-PERF-THREAD-POOL-001; FEATURE="ThreadPool"; ASPECT=QueryExecution; STATUS=TESTED; TEST=test_performance_optimizations.zig; OWNER=transport; UPDATED=2026-01-30
// GAP-0201: High-performance thread pool for parallel query execution
// Designed to decouple network I/O from query processing for 10-50x throughput improvement
//
// This module is a thin compatibility wrapper around the external concurrency
// library. It re-exports the core types under their original names so that
// consumers do not need to change.

/// Work item representing a task to be executed by the thread pool.
pub const WorkItem = concurrency.WorkItem;

/// Lock-free bounded multi-producer multi-consumer queue (Vyukov algorithm).
pub const BoundedQueue = concurrency.BoundedQueue;

/// Thread pool configuration.
///
/// The external library's `ThreadPoolConfig` only exposes `num_threads` and
/// `stack_size`.  The former geode-local fields `queue_capacity` and
/// `name_prefix` are accepted here for source compatibility but are no longer
/// used (the external pool hard-codes a 4096-slot queue).
pub const ThreadPoolConfig = struct {
    /// Number of worker threads (0 = auto-detect based on CPU count).
    num_threads: usize = 0,
    /// Work queue capacity per thread (ignored — retained for source compat).
    queue_capacity: usize = 1024,
    /// Thread stack size (0 = default).
    stack_size: usize = 0,
    /// Name prefix for worker threads (ignored — retained for source compat).
    name_prefix: []const u8 = "geode-worker",

    /// Convert to the external library's config type.
    fn toExternal(self: ThreadPoolConfig) concurrency.ThreadPoolConfig {
        return .{
            .num_threads = self.num_threads,
            .stack_size = self.stack_size,
        };
    }
};

/// Thread pool statistics.
pub const Stats = concurrency.Stats;

/// High-performance thread pool for query execution.
/// CANARY: REQ=REQ-PERF-THREAD-POOL-002; FEATURE="ThreadPool"; ASPECT=WorkerManagement; STATUS=TESTED; TEST=test_performance_optimizations.zig; OWNER=transport; UPDATED=2026-01-30
///
/// Wraps `concurrency.ThreadPool` and preserves the original public API.
pub const ThreadPool = struct {
    const Self = @This();

    inner: *concurrency.ThreadPool,

    /// Exposed so callers can read `pool.workers.len` for observability.
    workers: []std.Thread,

    /// Initialize the thread pool.
    pub fn init(allocator: std.mem.Allocator, config: ThreadPoolConfig) !*Self {
        const inner = try concurrency.ThreadPool.init(allocator, config.toExternal());
        errdefer inner.deinit();

        const self = try allocator.create(Self);
        self.* = .{ .inner = inner, .workers = inner.workers };
        return self;
    }

    /// Shutdown the thread pool and wait for all workers to finish.
    pub fn deinit(self: *Self) void {
        const inner = self.inner;
        // Recover the allocator before the inner pool frees itself.
        const allocator = inner.allocator;
        inner.deinit();
        allocator.destroy(self);
    }

    /// Submit a work item to the thread pool.
    /// Returns true if submitted, false if queue is full.
    pub fn submit(self: *Self, item: WorkItem) bool {
        return self.inner.submit(item);
    }

    /// Submit a work item, blocking if queue is full.
    /// Preserves the original signature (no timeout).
    pub fn submitBlocking(self: *Self, item: WorkItem) !void {
        self.inner.submitBlocking(item, null) catch |err| switch (err) {
            error.PoolShutdown => return error.PoolShutdown,
            error.Timeout => unreachable, // timeout_ns is null
        };
    }

    /// Get the number of pending tasks in the queue.
    pub fn pendingTasks(self: *Self) usize {
        return self.inner.pendingTasks();
    }

    /// Get the number of active workers currently processing tasks.
    pub fn activeWorkers(self: *Self) usize {
        return self.inner.activeWorkers();
    }

    /// Get statistics about the thread pool.
    pub fn getStats(self: *Self) Stats {
        return self.inner.getStats();
    }
};

/// Query work item for use with the thread pool.
/// CANARY: REQ=REQ-PERF-THREAD-POOL-003; FEATURE="ThreadPool"; ASPECT=QueryWorkItem; STATUS=TESTED; TEST=test_performance_optimizations.zig; OWNER=transport; UPDATED=2026-01-30
pub const QueryWorkItem = struct {
    allocator: std.mem.Allocator,
    query: []const u8,
    stream_id: u64,
    result: ?[]const u8 = null,
    err: ?anyerror = null,
    completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator, query: []const u8, stream_id: u64) !*QueryWorkItem {
        const self = try allocator.create(QueryWorkItem);
        self.* = QueryWorkItem{
            .allocator = allocator,
            .query = try allocator.dupe(u8, query),
            .stream_id = stream_id,
        };
        return self;
    }

    pub fn deinit(self: *QueryWorkItem) void {
        self.allocator.free(self.query);
        if (self.result) |result| {
            self.allocator.free(result);
        }
        self.allocator.destroy(self);
    }

    pub fn isCompleted(self: *QueryWorkItem) bool {
        return self.completed.load(.acquire);
    }

    pub fn markCompleted(self: *QueryWorkItem) void {
        self.completed.store(true, .release);
    }

    pub fn setResult(self: *QueryWorkItem, result: []const u8) !void {
        self.result = try self.allocator.dupe(u8, result);
    }

    pub fn setError(self: *QueryWorkItem, err: anyerror) void {
        self.err = err;
    }
};

// ============================================================================
// Unit tests
// ============================================================================

test "BoundedQueue: basic operations" {
    var queue = BoundedQueue(u32, 8).init();

    // Test push and pop
    try std.testing.expect(queue.tryPush(1));
    try std.testing.expect(queue.tryPush(2));
    try std.testing.expect(queue.tryPush(3));

    try std.testing.expectEqual(@as(usize, 3), queue.len());

    try std.testing.expectEqual(@as(?u32, 1), queue.tryPop());
    try std.testing.expectEqual(@as(?u32, 2), queue.tryPop());
    try std.testing.expectEqual(@as(?u32, 3), queue.tryPop());
    try std.testing.expectEqual(@as(?u32, null), queue.tryPop());
}

test "BoundedQueue: full queue" {
    var queue = BoundedQueue(u32, 4).init();

    // Fill the queue
    try std.testing.expect(queue.tryPush(1));
    try std.testing.expect(queue.tryPush(2));
    try std.testing.expect(queue.tryPush(3));
    try std.testing.expect(queue.tryPush(4));

    // Queue should be full
    try std.testing.expect(queue.isFull());
    try std.testing.expect(!queue.tryPush(5));

    // Pop one and push should succeed
    _ = queue.tryPop();
    try std.testing.expect(queue.tryPush(5));
}

test "ThreadPool: basic initialization" {
    const pool = try ThreadPool.init(std.testing.allocator, .{
        .num_threads = 2,
    });
    defer pool.deinit();

    const stats = pool.getStats();
    try std.testing.expectEqual(@as(usize, 2), stats.num_workers);
    try std.testing.expectEqual(@as(usize, 0), stats.pending_tasks);
}

test "ThreadPool: submit and execute work" {
    const pool = try ThreadPool.init(std.testing.allocator, .{
        .num_threads = 2,
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
            _ = c.counter.fetchAdd(1, .release);
        }
    }.call;

    // Submit 10 work items
    for (0..10) |_| {
        try std.testing.expect(pool.submit(.{
            .context = @ptrCast(&ctx),
            .callback = callback,
        }));
    }

    // Wait for completion
    var timeout: u32 = 0;
    while (counter.load(.acquire) < 10 and timeout < 1000) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
        timeout += 1;
    }

    try std.testing.expectEqual(@as(u32, 10), counter.load(.acquire));
}

test "ThreadPool: statistics tracking" {
    const pool = try ThreadPool.init(std.testing.allocator, .{
        .num_threads = 2,
    });
    defer pool.deinit();

    var completed = std.atomic.Value(bool).init(false);

    const Context = struct {
        completed: *std.atomic.Value(bool),
    };

    var ctx = Context{ .completed = &completed };

    const callback = struct {
        fn call(context: *anyopaque) void {
            const c: *Context = @ptrCast(@alignCast(context));
            c.completed.store(true, .release);
        }
    }.call;

    try std.testing.expect(pool.submit(.{
        .context = @ptrCast(&ctx),
        .callback = callback,
    }));

    // Wait for completion
    var timeout: u32 = 0;
    while (!completed.load(.acquire) and timeout < 1000) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
        timeout += 1;
    }

    const stats = pool.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.total_submitted);
    try std.testing.expectEqual(@as(u64, 1), stats.total_completed);
}

test "QueryWorkItem: lifecycle" {
    const item = try QueryWorkItem.init(std.testing.allocator, "RETURN 1", 42);
    defer item.deinit();

    try std.testing.expectEqualStrings("RETURN 1", item.query);
    try std.testing.expectEqual(@as(u64, 42), item.stream_id);
    try std.testing.expect(!item.isCompleted());

    try item.setResult("success");
    item.markCompleted();

    try std.testing.expect(item.isCompleted());
    try std.testing.expectEqualStrings("success", item.result.?);
}
