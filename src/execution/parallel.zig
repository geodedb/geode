const std = @import("std");

// Parallel execution thread pool with work-stealing scheduler
// CANARY: REQ=REQ-GQL-PARALLEL-001; FEATURE="Parallel Exec"; ASPECT=ENGINE; STATUS=TESTED; TEST=tests/e2e_parallel_execution.zig:1; BENCH=tests/benchmark_parallel_expand_mem_perf.zig:1; OWNER=engine; UPDATED=2025-09-26

// Work-stealing scheduler with adaptive chunk sizing and pipelined parallel joins

pub const JobFn = *const fn (ctx: ?*anyopaque) void;
pub const Job = struct { 
    func: JobFn, 
    ctx: ?*anyopaque,
    priority: u8 = 0,  // 0=normal, 1=high
    chunk_size: ?usize = null,  // adaptive chunk size hint
};

// Work-stealing deque for each worker
pub const WorkStealingDeque = struct {
    jobs: std.ArrayListUnmanaged(Job),
    mutex: std.Thread.Mutex = .{},
    top: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    bottom: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    
    pub fn push(self: *WorkStealingDeque, allocator: std.mem.Allocator, job: Job) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.jobs.append(allocator, job);
        _ = self.bottom.fetchAdd(1, .release);
    }
    
    pub fn pop(self: *WorkStealingDeque) ?Job {
        const b = self.bottom.fetchSub(1, .acquire) - 1;
        const t = self.top.load(.acquire);
        
        if (t <= b) {
            // Non-empty
            if (t == b) {
                // Last element - need CAS
                if (!self.top.cmpxchgWeak(t, t + 1, .acq_rel, .acquire)) {
                    // Failed race
                    _ = self.bottom.fetchAdd(1, .release);
                    return null;
                }
            }
            self.mutex.lock();
            defer self.mutex.unlock();
            if (b >= 0 and b < self.jobs.items.len) {
                return self.jobs.items[@intCast(b)];
            }
        } else {
            // Empty
            _ = self.bottom.fetchAdd(1, .release);
        }
        return null;
    }
    
    pub fn steal(self: *WorkStealingDeque) ?Job {
        const t = self.top.load(.acquire);
        const b = self.bottom.load(.acquire);
        
        if (t < b) {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            // Try to steal from top
            if (self.top.cmpxchgWeak(t, t + 1, .acq_rel, .acquire)) {
                if (t >= 0 and t < self.jobs.items.len) {
                    return self.jobs.items[@intCast(t)];
                }
            }
        }
        return null;
    }
    
    pub fn deinit(self: *WorkStealingDeque, allocator: std.mem.Allocator) void {
        self.jobs.deinit(allocator);
    }
};

// Deterministic parallel map: splits input slice into chunks, schedules jobs that
// apply workerFn(element_index, element_ptr, user_ctx) and stores results in order.
// Falls back to serial if pool disabled. Caller owns result allocation lifecycle.
pub const MapResult = struct { items: []u8 }; // placeholder generic-less container

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
    if (!pool.enabled) {
        var i: usize = 0;
        while (i < src_count) : (i += 1) {
            worker_fn(i, out[i * elem_size .. i * elem_size + elem_size], user_ctx);
        }
        return MapResult{ .items = out };
    }
    // Parallel path
    const JobCtx = struct {
        worker_fn: *const fn (usize, []u8, ?*anyopaque) void,
        out: []u8,
        elem_size: usize,
        user_ctx: ?*anyopaque,
        index: usize,
    };
    var job_buf = try allocator.alloc(JobCtx, src_count);
    defer allocator.free(job_buf);
    var i: usize = 0;
    while (i < src_count) : (i += 1) {
        job_buf[i] = JobCtx{ .worker_fn = worker_fn, .out = out, .elem_size = elem_size, .user_ctx = user_ctx, .index = i };
        const run = struct {
            fn go(ctx: ?*anyopaque) void {
                const jc: *JobCtx = @ptrCast(@alignCast(ctx.?));
                const start = jc.index * jc.elem_size;
                jc.worker_fn(jc.index, jc.out[start .. start + jc.elem_size], jc.user_ctx);
            }
        }.go;
        try pool.submit(.{ .func = run, .ctx = &job_buf[i] });
    }
    pool.waitIdle();
    return MapResult{ .items = out };
}

pub const Pool = struct {
    allocator: std.mem.Allocator,
    threads: []std.Thread = &[_]std.Thread{},
    worker_queues: []WorkStealingDeque,
    global_queue: std.ArrayListUnmanaged(Job),
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    shutdown: bool = false,
    active_jobs: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    enabled: bool = true,
    worker_count: usize,
    chunk_size_estimator: AdaptiveChunkEstimator,

    pub fn init(allocator: std.mem.Allocator, worker_count: usize) !Pool {
        const count = if (worker_count == 0) std.Thread.getCpuCount() catch 4 else worker_count;
        
        var pool: Pool = .{ 
            .allocator = allocator, 
            .global_queue = .{}, 
            .enabled = true,
            .worker_count = count,
            .worker_queues = try allocator.alloc(WorkStealingDeque, count),
            .threads = try allocator.alloc(std.Thread, count),
            .chunk_size_estimator = AdaptiveChunkEstimator.init(),
        };
        
        // Initialize work-stealing deques
        for (pool.worker_queues) |*queue| {
            queue.* = .{ .jobs = .{} };
        }
        
        // Start worker threads
        var i: usize = 0;
        while (i < count) : (i += 1) {
            pool.threads[i] = try std.Thread.spawn(.{}, workerMainSteal, .{ &pool, i });
        }
        return pool;
    }

    pub fn submit(self: *Pool, job: Job) !void {
        if (!self.enabled) return;
        
        // Try to submit to least loaded worker queue
        var min_size: usize = std.math.maxInt(usize);
        var target_worker: usize = 0;
        
        for (self.worker_queues, 0..) |*queue, i| {
            const size = queue.jobs.items.len;
            if (size < min_size) {
                min_size = size;
                target_worker = i;
            }
        }
        
        // Submit to target worker's queue
        try self.worker_queues[target_worker].push(self.allocator, job);
        self.cond.signal();
    }
    
    pub fn submitBatch(self: *Pool, jobs: []const Job) !void {
        if (!self.enabled or jobs.len == 0) return;
        
        // Distribute jobs across workers for load balancing
        const jobs_per_worker = (jobs.len + self.worker_count - 1) / self.worker_count;
        
        for (self.worker_queues, 0..) |*queue, i| {
            const start = i * jobs_per_worker;
            if (start >= jobs.len) break;
            
            const end = @min(start + jobs_per_worker, jobs.len);
            for (jobs[start..end]) |job| {
                try queue.push(self.allocator, job);
            }
        }
        
        self.cond.broadcast();
    }

    pub fn waitIdle(self: *Pool) void {
        if (!self.enabled) return;
        
        while (true) {
            var has_work = false;
            
            // Check all worker queues
            for (self.worker_queues) |*queue| {
                if (queue.jobs.items.len > 0) {
                    has_work = true;
                    break;
                }
            }
            
            // Check active jobs
            if (self.active_jobs.load(.acquire) > 0) {
                has_work = true;
            }
            
            if (!has_work) break;
            
            self.mutex.lock();
            self.cond.wait(&self.mutex);
            self.mutex.unlock();
        }
    }

    pub fn deinit(self: *Pool) void {
        if (self.enabled) {
            self.mutex.lock();
            self.shutdown = true;
            self.cond.broadcast();
            self.mutex.unlock();
            
            for (self.threads) |t| t.join();
            
            for (self.worker_queues) |*queue| {
                queue.deinit(self.allocator);
            }
            
            self.allocator.free(self.worker_queues);
            self.allocator.free(self.threads);
        }
        self.global_queue.deinit(self.allocator);
    }
};

fn workerMainSteal(args: struct { pool: *Pool, worker_id: usize }) void {
    const pool = args.pool;
    const worker_id = args.worker_id;
    var rng = std.rand.DefaultPrng.init(@intCast(std.time.timestamp() + worker_id));
    const random = rng.random();
    
    while (!pool.shutdown) {
        var job: ?Job = null;
        
        // Try to get job from own queue first
        job = pool.worker_queues[worker_id].pop();
        
        // If no job, try work stealing
        if (job == null) {
            // Random victim selection for work stealing
            const victim = random.intRangeAtMost(usize, 0, pool.worker_count - 1);
            if (victim != worker_id) {
                job = pool.worker_queues[victim].steal();
            }
        }
        
        // If still no job, check global queue
        if (job == null) {
            pool.mutex.lock();
            if (pool.global_queue.items.len > 0) {
                job = pool.global_queue.items[0];
                for (pool.global_queue.items[1..], 0..) |it, idx| {
                    pool.global_queue.items[idx] = it;
                }
                pool.global_queue.items.len -= 1;
            }
            pool.mutex.unlock();
        }
        
        if (job) |j| {
            _ = pool.active_jobs.fetchAdd(1, .release);
            j.func(j.ctx);
            _ = pool.active_jobs.fetchSub(1, .release);
            pool.cond.signal();
        } else {
            // No work available, wait briefly
            pool.mutex.lock();
            _ = pool.cond.timedWait(&pool.mutex, 1_000_000) catch {}; // 1ms timeout
            pool.mutex.unlock();
        }
    }
}

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
        var current_batch = input;
        
        for (self.stages) |stage| {
            const chunk_size = self.pool.chunk_size_estimator.estimateChunkSize(current_batch.len, stage.parallelism);
            var jobs = try self.allocator.alloc(Job, (current_batch.len + chunk_size - 1) / chunk_size);
            defer self.allocator.free(jobs);
            
            var job_idx: usize = 0;
            var i: usize = 0;
            while (i < current_batch.len) : (i += chunk_size) {
                const end = @min(i + chunk_size, current_batch.len);
                const ctx = struct {
                    items: []const *anyopaque,
                    stage: PipelineStage,
                    
                    pub fn run(c: ?*anyopaque) void {
                        const self_ctx = @as(*@This(), @ptrCast(@alignCast(c.?)));
                        for (self_ctx.items) |item| {
                            self_ctx.stage.process(@constCast(item), self_ctx.stage.ctx) catch {};
                        }
                    }
                }{ .items = current_batch[i..end], .stage = stage };
                
                jobs[job_idx] = .{
                    .func = ctx.run,
                    .ctx = @ptrCast(@constCast(&ctx)),
                    .priority = 0,
                    .chunk_size = chunk_size,
                };
                job_idx += 1;
            }
            
            try self.pool.submitBatch(jobs[0..job_idx]);
            self.pool.waitIdle();
        }
    }
};

// Ordered barrier helper: executes jobs sequentially (used by existing tests)
pub fn orderedBarrier(jobs: []Job) void {
    for (jobs) |j| j.func(j.ctx);
}
