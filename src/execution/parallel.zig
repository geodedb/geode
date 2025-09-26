const std = @import("std");

// Parallel execution thread pool (always enabled; feature flags removed).
// CANARY: REQ=REQ-GQL-PARALLEL-001; FEATURE="Parallel Exec"; ASPECT=ENGINE; STATUS=PARTIAL; TEST=tests/e2e_parallel_execution.zig:1; OWNER=engine; UPDATED=2025-09-26

// Legacy helpers removed; always active.

pub const JobFn = *const fn (ctx: ?*anyopaque) void;
pub const Job = struct { func: JobFn, ctx: ?*anyopaque };

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
    queue: std.ArrayListUnmanaged(Job),
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    shutdown: bool = false,
    active_jobs: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    enabled: bool = true,

    pub fn init(allocator: std.mem.Allocator, worker_count: usize) !Pool {
        var pool: Pool = .{ .allocator = allocator, .queue = .{}, .enabled = true };

        const count = if (worker_count == 0) 1 else worker_count;
        pool.threads = try allocator.alloc(std.Thread, count);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            pool.threads[i] = try std.Thread.spawn(.{}, workerMain, .{&pool});
        }
        return pool;
    }

    pub fn submit(self: *Pool, job: Job) !void {
        // Always enabled; accept job.
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.queue.append(self.allocator, job);
        self.cond.signal();
    }

    pub fn waitIdle(self: *Pool) void {
        if (!self.enabled) return; // Nothing to wait for in disabled mode
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.queue.items.len > 0 or self.active_jobs.load(.acquire) > 0) {
            self.cond.wait(&self.mutex);
        }
    }

    pub fn deinit(self: *Pool) void {
        if (self.enabled) {
            self.mutex.lock();
            self.shutdown = true;
            self.cond.broadcast();
            self.mutex.unlock();
            for (self.threads) |t| t.join();
            self.allocator.free(self.threads);
        }
        self.queue.deinit(self.allocator);
    }
};

fn workerMain(pool: *Pool) void {
    while (true) {
        pool.mutex.lock();
        while (pool.queue.items.len == 0 and !pool.shutdown) {
            pool.cond.wait(&pool.mutex);
        }
        if (pool.shutdown and pool.queue.items.len == 0) {
            pool.mutex.unlock();
            break;
        }
        // FIFO: remove first element (manual shift for unmanaged list)
        const job = pool.queue.items[0];
        // shift left
        for (pool.queue.items[1..], 0..) |it, idx| pool.queue.items[idx] = it;
        pool.queue.items.len -= 1;
        pool.active_jobs.store(pool.active_jobs.load(.acquire) + 1, .release);
        pool.mutex.unlock();
        job.func(job.ctx);
        pool.mutex.lock();
        const remaining = pool.active_jobs.load(.acquire) - 1;
        pool.active_jobs.store(remaining, .release);
        if (pool.queue.items.len == 0 and remaining == 0) pool.cond.broadcast();
        pool.mutex.unlock();
    }
}

// Ordered barrier helper: executes jobs sequentially (used by existing tests)
pub fn orderedBarrier(jobs: []Job) void {
    for (jobs) |j| j.func(j.ctx);
}
