const std = @import("std");

// CANARY: REQ=REQ-PERF-THREAD-POOL-001; FEATURE="ThreadPool"; ASPECT=QueryExecution; STATUS=IMPL; OWNER=transport; UPDATED=2026-01-26
// GAP-0201: High-performance thread pool for parallel query execution
// Designed to decouple network I/O from query processing for 10-50x throughput improvement

/// Work item representing a task to be executed by the thread pool
pub const WorkItem = struct {
    /// User data pointer for the task context
    context: *anyopaque,
    /// Callback function to execute the work
    callback: *const fn (context: *anyopaque) void,
    /// Optional completion callback (called after work is done)
    completion: ?*const fn (context: *anyopaque) void = null,
};

/// Lock-free bounded multi-producer multi-consumer queue
/// Uses atomic operations for high-performance concurrent access
pub fn BoundedQueue(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        items: [capacity]?T = [_]?T{null} ** capacity,
        head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        size: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        pub fn init() Self {
            return Self{};
        }

        /// Try to push an item to the queue (non-blocking)
        /// Returns true if successful, false if queue is full
        pub fn tryPush(self: *Self, item: T) bool {
            const current_size = self.size.load(.acquire);
            if (current_size >= capacity) {
                return false;
            }

            // Try to claim a slot
            const tail = self.tail.fetchAdd(1, .acq_rel) % capacity;
            self.items[tail] = item;

            // Increment size after item is placed
            _ = self.size.fetchAdd(1, .release);
            return true;
        }

        /// Try to pop an item from the queue (non-blocking)
        /// Returns the item if available, null if queue is empty
        pub fn tryPop(self: *Self) ?T {
            const current_size = self.size.load(.acquire);
            if (current_size == 0) {
                return null;
            }

            // Try to claim an item
            const head = self.head.fetchAdd(1, .acq_rel) % capacity;
            const item = self.items[head];

            if (item != null) {
                self.items[head] = null;
                _ = self.size.fetchSub(1, .release);
            }

            return item;
        }

        /// Get current queue size (approximate, may change immediately)
        pub fn len(self: *Self) usize {
            return self.size.load(.acquire);
        }

        /// Check if queue is empty (approximate)
        pub fn isEmpty(self: *Self) bool {
            return self.len() == 0;
        }

        /// Check if queue is full (approximate)
        pub fn isFull(self: *Self) bool {
            return self.len() >= capacity;
        }
    };
}

/// Thread pool configuration
pub const ThreadPoolConfig = struct {
    /// Number of worker threads (0 = auto-detect based on CPU count)
    num_threads: usize = 0,
    /// Work queue capacity per thread
    queue_capacity: usize = 1024,
    /// Thread stack size (0 = default)
    stack_size: usize = 0,
    /// Name prefix for worker threads (for debugging)
    name_prefix: []const u8 = "geode-worker",
};

/// High-performance thread pool for query execution
/// CANARY: REQ=REQ-PERF-THREAD-POOL-002; FEATURE="ThreadPool"; ASPECT=WorkerManagement; STATUS=IMPL; OWNER=transport; UPDATED=2026-01-26
pub const ThreadPool = struct {
    const Self = @This();
    const QueueType = BoundedQueue(WorkItem, 4096);

    allocator: std.mem.Allocator,
    config: ThreadPoolConfig,
    workers: []std.Thread,
    work_queue: QueueType,
    shutdown: std.atomic.Value(bool),
    active_workers: std.atomic.Value(usize),
    total_tasks_submitted: std.atomic.Value(u64),
    total_tasks_completed: std.atomic.Value(u64),

    /// Initialize the thread pool
    pub fn init(allocator: std.mem.Allocator, config: ThreadPoolConfig) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Auto-detect thread count if not specified
        const num_threads = if (config.num_threads == 0)
            @max(std.Thread.getCpuCount() catch 4, 2)
        else
            config.num_threads;

        self.* = Self{
            .allocator = allocator,
            .config = config,
            .workers = try allocator.alloc(std.Thread, num_threads),
            .work_queue = QueueType.init(),
            .shutdown = std.atomic.Value(bool).init(false),
            .active_workers = std.atomic.Value(usize).init(0),
            .total_tasks_submitted = std.atomic.Value(u64).init(0),
            .total_tasks_completed = std.atomic.Value(u64).init(0),
        };

        // Start worker threads
        for (self.workers, 0..) |*worker, i| {
            var spawn_config = std.Thread.SpawnConfig{};
            if (config.stack_size > 0) {
                spawn_config.stack_size = config.stack_size;
            }
            worker.* = try std.Thread.spawn(spawn_config, workerMain, .{ self, i });
        }

        return self;
    }

    /// Shutdown the thread pool and wait for all workers to finish
    pub fn deinit(self: *Self) void {
        // Signal shutdown
        self.shutdown.store(true, .release);

        // Wait for all workers to finish
        for (self.workers) |worker| {
            worker.join();
        }

        self.allocator.free(self.workers);
        self.allocator.destroy(self);
    }

    /// Submit a work item to the thread pool
    /// Returns true if submitted, false if queue is full
    pub fn submit(self: *Self, item: WorkItem) bool {
        if (self.shutdown.load(.acquire)) {
            return false;
        }

        if (self.work_queue.tryPush(item)) {
            _ = self.total_tasks_submitted.fetchAdd(1, .release);
            return true;
        }
        return false;
    }

    /// Submit a work item, blocking if queue is full
    pub fn submitBlocking(self: *Self, item: WorkItem) !void {
        if (self.shutdown.load(.acquire)) {
            return error.PoolShutdown;
        }

        // Spin-wait with backoff
        var backoff: u32 = 1;
        while (!self.work_queue.tryPush(item)) {
            if (self.shutdown.load(.acquire)) {
                return error.PoolShutdown;
            }
            // Exponential backoff
            std.Thread.sleep(@as(u64, backoff) * std.time.ns_per_us);
            backoff = @min(backoff * 2, 1000); // Cap at 1ms
        }
        _ = self.total_tasks_submitted.fetchAdd(1, .release);
    }

    /// Get the number of pending tasks in the queue
    pub fn pendingTasks(self: *Self) usize {
        return self.work_queue.len();
    }

    /// Get the number of active workers currently processing tasks
    pub fn activeWorkers(self: *Self) usize {
        return self.active_workers.load(.acquire);
    }

    /// Get statistics about the thread pool
    pub fn getStats(self: *Self) Stats {
        return Stats{
            .num_workers = self.workers.len,
            .active_workers = self.active_workers.load(.acquire),
            .pending_tasks = self.work_queue.len(),
            .total_submitted = self.total_tasks_submitted.load(.acquire),
            .total_completed = self.total_tasks_completed.load(.acquire),
        };
    }

    pub const Stats = struct {
        num_workers: usize,
        active_workers: usize,
        pending_tasks: usize,
        total_submitted: u64,
        total_completed: u64,
    };

    /// Worker thread main function
    fn workerMain(self: *Self, worker_id: usize) void {
        _ = worker_id;
        var idle_count: u32 = 0;
        const max_idle: u32 = 100;
        const min_sleep_us: u64 = 1;
        const max_sleep_us: u64 = 100;

        while (!self.shutdown.load(.acquire)) {
            if (self.work_queue.tryPop()) |item| {
                // Mark worker as active
                _ = self.active_workers.fetchAdd(1, .release);
                idle_count = 0;

                // Execute the work
                item.callback(item.context);

                // Call completion callback if provided
                if (item.completion) |completion| {
                    completion(item.context);
                }

                // Mark worker as idle and increment completion count
                _ = self.active_workers.fetchSub(1, .release);
                _ = self.total_tasks_completed.fetchAdd(1, .release);
            } else {
                // No work available - use adaptive backoff
                idle_count += 1;
                if (idle_count > max_idle) {
                    const backoff: u6 = @intCast(@min(idle_count - max_idle, 10));
                    const sleep_us: u64 = @min(min_sleep_us << backoff, max_sleep_us);
                    std.Thread.sleep(sleep_us * @as(u64, std.time.ns_per_us));
                }
            }
        }
    }
};

/// Query work item for use with the thread pool
/// CANARY: REQ=REQ-PERF-THREAD-POOL-003; FEATURE="ThreadPool"; ASPECT=QueryWorkItem; STATUS=IMPL; OWNER=transport; UPDATED=2026-01-26
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

// Unit tests
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
