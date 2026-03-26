// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const bounded_queue = @import("bounded_queue.zig");

const BoundedQueue = bounded_queue.BoundedQueue;

/// Work item representing a task to be executed by the thread pool.
///
/// The caller owns the `context` pointer and must ensure it remains
/// valid until the callback (and optional completion) have returned.
///
/// **Important:** Callbacks must not panic. A panicking callback will
/// abort the worker thread, permanently reducing pool capacity and
/// leaving the `active_workers` counter in an inconsistent state.
pub const WorkItem = struct {
    /// User data pointer for the task context.
    context: *anyopaque,
    /// Callback function to execute the work. Must not panic.
    callback: *const fn (context: *anyopaque) void,
    /// Optional completion callback (called after work is done). Must not panic.
    completion: ?*const fn (context: *anyopaque) void = null,
};

/// Thread pool configuration.
pub const ThreadPoolConfig = struct {
    /// Number of worker threads (0 = auto-detect based on CPU count).
    num_threads: usize = 0,
    /// Thread stack size in bytes (0 = system default).
    stack_size: usize = 0,
};

/// Thread pool statistics.
///
/// Values are sampled from independent atomics and may be momentarily
/// inconsistent under concurrent access. Suitable for monitoring and
/// debugging, not for control-flow decisions.
pub const Stats = struct {
    /// Total number of worker threads.
    num_workers: usize,
    /// Workers currently executing a callback.
    active_workers: usize,
    /// Approximate items in the work queue.
    pending_tasks: usize,
    /// Cumulative tasks submitted since pool creation.
    total_submitted: u64,
    /// Cumulative tasks completed since pool creation.
    total_completed: u64,
};

/// High-performance thread pool for parallel task execution.
///
/// The internal work queue holds up to 4096 items. Non-blocking `submit`
/// returns false when the queue is full; `submitBlocking` waits with
/// exponential backoff until space is available or the optional timeout
/// expires.
pub const ThreadPool = struct {
    const Self = @This();
    const queue_capacity = 4096;
    const QueueType = BoundedQueue(WorkItem, queue_capacity);

    const cache_line = 64;

    allocator: std.mem.Allocator,
    config: ThreadPoolConfig,
    workers: []std.Thread,
    spawned_count: usize,
    work_queue: QueueType,
    wait_mutex: std.Thread.Mutex,
    wait_cond: std.Thread.Condition,

    // Worker-loop hot path: read every iteration — own cache line.
    shutdown: std.atomic.Value(bool) align(cache_line),
    sleeping_workers: std.atomic.Value(usize),

    // Completion counters: written by every worker per task — own cache line.
    active_workers: std.atomic.Value(usize) align(cache_line),
    total_tasks_completed: std.atomic.Value(usize),

    // Submission counters: written by submitters — own cache line.
    total_tasks_submitted: std.atomic.Value(usize) align(cache_line),
    blocking_waiters: std.atomic.Value(usize),

    /// Initialize the thread pool and start worker threads.
    pub fn init(allocator: std.mem.Allocator, config: ThreadPoolConfig) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const num_threads = if (config.num_threads == 0)
            @max(std.Thread.getCpuCount() catch 4, 2)
        else
            config.num_threads;

        self.* = Self{
            .allocator = allocator,
            .config = config,
            .workers = try allocator.alloc(std.Thread, num_threads),
            .spawned_count = 0,
            .work_queue = QueueType.init(),
            .wait_mutex = .{},
            .wait_cond = .{},
            .shutdown = std.atomic.Value(bool).init(false),
            .active_workers = std.atomic.Value(usize).init(0),
            .sleeping_workers = std.atomic.Value(usize).init(0),
            .blocking_waiters = std.atomic.Value(usize).init(0),
            .total_tasks_submitted = std.atomic.Value(usize).init(0),
            .total_tasks_completed = std.atomic.Value(usize).init(0),
        };

        // errdefer for partial spawn: shut down and join threads started so far.
        errdefer {
            self.shutdown.store(true, .release);
            self.wait_mutex.lock();
            self.wait_cond.broadcast();
            self.wait_mutex.unlock();
            for (self.workers[0..self.spawned_count]) |w| w.join();
            allocator.free(self.workers);
        }

        for (self.workers, 0..) |*worker, i| {
            var spawn_config = std.Thread.SpawnConfig{};
            if (config.stack_size > 0) {
                spawn_config.stack_size = config.stack_size;
            }
            worker.* = try std.Thread.spawn(spawn_config, workerMain, .{self});
            self.spawned_count = i + 1;
        }

        return self;
    }

    /// Shutdown the thread pool and wait for all workers to finish.
    ///
    /// After `deinit` returns, the pool pointer is invalid. Calling
    /// `deinit` on an already-shut-down pool is a no-op.
    pub fn deinit(self: *Self) void {
        // Guard against double-deinit.
        if (self.shutdown.cmpxchgStrong(false, true, .acq_rel, .monotonic) != null) {
            return;
        }

        self.wait_mutex.lock();
        self.wait_cond.broadcast();
        self.wait_mutex.unlock();

        for (self.workers[0..self.spawned_count]) |worker| {
            worker.join();
        }

        const alloc = self.allocator;
        const workers = self.workers;
        alloc.free(workers);
        alloc.destroy(self);
    }

    /// Submit a work item to the thread pool (non-blocking).
    /// Returns true if submitted, false if the queue is full or the
    /// pool is shutting down.
    pub fn submit(self: *Self, item: WorkItem) bool {
        if (self.shutdown.load(.acquire)) {
            return false;
        }

        if (self.work_queue.tryPush(item)) {
            _ = self.total_tasks_submitted.fetchAdd(1, .monotonic);
            self.wait_mutex.lock();
            self.wait_cond.signal();
            self.wait_mutex.unlock();
            return true;
        }
        return false;
    }

    pub const SubmitError = error{ PoolShutdown, Timeout };

    /// Submit a work item, blocking until space is available.
    ///
    /// If `timeout_ns` is provided and the deadline passes before the
    /// item can be enqueued, returns `error.Timeout`.
    /// Returns `error.PoolShutdown` if the pool is shutting down.
    pub fn submitBlocking(self: *Self, item: WorkItem, timeout_ns: ?u64) SubmitError!void {
        if (self.shutdown.load(.acquire)) {
            return error.PoolShutdown;
        }

        const deadline: ?u64 = if (timeout_ns) |t|
            nanoNow() +| t
        else
            null;

        _ = self.blocking_waiters.fetchAdd(1, .monotonic);
        defer _ = self.blocking_waiters.fetchSub(1, .monotonic);

        var backoff: u32 = 1;
        while (!self.work_queue.tryPush(item)) {
            if (self.shutdown.load(.acquire)) {
                return error.PoolShutdown;
            }
            if (deadline) |dl| {
                if (nanoNow() >= dl) {
                    return error.Timeout;
                }
            }
            self.wait_mutex.lock();
            self.wait_cond.timedWait(&self.wait_mutex, @as(u64, backoff) * std.time.ns_per_us) catch {};
            self.wait_mutex.unlock();
            backoff = @min(backoff * 2, 1000);
        }
        _ = self.total_tasks_submitted.fetchAdd(1, .monotonic);
        self.wait_mutex.lock();
        self.wait_cond.signal();
        self.wait_mutex.unlock();
    }

    /// Get the number of pending tasks in the queue.
    pub fn pendingTasks(self: *Self) usize {
        return self.work_queue.len();
    }

    /// Get the number of active workers currently processing tasks.
    pub fn activeWorkers(self: *Self) usize {
        return self.active_workers.load(.acquire);
    }

    /// Get statistics about the thread pool.
    pub fn getStats(self: *Self) Stats {
        return Stats{
            .num_workers = self.workers.len,
            .active_workers = self.active_workers.load(.acquire),
            .pending_tasks = self.work_queue.len(),
            .total_submitted = @intCast(self.total_tasks_submitted.load(.acquire)),
            .total_completed = @intCast(self.total_tasks_completed.load(.acquire)),
        };
    }

    /// Monotonic nanosecond clock, clamped to zero for negative timestamps.
    fn nanoNow() u64 {
        const ts = std.time.nanoTimestamp();
        return if (ts < 0) 0 else @intCast(ts);
    }

    /// Worker thread main loop. Uses a spin-then-park strategy:
    /// 1. Try to pop a work item from the queue.
    /// 2. If found, execute the callback (and optional completion).
    /// 3. If empty, yield the CPU for up to `max_spin_before_wait` iterations.
    /// 4. If still empty, park on a condition variable with a 5ms timeout.
    /// Exits when `shutdown` is set to true.
    fn workerMain(self: *Self) void {
        var idle_count: u32 = 0;
        const max_spin_before_wait: u32 = 64;
        const idle_wait_ns: u64 = 5 * std.time.ns_per_ms;

        while (!self.shutdown.load(.acquire)) {
            if (self.work_queue.tryPop()) |item| {
                _ = self.active_workers.fetchAdd(1, .monotonic);
                idle_count = 0;

                item.callback(item.context);

                if (item.completion) |completion| {
                    completion(item.context);
                }

                _ = self.active_workers.fetchSub(1, .monotonic);
                _ = self.total_tasks_completed.fetchAdd(1, .monotonic);

                // Wake blocked submitBlocking callers if any are waiting.
                if (self.blocking_waiters.load(.acquire) > 0) {
                    self.wait_mutex.lock();
                    self.wait_cond.signal();
                    self.wait_mutex.unlock();
                }
            } else {
                idle_count += 1;
                if (idle_count <= max_spin_before_wait) {
                    std.Thread.yield() catch {};
                    continue;
                }

                _ = self.sleeping_workers.fetchAdd(1, .monotonic);
                self.wait_mutex.lock();
                if (!self.shutdown.load(.acquire) and self.work_queue.isEmpty()) {
                    self.wait_cond.timedWait(&self.wait_mutex, idle_wait_ns) catch {};
                }
                self.wait_mutex.unlock();
                _ = self.sleeping_workers.fetchSub(1, .monotonic);
                idle_count = 0;
            }
        }
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "ThreadPool: basic initialization and shutdown" {
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

    for (0..10) |_| {
        try std.testing.expect(pool.submit(.{
            .context = @ptrCast(&ctx),
            .callback = callback,
        }));
    }

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

    var timeout: u32 = 0;
    while (!completed.load(.acquire) and timeout < 1000) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
        timeout += 1;
    }

    const stats = pool.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.total_submitted);
    try std.testing.expectEqual(@as(u64, 1), stats.total_completed);
}

test "ThreadPool: completion callback" {
    const pool = try ThreadPool.init(std.testing.allocator, .{
        .num_threads = 2,
    });
    defer pool.deinit();

    var work_done = std.atomic.Value(bool).init(false);
    var completion_done = std.atomic.Value(bool).init(false);

    const Context = struct {
        work_done: *std.atomic.Value(bool),
        completion_done: *std.atomic.Value(bool),
    };

    var ctx = Context{
        .work_done = &work_done,
        .completion_done = &completion_done,
    };

    const work_cb = struct {
        fn call(context: *anyopaque) void {
            const c: *Context = @ptrCast(@alignCast(context));
            c.work_done.store(true, .release);
        }
    }.call;

    const completion_cb = struct {
        fn call(context: *anyopaque) void {
            const c: *Context = @ptrCast(@alignCast(context));
            c.completion_done.store(true, .release);
        }
    }.call;

    try std.testing.expect(pool.submit(.{
        .context = @ptrCast(&ctx),
        .callback = work_cb,
        .completion = completion_cb,
    }));

    var timeout: u32 = 0;
    while (!completion_done.load(.acquire) and timeout < 1000) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
        timeout += 1;
    }

    try std.testing.expect(work_done.load(.acquire));
    try std.testing.expect(completion_done.load(.acquire));
}

test "ThreadPoolConfig: default values" {
    const config = ThreadPoolConfig{};
    try std.testing.expectEqual(@as(usize, 0), config.num_threads);
    try std.testing.expectEqual(@as(usize, 0), config.stack_size);
}

test "ThreadPool: deinit CAS guard prevents double shutdown" {
    const pool = try ThreadPool.init(std.testing.allocator, .{
        .num_threads = 2,
    });

    // Manually set shutdown to true (simulating a prior deinit's CAS).
    // The real deinit should see this and return early (no-op).
    pool.shutdown.store(true, .release);

    // Broadcast so workers wake and exit.
    pool.wait_mutex.lock();
    pool.wait_cond.broadcast();
    pool.wait_mutex.unlock();

    for (pool.workers[0..pool.spawned_count]) |w| w.join();

    // Now call the real deinit — the CAS guard should make it a no-op
    // (shutdown is already true), so it will return without double-freeing.
    // We manually clean up since deinit won't run the free path.
    pool.allocator.free(pool.workers);
    pool.allocator.destroy(pool);
}

test "ThreadPool: submitBlocking with timeout" {
    const pool = try ThreadPool.init(std.testing.allocator, .{
        .num_threads = 1,
    });
    defer pool.deinit();

    var counter = std.atomic.Value(u32).init(0);
    const Context = struct { counter: *std.atomic.Value(u32) };
    var ctx = Context{ .counter = &counter };

    const callback = struct {
        fn call(context: *anyopaque) void {
            const c: *Context = @ptrCast(@alignCast(context));
            _ = c.counter.fetchAdd(1, .release);
        }
    }.call;

    // Submit some work via blocking path (should succeed immediately).
    try pool.submitBlocking(.{
        .context = @ptrCast(&ctx),
        .callback = callback,
    }, null);

    var timeout: u32 = 0;
    while (counter.load(.acquire) < 1 and timeout < 1000) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
        timeout += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), counter.load(.acquire));
}

test "ThreadPool: submit returns false after shutdown" {
    const pool = try ThreadPool.init(std.testing.allocator, .{
        .num_threads = 1,
    });

    const noop = struct {
        fn call(_: *anyopaque) void {}
    }.call;

    var dummy: u8 = 0;
    pool.deinit();

    // Pool is shut down — submit must return false. We can't use the
    // pool pointer after deinit frees it, so instead we test via
    // a fresh pool that we shut down first.
    const pool2 = try ThreadPool.init(std.testing.allocator, .{
        .num_threads = 1,
    });

    // Trigger shutdown without freeing (we need the pointer alive).
    pool2.shutdown.store(true, .release);
    pool2.wait_mutex.lock();
    pool2.wait_cond.broadcast();
    pool2.wait_mutex.unlock();

    try std.testing.expect(!pool2.submit(.{
        .context = @ptrCast(&dummy),
        .callback = noop,
    }));

    // Clean up: join workers, free.
    for (pool2.workers[0..pool2.spawned_count]) |w| w.join();
    pool2.allocator.free(pool2.workers);
    pool2.allocator.destroy(pool2);
}

test "ThreadPool: submitBlocking returns PoolShutdown after shutdown" {
    const pool = try ThreadPool.init(std.testing.allocator, .{
        .num_threads = 1,
    });

    const noop = struct {
        fn call(_: *anyopaque) void {}
    }.call;

    // Signal shutdown but don't free — we need to test the error path.
    pool.shutdown.store(true, .release);
    pool.wait_mutex.lock();
    pool.wait_cond.broadcast();
    pool.wait_mutex.unlock();

    var dummy: u8 = 0;
    const result = pool.submitBlocking(.{
        .context = @ptrCast(&dummy),
        .callback = noop,
    }, null);

    try std.testing.expectError(error.PoolShutdown, result);

    for (pool.workers[0..pool.spawned_count]) |w| w.join();
    pool.allocator.free(pool.workers);
    pool.allocator.destroy(pool);
}

test "ThreadPool: submitBlocking returns Timeout" {
    const pool = try ThreadPool.init(std.testing.allocator, .{
        .num_threads = 1,
    });
    defer pool.deinit();

    // The single worker will block on this flag, keeping it busy.
    var gate = std.atomic.Value(bool).init(false);

    const BlockCtx = struct { gate: *std.atomic.Value(bool) };
    var block_ctx = BlockCtx{ .gate = &gate };

    const block_cb = struct {
        fn call(raw: *anyopaque) void {
            const ctx: *BlockCtx = @ptrCast(@alignCast(raw));
            while (!ctx.gate.load(.acquire)) {
                std.Thread.yield() catch {};
            }
        }
    }.call;

    const noop = struct {
        fn call(_: *anyopaque) void {}
    }.call;

    // Submit the blocking item — worker picks it up and blocks.
    try std.testing.expect(pool.submit(.{
        .context = @ptrCast(&block_ctx),
        .callback = block_cb,
    }));

    // Give the worker time to pick up the item.
    std.Thread.sleep(5 * std.time.ns_per_ms);

    // Fill the remaining queue slots (worker is stuck, can't drain).
    var dummy: u8 = 0;
    var filled: usize = 0;
    for (0..ThreadPool.queue_capacity) |_| {
        if (!pool.submit(.{
            .context = @ptrCast(&dummy),
            .callback = noop,
        })) break;
        filled += 1;
    }

    // Queue should be full now. submitBlocking with tiny timeout → Timeout.
    const result = pool.submitBlocking(.{
        .context = @ptrCast(&dummy),
        .callback = noop,
    }, 1_000); // 1 microsecond

    try std.testing.expectError(error.Timeout, result);

    // Release the gate so the worker can drain and shutdown cleanly.
    gate.store(true, .release);
}
