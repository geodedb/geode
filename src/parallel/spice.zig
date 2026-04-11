const std = @import("std");
const spice = @import("spice");

// CANARY: REQ=REQ-PERF-SPICE-003; FEATURE="SpiceWrapper"; ASPECT=CoreInterface; STATUS=IMPL; OWNER=performance; UPDATED=2026-02-02
// Unified interface for spice fork/join parallelism in Geode
// Provides high-level APIs for recursive divide-and-conquer algorithms

pub const ThreadPool = spice.ThreadPool;
pub const ThreadPoolConfig = spice.ThreadPoolConfig;
pub const Worker = spice.Worker;
pub const Task = spice.Task;
pub const Future = spice.Future;

/// Task context type for map operations
pub const TaskContext = *Task;

/// Global SpicePool instance for managing fork/join parallelism
/// CANARY: REQ=REQ-PERF-SPICE-004; FEATURE="SpicePool"; ASPECT=GlobalPool; STATUS=IMPL; OWNER=performance; UPDATED=2026-02-02
pub const SpicePool = struct {
    allocator: std.mem.Allocator,
    pool: ThreadPool,
    started: bool = false,
    config: ThreadPoolConfig,

    /// Initialize a SpicePool with the given allocator.
    /// Use `worker_count = null` for automatic detection.
    /// Auto-detect is capped at 16 workers — each spice worker allocates
    /// ~16 MB of thread stack via std.Thread.spawn's default, so scaling
    /// linearly with CPU count wastes hundreds of MB of address space on
    /// large-core-count machines without proportional throughput gain for
    /// geode's workload.  Callers needing more parallelism can pass an
    /// explicit count.
    pub fn init(allocator: std.mem.Allocator, worker_count: ?usize) SpicePool {
        const auto_max: usize = 16;
        const effective_count: ?usize = if (worker_count) |c|
            c
        else blk: {
            const cpus = std.Thread.getCpuCount() catch 4;
            break :blk @min(cpus, auto_max);
        };
        return .{
            .allocator = allocator,
            .pool = ThreadPool.init(allocator),
            .config = .{
                .background_worker_count = effective_count,
                .heartbeat_interval = 100 * std.time.ns_per_us,
            },
        };
    }

    /// Start the thread pool - must be called before any parallel operations
    pub fn start(self: *SpicePool) void {
        if (!self.started) {
            self.pool.start(self.config);
            self.started = true;
        }
    }

    /// Clean up resources - waits for all background threads to complete
    pub fn deinit(self: *SpicePool) void {
        if (self.started) {
            self.pool.deinit();
            self.started = false;
        }
    }

    /// Execute a function using fork/join parallelism
    /// Returns the result of the computation
    pub fn call(self: *SpicePool, comptime T: type, func: anytype, arg: anytype) T {
        if (!self.started) {
            self.start();
        }
        return self.pool.call(T, func, arg);
    }

    /// In-place parallel map operation
    /// Maps inputs to outputs using the provided map function
    /// CANARY: REQ=REQ-PERF-SPICE-008; FEATURE="SpicePoolMap"; ASPECT=InPlaceMap; STATUS=IMPL; OWNER=performance; UPDATED=2026-02-03
    pub fn map(
        self: *SpicePool,
        comptime Input: type,
        comptime Output: type,
        inputs: []const Input,
        outputs: []Output,
        comptime mapFn: fn (TaskContext, Input, *Output) void,
    ) !void {
        if (inputs.len != outputs.len) {
            return error.LengthMismatch;
        }
        if (inputs.len == 0) return;

        if (!self.started) {
            self.start();
        }

        const threshold = Thresholds.map;

        if (inputs.len <= threshold) {
            // Sequential fallback for small workloads
            for (inputs, 0..) |input, i| {
                var dummy_task: Task = undefined;
                mapFn(&dummy_task, input, &outputs[i]);
            }
            return;
        }

        // Use fork/join for larger workloads
        const Context = struct {
            inputs: []const Input,
            outputs: []Output,
            start_idx: usize,
            end_idx: usize,
            threshold_val: usize,
        };

        const parallelMapWorker = struct {
            fn work(task: *Task, ctx: Context) void {
                const len = ctx.end_idx - ctx.start_idx;

                if (len <= ctx.threshold_val) {
                    // Base case: process sequentially
                    for (ctx.start_idx..ctx.end_idx) |i| {
                        mapFn(task, ctx.inputs[i], &ctx.outputs[i]);
                    }
                    return;
                }

                const mid = ctx.start_idx + len / 2;

                // Fork: split work in half
                var future = Future(Context, void).init();
                future.fork(task, work, .{
                    .inputs = ctx.inputs,
                    .outputs = ctx.outputs,
                    .start_idx = ctx.start_idx,
                    .end_idx = mid,
                    .threshold_val = ctx.threshold_val,
                });

                // Do right half in current task
                work(task, .{
                    .inputs = ctx.inputs,
                    .outputs = ctx.outputs,
                    .start_idx = mid,
                    .end_idx = ctx.end_idx,
                    .threshold_val = ctx.threshold_val,
                });

                // Join: wait for left half
                _ = future.join(task);
            }
        }.work;

        _ = self.pool.call(void, parallelMapWorker, Context{
            .inputs = inputs,
            .outputs = outputs,
            .start_idx = 0,
            .end_idx = inputs.len,
            .threshold_val = threshold,
        });
    }
};

/// Parallel map operation with configurable threshold
/// Falls back to sequential execution for small workloads
/// CANARY: REQ=REQ-PERF-SPICE-005; FEATURE="ParallelMap"; ASPECT=MapOperation; STATUS=IMPL; OWNER=performance; UPDATED=2026-02-02
pub fn parallelMap(
    comptime T: type,
    comptime R: type,
    pool: *SpicePool,
    items: []const T,
    comptime mapFn: fn (*Task, T) R,
    threshold: usize,
) ![]R {
    const allocator = pool.allocator;
    var results = try allocator.alloc(R, items.len);

    if (items.len <= threshold) {
        // Sequential fallback for small workloads
        for (items, 0..) |item, i| {
            var dummy_task: Task = undefined;
            results[i] = mapFn(&dummy_task, item);
        }
        return results;
    }

    // Use fork/join for larger workloads
    const Context = struct {
        items: []const T,
        results: []R,
        start: usize,
        end: usize,
        threshold_val: usize,
    };

    const parallelMapWorker = struct {
        fn work(task: *Task, ctx: Context) void {
            const mid = (ctx.start + ctx.end) / 2;

            if (ctx.end - ctx.start <= ctx.threshold_val) {
                // Base case: process sequentially
                for (ctx.start..ctx.end) |i| {
                    ctx.results[i] = mapFn(task, ctx.items[i]);
                }
                return;
            }

            // Fork: split work in half
            var future = Future(Context, void).init();
            future.fork(task, work, .{
                .items = ctx.items,
                .results = ctx.results,
                .start = ctx.start,
                .end = mid,
                .threshold_val = ctx.threshold_val,
            });

            // Do right half in current task
            work(task, .{
                .items = ctx.items,
                .results = ctx.results,
                .start = mid,
                .end = ctx.end,
                .threshold_val = ctx.threshold_val,
            });

            // Join: wait for left half
            _ = future.join(task);
        }
    }.work;

    _ = pool.call(void, parallelMapWorker, Context{
        .items = items,
        .results = results,
        .start = 0,
        .end = items.len,
        .threshold_val = threshold,
    });

    return results;
}

/// Parallel reduce operation with configurable threshold
/// CANARY: REQ=REQ-PERF-SPICE-006; FEATURE="ParallelReduce"; ASPECT=ReduceOperation; STATUS=IMPL; OWNER=performance; UPDATED=2026-02-02
pub fn parallelReduce(
    comptime T: type,
    pool: *SpicePool,
    items: []const T,
    initial: T,
    comptime reduceFn: fn (*Task, T, T) T,
    threshold: usize,
) T {
    if (items.len == 0) return initial;
    if (items.len == 1) {
        var dummy_task: Task = undefined;
        return reduceFn(&dummy_task, initial, items[0]);
    }

    if (items.len <= threshold) {
        // Sequential fallback for small workloads
        var result = initial;
        var dummy_task: Task = undefined;
        for (items) |item| {
            result = reduceFn(&dummy_task, result, item);
        }
        return result;
    }

    const Context = struct {
        items: []const T,
        start: usize,
        end: usize,
        initial: T,
        threshold_val: usize,
    };

    const parallelReduceWorker = struct {
        fn work(task: *Task, ctx: Context) T {
            const len = ctx.end - ctx.start;

            if (len <= ctx.threshold_val) {
                // Base case: reduce sequentially
                var result = ctx.initial;
                for (ctx.start..ctx.end) |i| {
                    result = reduceFn(task, result, ctx.items[i]);
                }
                return result;
            }

            const mid = ctx.start + len / 2;

            // Fork: process left half
            var future = Future(Context, T).init();
            future.fork(task, work, .{
                .items = ctx.items,
                .start = ctx.start,
                .end = mid,
                .initial = ctx.initial,
                .threshold_val = ctx.threshold_val,
            });

            // Do right half in current task
            const right_result = work(task, .{
                .items = ctx.items,
                .start = mid,
                .end = ctx.end,
                .initial = ctx.initial,
                .threshold_val = ctx.threshold_val,
            });

            // Join: combine results
            const left_result = future.join(task) orelse ctx.initial;
            return reduceFn(task, left_result, right_result);
        }
    }.work;

    return pool.call(T, parallelReduceWorker, Context{
        .items = items,
        .start = 0,
        .end = items.len,
        .initial = initial,
        .threshold_val = threshold,
    });
}

/// Parallel for-each with index
/// Executes a function for each index in a range, with fork/join parallelism
/// CANARY: REQ=REQ-PERF-SPICE-007; FEATURE="ParallelForEach"; ASPECT=ForEachOperation; STATUS=IMPL; OWNER=performance; UPDATED=2026-02-02
pub fn parallelForEach(
    pool: *SpicePool,
    start: usize,
    end: usize,
    context: anytype,
    comptime func: fn (*Task, usize, @TypeOf(context)) void,
    threshold: usize,
) void {
    if (end <= start) return;

    const len = end - start;
    if (len <= threshold) {
        // Sequential fallback
        var dummy_task: Task = undefined;
        for (start..end) |i| {
            func(&dummy_task, i, context);
        }
        return;
    }

    const Context = struct {
        start: usize,
        end: usize,
        user_ctx: @TypeOf(context),
        threshold_val: usize,
    };

    const parallelForEachWorker = struct {
        fn work(task: *Task, ctx: Context) void {
            const local_len = ctx.end - ctx.start;

            if (local_len <= ctx.threshold_val) {
                // Base case: execute sequentially
                for (ctx.start..ctx.end) |i| {
                    func(task, i, ctx.user_ctx);
                }
                return;
            }

            const mid = ctx.start + local_len / 2;

            // Fork left half
            var future = Future(Context, void).init();
            future.fork(task, work, .{
                .start = ctx.start,
                .end = mid,
                .user_ctx = ctx.user_ctx,
                .threshold_val = ctx.threshold_val,
            });

            // Do right half
            work(task, .{
                .start = mid,
                .end = ctx.end,
                .user_ctx = ctx.user_ctx,
                .threshold_val = ctx.threshold_val,
            });

            // Join
            _ = future.join(task);
        }
    }.work;

    _ = pool.call(void, parallelForEachWorker, Context{
        .start = start,
        .end = end,
        .user_ctx = context,
        .threshold_val = threshold,
    });
}

/// Check if spice parallelism should be used based on workload size
/// Returns true if the workload is large enough to benefit from parallelism
pub inline fn shouldUseParallelism(item_count: usize, threshold: usize) bool {
    return item_count > threshold;
}

/// Default thresholds for various operations
pub const Thresholds = struct {
    /// Default threshold for parallel map operations
    pub const map: usize = 64;

    /// Default threshold for parallel reduce operations
    pub const reduce: usize = 128;

    /// Default threshold for parallel for-each operations
    pub const forEach: usize = 32;

    /// Threshold for HNSW batch distance computations
    pub const hnswBatchDistance: usize = 32;

    /// Threshold for CBO join enumeration subsets
    pub const cboSubsets: usize = 4;

    /// Threshold for GraphStore snapshot chunk processing
    pub const graphStoreSegments: usize = 2;
};

// Unit tests
test "SpicePool init and deinit" {
    var pool = SpicePool.init(std.testing.allocator, 2);
    pool.start();
    defer pool.deinit();
}

test "parallelMap with small input" {
    var pool = SpicePool.init(std.testing.allocator, 2);
    pool.start();
    defer pool.deinit();

    const items = [_]u32{ 1, 2, 3, 4, 5 };
    const mapSquare = struct {
        fn map(_: *Task, x: u32) u64 {
            return @as(u64, x) * x;
        }
    }.map;

    const results = try parallelMap(u32, u64, &pool, &items, mapSquare, 10);
    defer pool.allocator.free(results);

    try std.testing.expectEqual(@as(u64, 1), results[0]);
    try std.testing.expectEqual(@as(u64, 4), results[1]);
    try std.testing.expectEqual(@as(u64, 9), results[2]);
    try std.testing.expectEqual(@as(u64, 16), results[3]);
    try std.testing.expectEqual(@as(u64, 25), results[4]);
}

test "shouldUseParallelism" {
    try std.testing.expect(!shouldUseParallelism(10, 32));
    try std.testing.expect(shouldUseParallelism(100, 32));
    try std.testing.expect(shouldUseParallelism(33, 32));
    try std.testing.expect(!shouldUseParallelism(32, 32));
}
