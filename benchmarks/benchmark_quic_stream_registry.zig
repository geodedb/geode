const std = @import("std");
const active_stream_registry = @import("server/active_stream_registry");

// CANARY: REQ=REQ-QUIC-MUX-007; FEATURE="ActiveStreamRegistryBenchmarks"; ASPECT=ParallelThroughput; STATUS=BENCHED; BENCH=benchmark_quic_stream_registry; OWNER=server; UPDATED=2026-04-08

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
        std.Thread.sleep(10 * std.time.ns_per_us);
    }
}

fn runDuplicateRequeueBenchmark(config: BenchmarkConfig) !BenchmarkResult {
    if (config.workers == 0 or config.workers > max_benchmark_workers) {
        return error.InvalidWorkerCount;
    }

    var registry = active_stream_registry.ActiveStreamRegistry{};
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
    var thread_storage: [max_benchmark_workers]std.Thread = undefined;
    const threads = thread_storage[0..config.workers];

    for (threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, struct {
            fn run(
                registry_ptr: *active_stream_registry.ActiveStreamRegistry,
                start_ptr: *std.atomic.Value(bool),
                ready_ptr: *std.atomic.Value(u32),
                duplicate_rejections_ptr: *std.atomic.Value(u64),
                failure_ptr: *std.atomic.Value(bool),
                rounds: usize,
            ) void {
                _ = ready_ptr.fetchAdd(1, .acq_rel);
                waitForStart(start_ptr);

                for (0..rounds) |_| {
                    for (0..active_stream_registry.max_total_streams_per_connection) |i| {
                        const stream_id: u64 = @intCast(i + 1);
                        const is_new = registry_ptr.register(stream_id) catch {
                            failure_ptr.store(true, .release);
                            return;
                        };
                        if (is_new) {
                            failure_ptr.store(true, .release);
                            return;
                        }
                        _ = duplicate_rejections_ptr.fetchAdd(1, .acq_rel);
                    }
                }
            }
        }.run, .{
            &registry,
            &start,
            &ready,
            &duplicate_rejections,
            &failure,
            config.duplicate_rounds_per_worker,
        });
    }

    while (ready.load(.acquire) < config.workers) {
        std.Thread.sleep(10 * std.time.ns_per_us);
    }

    var timer = try std.time.Timer.start();
    start.store(true, .release);

    for (threads) |thread| {
        thread.join();
    }

    if (failure.load(.acquire)) return error.DuplicateBenchmarkInvariantFailed;

    const total_ops = @as(u64, @intCast(config.workers)) * active_window * config.duplicate_rounds_per_worker;
    if (duplicate_rejections.load(.acquire) != total_ops) return error.DuplicateBenchmarkCountMismatch;

    return .{
        .name = "duplicate_requeue_rejection",
        .total_ops = total_ops,
        .total_time_ns = timer.read(),
    };
}

fn runUniqueChurnBenchmark(config: BenchmarkConfig) !BenchmarkResult {
    if (config.workers == 0 or config.workers > max_benchmark_workers) {
        return error.InvalidWorkerCount;
    }

    var registry = active_stream_registry.ActiveStreamRegistry{};
    var start = std.atomic.Value(bool).init(false);
    var ready = std.atomic.Value(u32).init(0);
    var completed_cycles = std.atomic.Value(u64).init(0);
    var failure = std.atomic.Value(bool).init(false);
    var thread_storage: [max_benchmark_workers]std.Thread = undefined;
    const threads = thread_storage[0..config.workers];

    for (threads, 0..) |*thread, worker_index| {
        thread.* = try std.Thread.spawn(.{}, struct {
            fn run(
                registry_ptr: *active_stream_registry.ActiveStreamRegistry,
                start_ptr: *std.atomic.Value(bool),
                ready_ptr: *std.atomic.Value(u32),
                completed_cycles_ptr: *std.atomic.Value(u64),
                failure_ptr: *std.atomic.Value(bool),
                worker_index_value: usize,
                iterations: usize,
            ) void {
                _ = ready_ptr.fetchAdd(1, .acq_rel);
                waitForStart(start_ptr);

                const base_stream_id = @as(u64, @intCast(worker_index_value)) << 32;
                for (0..iterations) |i| {
                    const stream_id = base_stream_id | @as(u64, @intCast(i + 1));

                    const is_new = registry_ptr.register(stream_id) catch {
                        failure_ptr.store(true, .release);
                        return;
                    };
                    if (!is_new) {
                        failure_ptr.store(true, .release);
                        return;
                    }
                    if (!registry_ptr.unregister(stream_id)) {
                        failure_ptr.store(true, .release);
                        return;
                    }

                    _ = completed_cycles_ptr.fetchAdd(1, .acq_rel);
                    if ((i & 255) == 0) {
                        std.Thread.sleep(1 * std.time.ns_per_us);
                    }
                }
            }
        }.run, .{
            &registry,
            &start,
            &ready,
            &completed_cycles,
            &failure,
            worker_index,
            config.unique_iterations_per_worker,
        });
    }

    while (ready.load(.acquire) < config.workers) {
        std.Thread.sleep(10 * std.time.ns_per_us);
    }

    var timer = try std.time.Timer.start();
    start.store(true, .release);

    for (threads) |thread| {
        thread.join();
    }

    if (failure.load(.acquire)) return error.UniqueBenchmarkInvariantFailed;

    const expected_cycles = @as(u64, @intCast(config.workers)) * config.unique_iterations_per_worker;
    if (completed_cycles.load(.acquire) != expected_cycles) return error.UniqueBenchmarkCountMismatch;
    if (registry.count() != 0) return error.UniqueBenchmarkRegistryLeak;

    return .{
        .name = "unique_ownership_churn",
        .total_ops = expected_cycles * 2,
        .total_time_ns = timer.read(),
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
    const config = BenchmarkConfig{};

    std.debug.print(
        "QUIC stream registry benchmark config: workers={}, duplicate_rounds_per_worker={}, unique_iterations_per_worker={}\n",
        .{
            config.workers,
            config.duplicate_rounds_per_worker,
            config.unique_iterations_per_worker,
        },
    );

    const duplicate_result = try runDuplicateRequeueBenchmark(config);
    reportResult(config, duplicate_result);

    const unique_result = try runUniqueChurnBenchmark(config);
    reportResult(config, unique_result);
}
