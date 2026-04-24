const std = @import("std");
const ext_pool = @import("thread_pool");

// CANARY: REQ=REQ-PERF-THREAD-POOL-001; FEATURE="ThreadPool"; ASPECT=QueryExecution; STATUS=TESTED; TEST=test_performance_optimizations.zig; OWNER=transport; UPDATED=2026-04-01
// GAP-0201: High-performance thread pool for parallel query execution
// GAP-0275: Consolidated on the external thread_pool dependency.
//           This module keeps the fire-and-forget dispatch semantics Geode
//           needs for long-lived worker queues, while the higher-level
//           parallel wrapper builds map/reduce/forEach helpers on top.

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
    /// How long an idle worker parks on its wake condvar before its
    /// timedWait returns and it re-polls. Upstream default is 250 µs —
    /// fine for bursty latency-critical work but disastrous for a
    /// long-lived server: 16 idle workers × 4000 wakes/s each = 64 k
    /// cross-CPU IPIs + TLB flushes/s on an otherwise idle box (see
    /// docs/performance/2026-04-19-qps-closure/step-1-profile.md, which
    /// attributed ~26 % of samples to this spin storm). Default 10 ms
    /// here — a submitter still wakes an idle worker via the condvar
    /// signal path with zero added latency, but idle workers no longer
    /// burn cycles.
    idle_park_after_ns: u64 = 10_000_000,
    /// How long `deinit` waits for in-flight tasks to drain before
    /// giving up and logging a warning.  Upstream default is 30 s —
    /// way too long for per-connection pools on a server where the
    /// connection may be torn down between files (see the 30 s/file
    /// floor discovered on 2026-04-23 under the msft-graph workload).
    /// Default 2 s here: still enough for any in-flight fast-path
    /// mutation to complete (those finish in milliseconds post Task
    /// 16 + Task 19), but short enough that connection teardown
    /// doesn't stall the next file's worker startup.
    deinit_timeout_ns: u64 = 2 * std.time.ns_per_s,
};

/// Thread pool statistics.
pub const Stats = struct {
    num_workers: usize,
    pending_tasks: usize,
    total_submitted: u64,
    total_completed: u64,
};

pub const WaitGroup = ext_pool.WaitGroup;
pub const TaskHandle = ext_pool.TaskHandle;
pub const TaskContext = ext_pool.TaskContext;
pub const TaskFn = ext_pool.TaskFn;
pub const SubmitOptions = ext_pool.SubmitOptions;
pub const ShutdownMode = ext_pool.ShutdownMode;

/// High-performance thread pool for query execution.
/// CANARY: REQ=REQ-PERF-THREAD-POOL-002; FEATURE="ThreadPool"; ASPECT=WorkerManagement; STATUS=TESTED; TEST=test_performance_optimizations.zig; OWNER=transport; UPDATED=2026-04-01
///
/// Compatibility wrapper over the external `thread_pool` dependency.
pub const ThreadPool = struct {
    const Self = @This();
    const WorkerStub = struct {};
    const SubmittedTask = struct {
        allocator: std.mem.Allocator,
        item: WorkItem,
    };

    allocator: std.mem.Allocator,
    inner: ext_pool.ThreadPool,

    /// Exposed so callers can read `pool.workers.len` for observability.
    workers: []WorkerStub,

    /// Initialize the thread pool.
    pub fn init(allocator: std.mem.Allocator, config: ThreadPoolConfig) !*Self {
        // Upstream thread_pool 0.2.0 enforces: if allow_blocking_lane = true
        // then blocking_workers > 0 and strictly less than max_threads.
        // `submitBlocking` routes to `.lane = .blocking`, reserved for
        // serialized long-lived work (cert gen, audit writes, keepalive
        // loops), so the blocking lane must always be enabled. We keep
        // `blocking_workers = 1` (load-bearing invariant, asserted by
        // tests/test_thread_pool_lane_parallelism.zig) and require at
        // least 2 total threads so the default lane has a worker.
        // `submit` / `submitDefault` route to the `.default` lane, which
        // owns `num_threads - 1` workers.
        const requested = effectiveThreadCount(config);
        const num: usize = @max(requested, 2);
        const workers = try allocator.alloc(WorkerStub, num);
        errdefer allocator.free(workers);
        var inner = try ext_pool.ThreadPool.init(allocator, .{
            .min_threads = num,
            .max_threads = num,
            .queue_capacity = @max(config.queue_capacity, 64),
            .local_queue_capacity = @max(@min(config.queue_capacity, 256), 1),
            // Use global_queue to avoid TLS worker-index cross-contamination
            // when a worker thread from one pool submits to a different pool
            // (e.g. main pool worker → per-connection acceptor_pool).
            .scheduler_variant = .global_queue,
            // GAP-0807: raise default idle park from the upstream 250 µs
            // to this caller's config (default 10 ms). See config doc.
            .idle_park_after_ns = config.idle_park_after_ns,
            // 2026-04-23: propagate the caller's deinit timeout through
            // to the upstream pool (default 2 s, was 30 s upstream).
            .deinit_timeout_ns = config.deinit_timeout_ns,
            .allow_blocking_lane = true,
            .blocking_workers = 1,
        });
        errdefer inner.deinit();
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .inner = inner,
            .workers = workers,
        };
        return self;
    }

    /// Shutdown the thread pool and wait for all workers to finish.
    pub fn deinit(self: *Self) void {
        self.inner.deinit();
        self.allocator.free(self.workers);
        self.allocator.destroy(self);
    }

    /// Submit a work item to the thread pool's default lane.
    /// Returns true if submitted, false if queue is full.
    ///
    /// Routes to `.lane = .default` — serviced by all non-blocking workers
    /// (with `num_threads = N` and `blocking_workers = 1` the default lane
    /// has `N - 1` workers). This is the right entry point for generic
    /// parallel work (connection handlers, stream handlers, background
    /// dispatch); pre-fix it routed to the 1-wide `.blocking` lane and
    /// deadlocked under >1 concurrent long-lived task. See Task #31 triage
    /// at docs/performance/2026-04-24-sharding/TASK-31-TRIAGE.md.
    ///
    /// Callers who genuinely need the 1-wide blocking lane (cert gen, audit
    /// writes, keepalive loops) must use `submitBlocking` explicitly.
    pub fn submit(self: *Self, item: WorkItem) bool {
        _ = self.submitInternal(item, .{ .lane = .default }) catch return false;
        return true;
    }

    /// Alias for `submit` — kept for source compatibility.  Both entry
    /// points route to the default lane.  Prefer `submit` in new code.
    pub fn submitDefault(self: *Self, item: WorkItem) bool {
        return self.submit(item);
    }

    /// Submit a work item, blocking if queue is full.
    pub fn submitBlocking(self: *Self, item: WorkItem) !void {
        _ = try self.submitInternal(item, .{
            .lane = .blocking,
            .backpressure = .block,
        });
    }

    /// Get the number of pending tasks in the queue.
    pub fn pendingTasks(self: *Self) usize {
        const stats = self.inner.statsSnapshot();
        return @intCast(stats.queue_depth_current);
    }

    /// Get the number of active workers currently processing tasks.
    pub fn activeWorkers(self: *Self) usize {
        const stats = self.inner.statsSnapshot();
        return @intCast(stats.active_tasks);
    }

    /// Get statistics about the thread pool.
    pub fn getStats(self: *Self) Stats {
        const stats = self.inner.statsSnapshot();
        return .{
            .num_workers = self.workers.len,
            .pending_tasks = @intCast(stats.queue_depth_current),
            .total_submitted = stats.submitted,
            .total_completed = stats.completed,
        };
    }

    pub fn waitGroup(self: *Self) WaitGroup {
        return self.inner.waitGroup();
    }

    pub fn wait(self: *Self, handle: TaskHandle) !void {
        try self.inner.wait(handle);
    }

    pub fn submitTask(self: *Self, task_fn: TaskFn, ctx: *anyopaque, options: SubmitOptions) !TaskHandle {
        return self.inner.submit(task_fn, ctx, options);
    }

    pub fn shutdown(self: *Self, mode: ShutdownMode, timeout_ns: ?u64) !void {
        try self.inner.shutdown(mode, timeout_ns);
    }

    fn effectiveThreadCount(config: ThreadPoolConfig) usize {
        if (config.num_threads != 0) return config.num_threads;
        const cpus = std.Thread.getCpuCount() catch 4;
        const auto_max: usize = 16;
        return @max(@min(cpus, auto_max), 2);
    }

    fn submitInternal(self: *Self, item: WorkItem, options: SubmitOptions) !TaskHandle {
        const submitted = try self.allocator.create(SubmittedTask);
        errdefer self.allocator.destroy(submitted);
        submitted.* = .{
            .allocator = self.allocator,
            .item = item,
        };

        return try self.inner.submit(runSubmittedTask, @ptrCast(submitted), options);
    }

    fn runSubmittedTask(ctx: *anyopaque, runtime: *TaskContext) void {
        _ = runtime;
        const submitted: *SubmittedTask = @ptrCast(@alignCast(ctx));
        defer submitted.allocator.destroy(submitted);
        submitted.item.callback(submitted.item.context);
        if (submitted.item.completion) |completion| {
            completion(submitted.item.context);
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
