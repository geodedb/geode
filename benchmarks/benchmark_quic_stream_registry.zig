const std = @import("std");
const active_stream_registry = @import("server/active_stream_registry");
const thread_pool = @import("transport/thread_pool");

// CANARY: REQ=REQ-QUIC-MUX-007; FEATURE="ActiveStreamRegistryBenchmarks"; ASPECT=ParallelThroughput; STATUS=BENCHED; BENCH=benchmark_quic_stream_registry; OWNER=server; UPDATED=2026-04-08

// Zig 0.16 compat: std.time.Timer removed; use clock_gettime(MONOTONIC).
fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// Zig 0.16 compat: std.Thread.sleep removed; use raw nanosleep syscall.
fn sleepNs(ns: u64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.os.linux.nanosleep(&req, null);
}

const BenchmarkConfig = struct {
    workers: usize = 8,
    duplicate_rounds_per_worker: usize = 20_000,
    unique_iterations_per_worker: usize = 100_000,
};

const max_benchmark_workers = 64;

const BenchmarkResult = struct {
    name: []const u8,
    total_ops: u64,
    total_time_ns: u64,

    fn avgNsPerOp(self: BenchmarkResult) u64 {
        return if (self.total_ops == 0) 0 else self.total_time_ns / self.total_ops;
    }

    fn throughputOpsPerSec(self: BenchmarkResult) u64 {
        return if (self.total_time_ns == 0) 0 else self.total_ops * std.time.ns_per_s / self.total_time_ns;
    }
};

fn waitForStart(start: *std.atomic.Value(bool)) void {
    while (!start.load(.acquire)) {
        sleepNs(10 * std.time.ns_per_us);
    }
}

fn runDuplicateRequeueBenchmark(allocator: std.mem.Allocator, config: BenchmarkConfig) !BenchmarkResult {
    if (config.workers == 0 or config.workers > max_benchmark_workers) {
        return error.InvalidWorkerCount;
    }

    var registry = active_stream_registry.ActiveStreamRegistry{};
    const pool = try thread_pool.ThreadPool.init(allocator, .{
        .num_threads = config.workers + 1, // +1 for the reserved blocking-lane worker (wrapper sets blocking_workers=1)
        .queue_capacity = config.workers,
    });
    defer pool.deinit();
    const active_window = active_stream_registry.max_total_streams_per_connection;

    for (0..active_window) |i| {
        const stream_id: u64 = @intCast(i + 1);
        const is_new = try registry.register(stream_id);
        if (!is_new) return error.DuplicateSetupFailed;
    }

    var start = std.atomic.Value(bool).init(false);
    var ready = std.atomic.Value(u32).init(0);
    var duplicate_rejections = std.atomic.Value(u64).init(0);
    var failure = std.atomic.Value(bool).init(false);
    const WorkerContext = struct {
        registry: *active_stream_registry.ActiveStreamRegistry,
        start: *std.atomic.Value(bool),
        ready: *std.atomic.Value(u32),
        duplicate_rejections: *std.atomic.Value(u64),
        failure: *std.atomic.Value(bool),
        rounds: usize,
    };
    var worker_contexts: [max_benchmark_workers]WorkerContext = undefined;
    var handles: [max_benchmark_workers]thread_pool.TaskHandle = undefined;

    for (0..config.workers) |idx| {
        worker_contexts[idx] = .{
            .registry = &registry,
            .start = &start,
            .ready = &ready,
            .duplicate_rejections = &duplicate_rejections,
            .failure = &failure,
            .rounds = config.duplicate_rounds_per_worker,
        };
        handles[idx] = try pool.submitTask(struct {
            fn run(ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
                _ = runtime;
                const context: *WorkerContext = @ptrCast(@alignCast(ctx));
                _ = context.ready.fetchAdd(1, .acq_rel);
                waitForStart(context.start);

                for (0..context.rounds) |_| {
                    for (0..active_stream_registry.max_total_streams_per_connection) |i| {
                        const stream_id: u64 = @intCast(i + 1);
                        const is_new = context.registry.register(stream_id) catch {
                            context.failure.store(true, .release);
                            return;
                        };
                        if (is_new) {
                            context.failure.store(true, .release);
                            return;
                        }
                        _ = context.duplicate_rejections.fetchAdd(1, .acq_rel);
                    }
                }
            }
        }.run, @ptrCast(&worker_contexts[idx]), .{
            .lane = .default, // reverted from .blocking — the wrapper reserves only 1 worker for .blocking lane which deadlocks the N-way barrier pattern in this bench
            .backpressure = .block,
            .waitable = true,
        });
    }

    while (ready.load(.acquire) < config.workers) {
        sleepNs(10 * std.time.ns_per_us);
    }

    const timer_start_ns = nowNs();
    start.store(true, .release);

    for (handles[0..config.workers]) |handle| {
        try pool.wait(handle);
    }

    if (failure.load(.acquire)) return error.DuplicateBenchmarkInvariantFailed;

    const total_ops = @as(u64, @intCast(config.workers)) * active_window * config.duplicate_rounds_per_worker;
    if (duplicate_rejections.load(.acquire) != total_ops) return error.DuplicateBenchmarkCountMismatch;

    return .{
        .name = "duplicate_requeue_rejection",
        .total_ops = total_ops,
        .total_time_ns = nowNs() - timer_start_ns,
    };
}

fn runUniqueChurnBenchmark(allocator: std.mem.Allocator, config: BenchmarkConfig) !BenchmarkResult {
    if (config.workers == 0 or config.workers > max_benchmark_workers) {
        return error.InvalidWorkerCount;
    }

    var registry = active_stream_registry.ActiveStreamRegistry{};
    const pool = try thread_pool.ThreadPool.init(allocator, .{
        .num_threads = config.workers + 1, // +1 for the reserved blocking-lane worker (wrapper sets blocking_workers=1)
        .queue_capacity = config.workers,
    });
    defer pool.deinit();
    var start = std.atomic.Value(bool).init(false);
    var ready = std.atomic.Value(u32).init(0);
    var completed_cycles = std.atomic.Value(u64).init(0);
    var failure = std.atomic.Value(bool).init(false);
    const WorkerContext = struct {
        registry: *active_stream_registry.ActiveStreamRegistry,
        start: *std.atomic.Value(bool),
        ready: *std.atomic.Value(u32),
        completed_cycles: *std.atomic.Value(u64),
        failure: *std.atomic.Value(bool),
        worker_index: usize,
        iterations: usize,
    };
    var worker_contexts: [max_benchmark_workers]WorkerContext = undefined;
    var handles: [max_benchmark_workers]thread_pool.TaskHandle = undefined;

    for (0..config.workers) |worker_index| {
        worker_contexts[worker_index] = .{
            .registry = &registry,
            .start = &start,
            .ready = &ready,
            .completed_cycles = &completed_cycles,
            .failure = &failure,
            .worker_index = worker_index,
            .iterations = config.unique_iterations_per_worker,
        };
        handles[worker_index] = try pool.submitTask(struct {
            fn run(ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
                _ = runtime;
                const context: *WorkerContext = @ptrCast(@alignCast(ctx));
                _ = context.ready.fetchAdd(1, .acq_rel);
                waitForStart(context.start);

                const base_stream_id = @as(u64, @intCast(context.worker_index)) << 32;
                for (0..context.iterations) |i| {
                    const stream_id = base_stream_id | @as(u64, @intCast(i + 1));

                    const is_new = context.registry.register(stream_id) catch {
                        context.failure.store(true, .release);
                        return;
                    };
                    if (!is_new) {
                        context.failure.store(true, .release);
                        return;
                    }
                    if (!context.registry.unregister(stream_id)) {
                        context.failure.store(true, .release);
                        return;
                    }

                    _ = context.completed_cycles.fetchAdd(1, .acq_rel);
                    if ((i & 255) == 0) {
                        sleepNs(1 * std.time.ns_per_us);
                    }
                }
            }
        }.run, @ptrCast(&worker_contexts[worker_index]), .{
            .lane = .default, // reverted from .blocking — the wrapper reserves only 1 worker for .blocking lane which deadlocks the N-way barrier pattern in this bench
            .backpressure = .block,
            .waitable = true,
        });
    }

    while (ready.load(.acquire) < config.workers) {
        sleepNs(10 * std.time.ns_per_us);
    }

    const timer_start_ns = nowNs();
    start.store(true, .release);

    for (handles[0..config.workers]) |handle| {
        try pool.wait(handle);
    }

    if (failure.load(.acquire)) return error.UniqueBenchmarkInvariantFailed;

    const expected_cycles = @as(u64, @intCast(config.workers)) * config.unique_iterations_per_worker;
    if (completed_cycles.load(.acquire) != expected_cycles) return error.UniqueBenchmarkCountMismatch;
    if (registry.count() != 0) return error.UniqueBenchmarkRegistryLeak;

    return .{
        .name = "unique_ownership_churn",
        .total_ops = expected_cycles * 2,
        .total_time_ns = nowNs() - timer_start_ns,
    };
}

fn reportResult(config: BenchmarkConfig, result: BenchmarkResult) void {
    std.debug.print(
        "{s}: workers={}, ops={}, total_ms={}, avg_ns_per_op={}, throughput_ops_per_sec={}\n",
        .{
            result.name,
            config.workers,
            result.total_ops,
            @divFloor(result.total_time_ns, std.time.ns_per_ms),
            result.avgNsPerOp(),
            result.throughputOpsPerSec(),
        },
    );
    std.debug.print(
        "{{\"benchmark\":\"{s}\",\"workers\":{},\"ops\":{},\"total_time_ns\":{},\"avg_ns_per_op\":{},\"throughput_ops_per_sec\":{}}}\n",
        .{
            result.name,
            config.workers,
            result.total_ops,
            result.total_time_ns,
            result.avgNsPerOp(),
            result.throughputOpsPerSec(),
        },
    );
}

pub fn main() !void {
    // Zig 0.16 compat: GeneralPurposeAllocator renamed to DebugAllocator.
    var dbg_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg_alloc.deinit();
    const allocator: std.mem.Allocator = if (@import("builtin").mode == .Debug)
        dbg_alloc.allocator()
    else
        std.heap.smp_allocator;
    const config = BenchmarkConfig{};

    std.debug.print(
        "QUIC stream registry benchmark config: workers={}, duplicate_rounds_per_worker={}, unique_iterations_per_worker={}\n",
        .{
            config.workers,
            config.duplicate_rounds_per_worker,
            config.unique_iterations_per_worker,
        },
    );

    const duplicate_result = try runDuplicateRequeueBenchmark(allocator, config);
    reportResult(config, duplicate_result);

    const unique_result = try runUniqueChurnBenchmark(allocator, config);
    reportResult(config, unique_result);
}
