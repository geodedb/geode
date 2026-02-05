const std = @import("std");

// CANARY: REQ=REQ-PERF-SPICE-009; FEATURE="SpiceIntegration"; ASPECT=ExecutionPool; STATUS=IMPL; OWNER=performance; UPDATED=2026-02-02
const spice_wrapper = @import("parallel/spice");
const SpicePool = spice_wrapper.SpicePool;

// Parallel execution pool backed by spice fork/join
// CANARY: REQ=REQ-GQL-PARALLEL-001; FEATURE="Parallel Exec"; ASPECT=ENGINE; STATUS=TESTED; TEST=tests/e2e_parallel_execution.zig:1; BENCH=tests/benchmark_parallel_expand_mem_perf.zig:1; OWNER=engine; UPDATED=2026-02-04

pub const JobFn = *const fn (ctx: ?*anyopaque) void;
pub const Job = struct {
    func: JobFn,
    ctx: ?*anyopaque,
    priority: u8 = 0, // retained for API compatibility
    chunk_size: ?usize = null,
};

// Deterministic parallel map: splits input slice into chunks, schedules jobs that
// apply workerFn(element_index, element_ptr, user_ctx) and stores results in order.
pub const MapResult = struct { items: []u8 };

pub fn parallelMap(
    allocator: std.mem.Allocator,
    pool: *Pool,
    elem_size: usize,
    src_count: usize,
    worker_fn: *const fn (index: usize, dst_elem: []u8, user_ctx: ?*anyopaque) void,
    user_ctx: ?*anyopaque,
) !MapResult {
    if (src_count == 0) return MapResult{ .items = try allocator.alloc(u8, 0) };
    const total_bytes = elem_size * src_count;
    var out = try allocator.alloc(u8, total_bytes);

    if (!pool.enabled or !spice_wrapper.shouldUseParallelism(src_count, spice_wrapper.Thresholds.map)) {
        var i: usize = 0;
        while (i < src_count) : (i += 1) {
            worker_fn(i, out[i * elem_size .. i * elem_size + elem_size], user_ctx);
        }
        return MapResult{ .items = out };
    }

    const Context = struct {
        out: []u8,
        elem_size: usize,
        worker_fn: *const fn (usize, []u8, ?*anyopaque) void,
        user_ctx: ?*anyopaque,
    };

    const ctx = Context{
        .out = out,
        .elem_size = elem_size,
        .worker_fn = worker_fn,
        .user_ctx = user_ctx,
    };

    spice_wrapper.parallelForEach(
        &pool.spice_pool,
        0,
        src_count,
        ctx,
        struct {
            fn work(_: *spice_wrapper.Task, idx: usize, c: Context) void {
                const start = idx * c.elem_size;
                c.worker_fn(idx, c.out[start .. start + c.elem_size], c.user_ctx);
            }
        }.work,
        spice_wrapper.Thresholds.map,
    );

    return MapResult{ .items = out };
}

pub const Pool = struct {
    allocator: std.mem.Allocator,
    spice_pool: SpicePool,
    enabled: bool = true,
    worker_count: usize,
    queued_jobs: std.ArrayList(Job),
    mutex: std.Thread.Mutex = .{},
    chunk_size_estimator: AdaptiveChunkEstimator,

    pub fn init(allocator: std.mem.Allocator, worker_count: usize) !Pool {
        const count = if (worker_count == 0) std.Thread.getCpuCount() catch 4 else worker_count;
        var pool = Pool{
            .allocator = allocator,
            .spice_pool = SpicePool.init(allocator, count),
            .enabled = true,
            .worker_count = count,
            .queued_jobs = std.ArrayList(Job).init(allocator),
            .chunk_size_estimator = AdaptiveChunkEstimator.init(),
        };
        pool.spice_pool.start();
        return pool;
    }

    /// Initialize spice pool if not already started (idempotent)
    pub fn initSpicePool(self: *Pool) !void {
        self.spice_pool.start();
    }

    /// Execute a fork/join computation using spice
    pub fn forkJoin(
        self: *Pool,
        comptime T: type,
        func: anytype,
        arg: anytype,
    ) T {
        return self.spice_pool.call(T, func, arg);
    }

    /// Parallel map using spice fork/join (for recursive divide-and-conquer workloads)
    pub fn spiceMap(
        self: *Pool,
        comptime T: type,
        comptime R: type,
        items: []const T,
        comptime mapFn: fn (*spice_wrapper.Task, T) R,
        threshold: usize,
    ) ![]R {
        return spice_wrapper.parallelMap(T, R, &self.spice_pool, items, mapFn, threshold);
    }

    pub fn submit(self: *Pool, job: Job) !void {
        if (!self.enabled) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.queued_jobs.append(self.allocator, job);
    }

    pub fn submitBatch(self: *Pool, jobs: []const Job) !void {
        if (!self.enabled or jobs.len == 0) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.queued_jobs.appendSlice(self.allocator, jobs);
    }

    pub fn waitIdle(self: *Pool) void {
        if (!self.enabled) return;

        while (true) {
            self.mutex.lock();
            if (self.queued_jobs.items.len == 0) {
                self.mutex.unlock();
                break;
            }

            const count = self.queued_jobs.items.len;
            const jobs = self.allocator.alloc(Job, count) catch {
                self.mutex.unlock();
                break;
            };
            std.mem.copy(Job, jobs, self.queued_jobs.items);
            self.queued_jobs.items.len = 0;
            self.mutex.unlock();

            const Context = struct {
                jobs: []Job,
            };

            spice_wrapper.parallelForEach(
                &self.spice_pool,
                0,
                jobs.len,
                Context{ .jobs = jobs },
                struct {
                    fn work(_: *spice_wrapper.Task, idx: usize, c: Context) void {
                        const j = c.jobs[idx];
                        j.func(j.ctx);
                    }
                }.work,
                spice_wrapper.Thresholds.forEach,
            );

            self.allocator.free(jobs);
        }
    }

    pub fn deinit(self: *Pool) void {
        self.spice_pool.deinit();
        self.queued_jobs.deinit(self.allocator);
    }
};

// Adaptive chunk size estimator for dynamic workload balancing
pub const AdaptiveChunkEstimator = struct {
    last_chunk_size: usize = 1000,
    last_duration_ns: u64 = 0,
    target_duration_ns: u64 = 1_000_000, // 1ms target

    pub fn init() AdaptiveChunkEstimator {
        return .{};
    }

    pub fn estimateChunkSize(self: *AdaptiveChunkEstimator, total_items: usize, worker_count: usize) usize {
        if (total_items <= worker_count * 10) {
            // Small workload - one chunk per worker
            return (total_items + worker_count - 1) / worker_count;
        }

        // Adaptive sizing based on previous performance
        if (self.last_duration_ns > 0) {
            const ratio = @as(f64, @floatFromInt(self.target_duration_ns)) / @as(f64, @floatFromInt(self.last_duration_ns));
            const new_size = @as(usize, @intFromFloat(@as(f64, @floatFromInt(self.last_chunk_size)) * ratio));
            return @max(10, @min(total_items / (worker_count * 2), new_size));
        }

        // Default: aim for 2x oversubscription
        return @max(10, total_items / (worker_count * 2));
    }

    pub fn recordPerformance(self: *AdaptiveChunkEstimator, chunk_size: usize, duration_ns: u64) void {
        self.last_chunk_size = chunk_size;
        self.last_duration_ns = duration_ns;
    }
};

// Parallel pipeline support for streaming operators
pub const ParallelPipeline = struct {
    pool: *Pool,
    stages: []const PipelineStage,
    allocator: std.mem.Allocator,

    pub const PipelineStage = struct {
        name: []const u8,
        parallelism: usize,
        process: *const fn (item: *anyopaque, ctx: *anyopaque) anyerror!void,
        ctx: *anyopaque,
    };

    pub fn init(allocator: std.mem.Allocator, pool: *Pool, stages: []const PipelineStage) ParallelPipeline {
        return .{
            .pool = pool,
            .stages = stages,
            .allocator = allocator,
        };
    }

    pub fn execute(self: *ParallelPipeline, input: []const *anyopaque) !void {
        const current_batch = input;

        for (self.stages) |stage| {
            const chunk_size = self.pool.chunk_size_estimator.estimateChunkSize(current_batch.len, stage.parallelism);
            const chunk_count = (current_batch.len + chunk_size - 1) / chunk_size;

            const Context = struct {
                items: []const *anyopaque,
                stage: PipelineStage,
                chunk_size: usize,
            };

            spice_wrapper.parallelForEach(
                &self.pool.spice_pool,
                0,
                chunk_count,
                Context{ .items = current_batch, .stage = stage, .chunk_size = chunk_size },
                struct {
                    fn work(_: *spice_wrapper.Task, idx: usize, c: Context) void {
                        const start = idx * c.chunk_size;
                        const end = @min(start + c.chunk_size, c.items.len);
                        for (c.items[start..end]) |item| {
                            c.stage.process(@constCast(item), c.stage.ctx) catch {};
                        }
                    }
                }.work,
                spice_wrapper.Thresholds.forEach,
            );
        }
    }
};

// Ordered barrier helper: executes jobs sequentially (used by existing tests)
pub fn orderedBarrier(jobs: []Job) void {
    for (jobs) |j| j.func(j.ctx);
}
