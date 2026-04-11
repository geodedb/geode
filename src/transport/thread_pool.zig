const std = @import("std");

// CANARY: REQ=REQ-PERF-THREAD-POOL-001; FEATURE="ThreadPool"; ASPECT=QueryExecution; STATUS=TESTED; TEST=test_performance_optimizations.zig; OWNER=transport; UPDATED=2026-04-01
// GAP-0201: High-performance thread pool for parallel query execution
// GAP-0275: Consolidated on spice — removed external concurrency dependency.
//           This module now uses std.Thread primitives directly for the
//           fire-and-forget dispatch pattern that spice's fork/join API does
//           not naturally support.  spice remains the single external
//           concurrency library for map/reduce/forEach parallelism.

/// Work item representing a task to be executed by the thread pool.
pub const WorkItem = struct {
    context: *anyopaque,
    callback: *const fn (*anyopaque) void,
    /// Optional completion callback invoked after the main callback finishes.
    completion: ?*const fn (*anyopaque) void = null,
};

/// Lock-free bounded multi-producer multi-consumer queue (Vyukov algorithm).
///
/// Re-implemented inline to drop the external concurrency dependency (GAP-0275).
/// Uses atomic head/tail indices with per-slot sequence counters for lock-free
/// progress.  The capacity must be a power of two.
pub fn BoundedQueue(comptime T: type, comptime N: comptime_int) type {
    if (N == 0 or (N & (N - 1)) != 0) {
        @compileError("BoundedQueue capacity must be a power of two");
    }

    return struct {
        const Self = @This();
        const mask: usize = N - 1;

        const Slot = struct {
            data: T = undefined,
            sequence: std.atomic.Value(usize),
        };

        buffer: [N]Slot = init: {
            @setEvalBranchQuota(N * 4 + 100);
            var slots: [N]Slot = undefined;
            for (&slots, 0..) |*slot, i| {
                slot.* = .{
                    .data = undefined,
                    .sequence = std.atomic.Value(usize).init(i),
                };
            }
            break :init slots;
        },
        head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        pub fn init() Self {
            return .{};
        }

        /// Try to push an item.  Returns false if the queue is full.
        pub fn tryPush(self: *Self, value: T) bool {
            var pos = self.tail.load(.monotonic);
            while (true) {
                const slot = &self.buffer[pos & mask];
                const seq = slot.sequence.load(.acquire);
                const diff = @as(isize, @bitCast(seq -% pos));
                if (diff == 0) {
                    if (self.tail.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |new_pos| {
                        pos = new_pos;
                    } else {
                        slot.data = value;
                        slot.sequence.store(pos +% 1, .release);
                        return true;
                    }
                } else if (diff < 0) {
                    // Queue full
                    return false;
                } else {
                    pos = self.tail.load(.monotonic);
                }
            }
        }

        /// Try to pop an item.  Returns null if the queue is empty.
        pub fn tryPop(self: *Self) ?T {
            var pos = self.head.load(.monotonic);
            while (true) {
                const slot = &self.buffer[pos & mask];
                const seq = slot.sequence.load(.acquire);
                const diff = @as(isize, @bitCast(seq -% (pos +% 1)));
                if (diff == 0) {
                    if (self.head.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |new_pos| {
                        pos = new_pos;
                    } else {
                        const value = slot.data;
                        slot.sequence.store(pos +% N, .release);
                        return value;
                    }
                } else if (diff < 0) {
                    // Queue empty
                    return null;
                } else {
                    pos = self.head.load(.monotonic);
                }
            }
        }

        /// Approximate number of items in the queue.
        pub fn len(self: *Self) usize {
            const t = self.tail.load(.monotonic);
            const h = self.head.load(.monotonic);
            return t -% h;
        }

        /// Returns true if the queue appears full.
        pub fn isFull(self: *Self) bool {
            return self.len() >= N;
        }

        /// Returns true if the queue appears empty.
        pub fn isEmpty(self: *Self) bool {
            return self.len() == 0;
        }
    };
}

/// Thread pool configuration.
pub const ThreadPoolConfig = struct {
    /// Number of worker threads (0 = auto-detect based on CPU count).
    num_threads: usize = 0,
    /// Work queue capacity per thread (ignored — retained for source compat).
    queue_capacity: usize = 1024,
    /// Thread stack size (0 = default).
    stack_size: usize = 0,
    /// Name prefix for worker threads (ignored — retained for source compat).
    name_prefix: []const u8 = "geode-worker",
};

/// Thread pool statistics.
pub const Stats = struct {
    num_workers: usize,
    pending_tasks: usize,
    total_submitted: u64,
    total_completed: u64,
};

/// High-performance thread pool for query execution.
/// CANARY: REQ=REQ-PERF-THREAD-POOL-002; FEATURE="ThreadPool"; ASPECT=WorkerManagement; STATUS=TESTED; TEST=test_performance_optimizations.zig; OWNER=transport; UPDATED=2026-04-01
///
/// Self-contained implementation using std.Thread primitives.
/// The external concurrency library has been removed (GAP-0275).
pub const ThreadPool = struct {
    const Self = @This();

    /// Fixed-size work queue (4096 slots, power of two).
    const QueueSize = 4096;
    const Queue = BoundedQueue(WorkItem, QueueSize);

    allocator: std.mem.Allocator,
    queue: *Queue,
    worker_threads: []std.Thread,
    shutdown: std.atomic.Value(bool),
    pending: std.atomic.Value(usize),
    total_submitted: std.atomic.Value(u64),
    total_completed: std.atomic.Value(u64),
    active: std.atomic.Value(usize),

    // Condition variable to wake sleeping workers when new work arrives.
    cond_mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,

    /// Exposed so callers can read `pool.workers.len` for observability.
    workers: []std.Thread,

    /// Initialize the thread pool.
    pub fn init(allocator: std.mem.Allocator, config: ThreadPoolConfig) !*Self {
        const num = if (config.num_threads == 0) blk: {
            const cpus = std.Thread.getCpuCount() catch 4;
            // Cap auto-detected worker count.  Each worker warms thread-local
            // state on first use (~10MB), so scaling linearly with CPU count
            // causes RSS to balloon on large-core-count machines and pushes
            // the server past process memory limits under sustained load.
            // 16 workers is plenty for a query-routing front-end; CPU-bound
            // work is dispatched to the separate parallel execution pool.
            // Callers needing more can set num_threads explicitly.
            const auto_max: usize = 16;
            break :blk @max(@min(cpus, auto_max), 2);
        } else config.num_threads;

        const queue = try allocator.create(Queue);
        queue.* = Queue.init();

        const threads = try allocator.alloc(std.Thread, num);

        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .queue = queue,
            .worker_threads = threads,
            .shutdown = std.atomic.Value(bool).init(false),
            .pending = std.atomic.Value(usize).init(0),
            .total_submitted = std.atomic.Value(u64).init(0),
            .total_completed = std.atomic.Value(u64).init(0),
            .active = std.atomic.Value(usize).init(0),
            .cond_mutex = .{},
            .cond = .{},
            .workers = threads,
        };

        // Spawn worker threads.
        for (threads, 0..) |*t, i| {
            _ = i;
            const spawn_config: std.Thread.SpawnConfig = if (config.stack_size > 0) .{ .stack_size = config.stack_size } else .{};
            t.* = try std.Thread.spawn(spawn_config, workerLoop, .{self});
        }

        return self;
    }

    /// Shutdown the thread pool and wait for all workers to finish.
    pub fn deinit(self: *Self) void {
        self.shutdown.store(true, .release);

        // Wake all sleeping workers.
        self.cond_mutex.lock();
        self.cond.broadcast();
        self.cond_mutex.unlock();

        for (self.worker_threads) |t| {
            t.join();
        }

        const allocator = self.allocator;
        allocator.free(self.worker_threads);
        allocator.destroy(self.queue);
        allocator.destroy(self);
    }

    /// Submit a work item to the thread pool.
    /// Returns true if submitted, false if queue is full.
    pub fn submit(self: *Self, item: WorkItem) bool {
        if (!self.queue.tryPush(item)) {
            return false;
        }
        _ = self.pending.fetchAdd(1, .release);
        _ = self.total_submitted.fetchAdd(1, .release);

        // Signal one worker.
        self.cond_mutex.lock();
        self.cond.signal();
        self.cond_mutex.unlock();

        return true;
    }

    /// Submit a work item, blocking if queue is full.
    pub fn submitBlocking(self: *Self, item: WorkItem) !void {
        while (true) {
            if (self.shutdown.load(.acquire)) return error.PoolShutdown;
            if (self.submit(item)) return;
            // Brief back-off before retry.
            std.Thread.sleep(100 * std.time.ns_per_us);
        }
    }

    /// Get the number of pending tasks in the queue.
    pub fn pendingTasks(self: *Self) usize {
        return self.pending.load(.acquire);
    }

    /// Get the number of active workers currently processing tasks.
    pub fn activeWorkers(self: *Self) usize {
        return self.active.load(.acquire);
    }

    /// Get statistics about the thread pool.
    pub fn getStats(self: *Self) Stats {
        return .{
            .num_workers = self.worker_threads.len,
            .pending_tasks = self.pending.load(.acquire),
            .total_submitted = self.total_submitted.load(.acquire),
            .total_completed = self.total_completed.load(.acquire),
        };
    }

    fn workerLoop(self: *Self) void {
        while (true) {
            if (self.queue.tryPop()) |item| {
                _ = self.active.fetchAdd(1, .release);
                item.callback(item.context);
                if (item.completion) |completion| {
                    completion(item.context);
                }
                _ = self.active.fetchSub(1, .release);
                _ = self.pending.fetchSub(1, .release);
                _ = self.total_completed.fetchAdd(1, .release);
                continue;
            }

            if (self.shutdown.load(.acquire)) break;

            // No work available — wait on condition variable.
            self.cond_mutex.lock();
            // Double-check after acquiring mutex.
            if (!self.queue.isEmpty()) {
                self.cond_mutex.unlock();
                continue;
            }
            if (self.shutdown.load(.acquire)) {
                self.cond_mutex.unlock();
                break;
            }
            self.cond.wait(&self.cond_mutex);
            self.cond_mutex.unlock();
        }
    }
};

/// Query work item for use with the thread pool.
/// CANARY: REQ=REQ-PERF-THREAD-POOL-003; FEATURE="ThreadPool"; ASPECT=QueryWorkItem; STATUS=TESTED; TEST=test_performance_optimizations.zig; OWNER=transport; UPDATED=2026-04-01
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
