const std = @import("std");
const pooled = @import("transport/thread_pool");

// CANARY: REQ=REQ-PERF-SPICE-003; FEATURE="ParallelWrapper"; ASPECT=CoreInterface; STATUS=IMPL; OWNER=performance; UPDATED=2026-04-12
// Shared thread-pool-backed parallel wrapper for map/reduce/forEach helpers.

pub const ThreadPool = pooled.ThreadPool;
pub const ThreadPoolConfig = pooled.ThreadPoolConfig;
pub const Worker = struct {};
pub const Task = struct {};

/// Task context type shared by the parallel wrapper APIs.
pub const TaskContext = *Task;

/// Global parallel worker pool used by the wrapper APIs.
/// CANARY: REQ=REQ-PERF-SPICE-004; FEATURE="ParallelPool"; ASPECT=GlobalPool; STATUS=IMPL; OWNER=performance; UPDATED=2026-04-12
pub const ParallelPool = struct {
    allocator: std.mem.Allocator,
    inner_pool: ?*pooled.ThreadPool = null,
    started: bool = false,
    start_failed: bool = false,
    worker_count: usize,

    pub fn init(allocator: std.mem.Allocator, worker_count: ?usize) ParallelPool {
        const auto_max: usize = 16;
        const resolved = if (worker_count) |count|
            @max(count, 1)
        else blk: {
            const cpus = std.Thread.getCpuCount() catch 4;
            break :blk @max(@min(cpus, auto_max), 1);
        };
        return .{
            .allocator = allocator,
            .worker_count = resolved,
        };
    }

    pub fn start(self: *ParallelPool) void {
        if (self.started or self.start_failed) return;

        self.inner_pool = pooled.ThreadPool.init(self.allocator, .{
            .num_threads = self.worker_count,
            .queue_capacity = @max(self.worker_count * 8, 64),
        }) catch {
            self.start_failed = true;
            return;
        };
        self.started = true;
    }

    pub fn deinit(self: *ParallelPool) void {
        if (self.inner_pool) |pool| {
            pool.deinit();
            self.inner_pool = null;
        }
        self.started = false;
        self.start_failed = false;
    }

    fn activePool(self: *ParallelPool) ?*pooled.ThreadPool {
        self.start();
        return self.inner_pool;
    }

    pub fn call(self: *ParallelPool, comptime T: type, func: anytype, arg: anytype) T {
        if (self.activePool()) |pool| {
            const fn_info = @typeInfo(@TypeOf(func)).@"fn";
            const Arg = fn_info.params[1].type orelse @compileError("parallel worker must declare an argument type");
            const typed_arg: Arg = arg;
            if (T == void) {
                const Context = struct {
                    arg: Arg,
                };
                var ctx = Context{ .arg = typed_arg };
                const handle = pool.submitTask(struct {
                    fn run(raw: *anyopaque, runtime: *pooled.TaskContext) void {
                        _ = runtime;
                        const context: *Context = @ptrCast(@alignCast(raw));
                        var task = Task{};
                        func(&task, context.arg);
                    }
                }.run, @ptrCast(&ctx), .{
                    .waitable = true,
                    .backpressure = .block,
                    .lane = .blocking,
                }) catch {
                    var task = Task{};
                    return func(&task, arg);
                };
                pool.wait(handle) catch {};
                return;
            }

            const Context = struct {
                arg: Arg,
                result: ?T = null,
            };
            var ctx = Context{ .arg = typed_arg };
            const handle = pool.submitTask(struct {
                fn run(raw: *anyopaque, runtime: *pooled.TaskContext) void {
                    _ = runtime;
                    const context: *Context = @ptrCast(@alignCast(raw));
                    var task = Task{};
                    context.result = func(&task, context.arg);
                }
            }.run, @ptrCast(&ctx), .{
                .waitable = true,
                .backpressure = .block,
                .lane = .blocking,
            }) catch {
                var task = Task{};
                return func(&task, arg);
            };
            pool.wait(handle) catch {};
            return ctx.result.?;
        }

        var task = Task{};
        return func(&task, arg);
    }

    pub fn map(
        self: *ParallelPool,
        comptime Input: type,
        comptime Output: type,
        inputs: []const Input,
        outputs: []Output,
        comptime mapFn: fn (TaskContext, Input, *Output) void,
    ) !void {
        if (inputs.len != outputs.len) return error.LengthMismatch;
        if (inputs.len == 0) return;

        if (!shouldUseParallelism(inputs.len, Thresholds.map) or self.activePool() == null) {
            for (inputs, 0..) |input, i| {
                var task = Task{};
                mapFn(&task, input, &outputs[i]);
            }
            return;
        }

        const Context = struct {
            inputs: []const Input,
            outputs: []Output,
        };

        parallelForEach(self, 0, inputs.len, Context{ .inputs = inputs, .outputs = outputs }, struct {
            fn work(task: *Task, idx: usize, ctx: Context) void {
                mapFn(task, ctx.inputs[idx], &ctx.outputs[idx]);
            }
        }.work, Thresholds.map);
    }
};

pub fn parallelMap(
    comptime T: type,
    comptime R: type,
    pool: *ParallelPool,
    items: []const T,
    comptime mapFn: fn (*Task, T) R,
    threshold: usize,
) ![]R {
    const allocator = pool.allocator;
    const results = try allocator.alloc(R, items.len);
    errdefer allocator.free(results);

    if (items.len <= threshold or pool.activePool() == null) {
        for (items, 0..) |item, i| {
            var task = Task{};
            results[i] = mapFn(&task, item);
        }
        return results;
    }

    const Context = struct {
        items: []const T,
        results: []R,
    };

    parallelForEach(pool, 0, items.len, Context{ .items = items, .results = results }, struct {
        fn work(task: *Task, idx: usize, ctx: Context) void {
            ctx.results[idx] = mapFn(task, ctx.items[idx]);
        }
    }.work, threshold);

    return results;
}

pub fn parallelReduce(
    comptime T: type,
    pool: *ParallelPool,
    items: []const T,
    initial: T,
    comptime reduceFn: fn (*Task, T, T) T,
    threshold: usize,
) T {
    if (items.len == 0) return initial;
    if (items.len == 1) {
        var task = Task{};
        return reduceFn(&task, initial, items[0]);
    }

    if (items.len <= threshold) {
        var result = initial;
        var task = Task{};
        for (items) |item| {
            result = reduceFn(&task, result, item);
        }
        return result;
    }

    const inner_pool = pool.activePool() orelse {
        var result = initial;
        var task = Task{};
        for (items) |item| {
            result = reduceFn(&task, result, item);
        }
        return result;
    };

    const desired_chunks = @max(pool.worker_count * 4, 1);
    const chunk_count = @min(items.len, desired_chunks);
    const chunk_size = @max(@divFloor(items.len + chunk_count - 1, chunk_count), 1);

    const ChunkContext = struct {
        items: []const T,
        start: usize,
        end: usize,
        out: *T,
    };

    const chunk_contexts = pool.allocator.alloc(ChunkContext, chunk_count) catch {
        var result = initial;
        var task = Task{};
        for (items) |item| {
            result = reduceFn(&task, result, item);
        }
        return result;
    };
    defer pool.allocator.free(chunk_contexts);

    const partials = pool.allocator.alloc(T, chunk_count) catch {
        var result = initial;
        var task = Task{};
        for (items) |item| {
            result = reduceFn(&task, result, item);
        }
        return result;
    };
    defer pool.allocator.free(partials);

    var wg = inner_pool.waitGroup();
    var used_chunks: usize = 0;

    const runChunk = struct {
        fn run(raw: *anyopaque, runtime: *pooled.TaskContext) void {
            _ = runtime;
            const ctx: *ChunkContext = @ptrCast(@alignCast(raw));
            var task = Task{};
            var acc = ctx.items[ctx.start];
            var idx = ctx.start + 1;
            while (idx < ctx.end) : (idx += 1) {
                acc = reduceFn(&task, acc, ctx.items[idx]);
            }
            ctx.out.* = acc;
        }
    }.run;

    for (0..chunk_count) |chunk_index| {
        const start = chunk_index * chunk_size;
        if (start >= items.len) break;
        const end = @min(start + chunk_size, items.len);

        chunk_contexts[used_chunks] = .{
            .items = items,
            .start = start,
            .end = end,
            .out = &partials[used_chunks],
        };

        _ = inner_pool.submitTask(runChunk, @ptrCast(&chunk_contexts[used_chunks]), .{
            .wait_group = &wg,
            .backpressure = .block,
            .lane = .blocking,
        }) catch {
            var task = Task{};
            var acc = items[start];
            var idx = start + 1;
            while (idx < end) : (idx += 1) {
                acc = reduceFn(&task, acc, items[idx]);
            }
            partials[used_chunks] = acc;
            used_chunks += 1;
            continue;
        };

        used_chunks += 1;
    }

    wg.wait();

    var result = initial;
    var task = Task{};
    for (partials[0..used_chunks]) |partial| {
        result = reduceFn(&task, result, partial);
    }
    return result;
}

pub fn parallelForEach(
    pool: *ParallelPool,
    start: usize,
    end: usize,
    context: anytype,
    comptime func: fn (*Task, usize, @TypeOf(context)) void,
    threshold: usize,
) void {
    if (end <= start) return;

    const len = end - start;
    if (len <= threshold) {
        var task = Task{};
        for (start..end) |idx| {
            func(&task, idx, context);
        }
        return;
    }

    const inner_pool = pool.activePool() orelse {
        var task = Task{};
        for (start..end) |idx| {
            func(&task, idx, context);
        }
        return;
    };

    const desired_chunks = @max(pool.worker_count * 4, 1);
    const chunk_count = @min(len, desired_chunks);
    const chunk_size = @max(@divFloor(len + chunk_count - 1, chunk_count), 1);

    const ChunkContext = struct {
        start: usize,
        end: usize,
        user_ctx: @TypeOf(context),
    };

    const chunk_contexts = pool.allocator.alloc(ChunkContext, chunk_count) catch {
        var task = Task{};
        for (start..end) |idx| {
            func(&task, idx, context);
        }
        return;
    };
    defer pool.allocator.free(chunk_contexts);

    var wg = inner_pool.waitGroup();
    var used_chunks: usize = 0;

    const runChunk = struct {
        fn run(raw: *anyopaque, runtime: *pooled.TaskContext) void {
            _ = runtime;
            const ctx: *ChunkContext = @ptrCast(@alignCast(raw));
            var task = Task{};
            for (ctx.start..ctx.end) |idx| {
                func(&task, idx, ctx.user_ctx);
            }
        }
    }.run;

    for (0..chunk_count) |chunk_index| {
        const range_start = start + chunk_index * chunk_size;
        if (range_start >= end) break;
        const range_end = @min(range_start + chunk_size, end);

        chunk_contexts[used_chunks] = .{
            .start = range_start,
            .end = range_end,
            .user_ctx = context,
        };

        _ = inner_pool.submitTask(runChunk, @ptrCast(&chunk_contexts[used_chunks]), .{
            .wait_group = &wg,
            .backpressure = .block,
            .lane = .blocking,
        }) catch {
            var task = Task{};
            for (range_start..range_end) |idx| {
                func(&task, idx, context);
            }
            used_chunks += 1;
            continue;
        };

        used_chunks += 1;
    }

    wg.wait();
}

pub inline fn shouldUseParallelism(item_count: usize, threshold: usize) bool {
    return item_count > threshold;
}

pub const Thresholds = struct {
    pub const map: usize = 64;
    pub const reduce: usize = 128;
    pub const forEach: usize = 32;
    pub const hnswBatchDistance: usize = 32;
    pub const cboSubsets: usize = 4;
    pub const graphStoreSegments: usize = 2;
};

test "ParallelPool init and deinit" {
    var pool = ParallelPool.init(std.testing.allocator, 2);
    pool.start();
    defer pool.deinit();
}

test "parallelMap with small input" {
    var pool = ParallelPool.init(std.testing.allocator, 2);
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
