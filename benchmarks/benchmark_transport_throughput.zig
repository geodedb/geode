const std = @import("std");

// CANARY: REQ=REQ-PERF-BENCH-001; FEATURE="ThroughputBenchmark"; ASPECT=ServerSide; STATUS=IMPL; OWNER=bench; UPDATED=2026-01-26
// GAP-0201: Server-side throughput benchmark to validate performance optimizations
// This benchmark measures actual throughput without subprocess overhead

const thread_pool = @import("transport/thread_pool");
const stream_scheduler = @import("transport/stream_scheduler");

/// Benchmark configuration
const BenchConfig = struct {
    warmup_iterations: usize = 1000,
    benchmark_iterations: usize = 100000,
    num_threads: usize = 0, // 0 = auto-detect
    report_interval: usize = 10000,
};

/// Benchmark results
const BenchResults = struct {
    name: []const u8,
    iterations: usize,
    total_time_ns: i128,
    avg_time_ns: i128,
    throughput_per_sec: u64,
    min_time_ns: i128 = std.math.maxInt(i128),
    max_time_ns: i128 = 0,
    p50_time_ns: i128 = 0,
    p99_time_ns: i128 = 0,
};

fn reportResults(results: BenchResults) void {
    std.debug.print("\n========================================\n", .{});
    std.debug.print("Benchmark: {s}\n", .{results.name});
    std.debug.print("========================================\n", .{});
    std.debug.print("Iterations:     {}\n", .{results.iterations});
    std.debug.print("Total time:     {} ms\n", .{@divFloor(results.total_time_ns, std.time.ns_per_ms)});
    std.debug.print("Avg time:       {} ns\n", .{results.avg_time_ns});
    std.debug.print("Min time:       {} ns\n", .{results.min_time_ns});
    std.debug.print("Max time:       {} ns\n", .{results.max_time_ns});
    std.debug.print("Throughput:     {} ops/sec\n", .{results.throughput_per_sec});
    std.debug.print("========================================\n\n", .{});
}

/// Benchmark thread pool work submission and execution
fn benchThreadPoolThroughput(allocator: std.mem.Allocator, config: BenchConfig) !BenchResults {
    const pool = try thread_pool.ThreadPool.init(allocator, .{
        .num_threads = if (config.num_threads == 0) std.Thread.getCpuCount() catch 4 else config.num_threads,
    });
    defer pool.deinit();

    var counter = std.atomic.Value(usize).init(0);
    const target = config.benchmark_iterations;

    const Context = struct {
        counter: *std.atomic.Value(usize),
    };

    var ctx = Context{ .counter = &counter };

    const callback = struct {
        fn call(context: *anyopaque) void {
            const c: *Context = @ptrCast(@alignCast(context));
            _ = c.counter.fetchAdd(1, .release);
        }
    }.call;

    // Warmup
    std.debug.print("Warming up ({} iterations)...\n", .{config.warmup_iterations});
    for (0..config.warmup_iterations) |_| {
        while (!pool.submit(.{
            .context = @ptrCast(&ctx),
            .callback = callback,
        })) {
            std.Thread.sleep(1 * std.time.ns_per_us);
        }
    }
    while (counter.load(.acquire) < config.warmup_iterations) {
        std.Thread.sleep(1 * std.time.ns_per_us);
    }
    counter.store(0, .release);

    // Benchmark
    std.debug.print("Running benchmark ({} iterations)...\n", .{config.benchmark_iterations});
    const start = std.time.nanoTimestamp();

    for (0..target) |i| {
        while (!pool.submit(.{
            .context = @ptrCast(&ctx),
            .callback = callback,
        })) {
            std.Thread.sleep(1 * std.time.ns_per_us);
        }

        if (i > 0 and i % config.report_interval == 0) {
            const current = counter.load(.acquire);
            const elapsed = std.time.nanoTimestamp() - start;
            const rate = @as(u64, @intCast(current)) * std.time.ns_per_s / @as(u64, @intCast(elapsed));
            std.debug.print("  Progress: {}/{} ({} ops/sec)\n", .{ current, target, rate });
        }
    }

    // Wait for completion
    while (counter.load(.acquire) < target) {
        std.Thread.sleep(1 * std.time.ns_per_us);
    }

    const end = std.time.nanoTimestamp();
    const total_time = end - start;
    const avg_time = @divFloor(total_time, @as(i128, target));
    const throughput = @as(u64, @intCast(target)) * std.time.ns_per_s / @as(u64, @intCast(total_time));

    return BenchResults{
        .name = "ThreadPool Throughput",
        .iterations = target,
        .total_time_ns = total_time,
        .avg_time_ns = avg_time,
        .throughput_per_sec = throughput,
    };
}

/// Benchmark stream scheduler performance
fn benchSchedulerThroughput(allocator: std.mem.Allocator, config: BenchConfig) !BenchResults {
    var scheduler = stream_scheduler.StreamScheduler.init(allocator);
    defer scheduler.deinit();

    // Add many streams
    const num_streams: u64 = 100;
    for (0..num_streams) |i| {
        try scheduler.addStream(@intCast(i), 1000);
    }

    var order: [100]u64 = undefined;

    // Warmup
    std.debug.print("Warming up ({} iterations)...\n", .{config.warmup_iterations});
    for (0..config.warmup_iterations) |_| {
        _ = scheduler.getScheduledStreams(&order);
    }

    // Benchmark
    std.debug.print("Running benchmark ({} iterations)...\n", .{config.benchmark_iterations});
    const start = std.time.nanoTimestamp();

    for (0..config.benchmark_iterations) |i| {
        _ = scheduler.getScheduledStreams(&order);

        if (i > 0 and i % config.report_interval == 0) {
            const elapsed = std.time.nanoTimestamp() - start;
            const rate = @as(u64, i) * std.time.ns_per_s / @as(u64, @intCast(elapsed));
            std.debug.print("  Progress: {}/{} ({} ops/sec)\n", .{ i, config.benchmark_iterations, rate });
        }
    }

    const end = std.time.nanoTimestamp();
    const total_time = end - start;
    const avg_time = @divFloor(total_time, @as(i128, config.benchmark_iterations));
    const throughput = @as(u64, config.benchmark_iterations) * std.time.ns_per_s / @as(u64, @intCast(total_time));

    return BenchResults{
        .name = "Stream Scheduler Throughput",
        .iterations = config.benchmark_iterations,
        .total_time_ns = total_time,
        .avg_time_ns = avg_time,
        .throughput_per_sec = throughput,
    };
}

/// Benchmark bounded queue operations
fn benchBoundedQueueThroughput(config: BenchConfig) BenchResults {
    const Queue = thread_pool.BoundedQueue(u64, 4096);
    var queue = Queue.init();

    // Warmup
    std.debug.print("Warming up ({} iterations)...\n", .{config.warmup_iterations});
    for (0..config.warmup_iterations) |i| {
        _ = queue.tryPush(i);
        _ = queue.tryPop();
    }

    // Benchmark push/pop cycles
    std.debug.print("Running benchmark ({} iterations)...\n", .{config.benchmark_iterations});
    const start = std.time.nanoTimestamp();

    for (0..config.benchmark_iterations) |i| {
        _ = queue.tryPush(i);
        _ = queue.tryPop();

        if (i > 0 and i % config.report_interval == 0) {
            const elapsed = std.time.nanoTimestamp() - start;
            const rate = @as(u64, i * 2) * std.time.ns_per_s / @as(u64, @intCast(elapsed)); // 2 ops per iteration
            std.debug.print("  Progress: {}/{} ({} ops/sec)\n", .{ i, config.benchmark_iterations, rate });
        }
    }

    const end = std.time.nanoTimestamp();
    const total_time = end - start;
    const total_ops = config.benchmark_iterations * 2; // push + pop
    const avg_time = @divFloor(total_time, @as(i128, total_ops));
    const throughput = @as(u64, total_ops) * std.time.ns_per_s / @as(u64, @intCast(total_time));

    return BenchResults{
        .name = "BoundedQueue Throughput (push+pop)",
        .iterations = total_ops,
        .total_time_ns = total_time,
        .avg_time_ns = avg_time,
        .throughput_per_sec = throughput,
    };
}

/// Benchmark concurrent queue with multiple producers and consumers
fn benchConcurrentQueueThroughput(allocator: std.mem.Allocator, config: BenchConfig) !BenchResults {
    const Queue = thread_pool.BoundedQueue(u64, 4096);
    var queue = Queue.init();

    const num_producers = 4;
    const num_consumers = 4;
    const items_per_producer = config.benchmark_iterations / num_producers;

    var produced = std.atomic.Value(u64).init(0);
    var consumed = std.atomic.Value(u64).init(0);
    const target = items_per_producer * num_producers;

    var threads: [num_producers + num_consumers]std.Thread = undefined;

    std.debug.print("Starting {} producers and {} consumers...\n", .{ num_producers, num_consumers });
    const start = std.time.nanoTimestamp();

    // Start producers
    for (0..num_producers) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(q: *Queue, p: *std.atomic.Value(u64), count: usize) void {
                for (0..count) |_| {
                    while (!q.tryPush(1)) {
                        std.Thread.sleep(1 * std.time.ns_per_us);
                    }
                    _ = p.fetchAdd(1, .release);
                }
            }
        }.run, .{ &queue, &produced, items_per_producer });
    }

    // Start consumers
    for (0..num_consumers) |i| {
        threads[num_producers + i] = try std.Thread.spawn(.{}, struct {
            fn run(q: *Queue, c: *std.atomic.Value(u64), t: u64) void {
                while (c.load(.acquire) < t) {
                    if (q.tryPop()) |_| {
                        _ = c.fetchAdd(1, .release);
                    } else {
                        std.Thread.sleep(1 * std.time.ns_per_us);
                    }
                }
            }
        }.run, .{ &queue, &consumed, target });
    }

    // Wait for all threads
    for (&threads) |*t| {
        t.join();
    }

    const end = std.time.nanoTimestamp();
    const total_time = end - start;
    const total_ops = target * 2; // push + pop
    const avg_time = @divFloor(total_time, @as(i128, total_ops));
    const throughput = @as(u64, total_ops) * std.time.ns_per_s / @as(u64, @intCast(total_time));

    _ = allocator;

    return BenchResults{
        .name = "Concurrent Queue Throughput (4P/4C)",
        .iterations = total_ops,
        .total_time_ns = total_time,
        .avg_time_ns = avg_time,
        .throughput_per_sec = throughput,
    };
}

/// Benchmark adaptive backoff behavior
fn benchAdaptiveBackoff(config: BenchConfig) BenchResults {
    const max_idle_before_sleep: u32 = 10;
    const min_sleep_us: u64 = 10;
    const max_sleep_us: u64 = 100;

    var idle_iterations: u32 = 0;
    var total_sleep_us: u64 = 0;

    // Simulate the adaptive backoff pattern
    std.debug.print("Running benchmark ({} iterations)...\n", .{config.benchmark_iterations});
    const start = std.time.nanoTimestamp();

    for (0..config.benchmark_iterations) |i| {
        // Simulate alternating idle and active periods
        if (i % 100 < 50) {
            // Active period - no sleep
            idle_iterations = 0;
        } else {
            // Idle period - use backoff
            idle_iterations += 1;
            if (idle_iterations > max_idle_before_sleep) {
                const backoff = @min(idle_iterations - max_idle_before_sleep, 4);
                const sleep_us = @min(min_sleep_us << @intCast(backoff), max_sleep_us);
                total_sleep_us += sleep_us;
                // Don't actually sleep in benchmark - just count
            }
        }
    }

    const end = std.time.nanoTimestamp();
    const total_time = end - start;
    const avg_time = @divFloor(total_time, @as(i128, config.benchmark_iterations));
    const throughput = @as(u64, config.benchmark_iterations) * std.time.ns_per_s / @as(u64, @intCast(total_time));

    std.debug.print("Total simulated sleep: {} us\n", .{total_sleep_us});

    return BenchResults{
        .name = "Adaptive Backoff Decision Overhead",
        .iterations = config.benchmark_iterations,
        .total_time_ns = total_time,
        .avg_time_ns = avg_time,
        .throughput_per_sec = throughput,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║     GEODE TRANSPORT LAYER THROUGHPUT BENCHMARKS              ║\n", .{});
    std.debug.print("║     GAP-0201: Performance Optimizations Validation           ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    const config = BenchConfig{
        .warmup_iterations = 1000,
        .benchmark_iterations = 100000,
        .report_interval = 25000,
    };

    // Run all benchmarks
    std.debug.print("Configuration:\n", .{});
    std.debug.print("  Warmup iterations:    {}\n", .{config.warmup_iterations});
    std.debug.print("  Benchmark iterations: {}\n", .{config.benchmark_iterations});
    std.debug.print("  CPU count:            {}\n", .{std.Thread.getCpuCount() catch 0});
    std.debug.print("\n", .{});

    // 1. Thread pool throughput
    std.debug.print("--- Thread Pool Throughput ---\n", .{});
    const pool_results = try benchThreadPoolThroughput(allocator, config);
    reportResults(pool_results);

    // 2. Stream scheduler throughput
    std.debug.print("--- Stream Scheduler Throughput ---\n", .{});
    const scheduler_results = try benchSchedulerThroughput(allocator, config);
    reportResults(scheduler_results);

    // 3. Bounded queue single-threaded
    std.debug.print("--- Bounded Queue (Single-threaded) ---\n", .{});
    const queue_results = benchBoundedQueueThroughput(config);
    reportResults(queue_results);

    // 4. Concurrent queue
    std.debug.print("--- Concurrent Queue (Multi-threaded) ---\n", .{});
    const concurrent_results = try benchConcurrentQueueThroughput(allocator, config);
    reportResults(concurrent_results);

    // 5. Adaptive backoff overhead
    std.debug.print("--- Adaptive Backoff Overhead ---\n", .{});
    const backoff_results = benchAdaptiveBackoff(config);
    reportResults(backoff_results);

    // Summary
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                     BENCHMARK SUMMARY                        ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║ Thread Pool:          {:>10} ops/sec                   ║\n", .{pool_results.throughput_per_sec});
    std.debug.print("║ Stream Scheduler:     {:>10} ops/sec                   ║\n", .{scheduler_results.throughput_per_sec});
    std.debug.print("║ Bounded Queue:        {:>10} ops/sec                   ║\n", .{queue_results.throughput_per_sec});
    std.debug.print("║ Concurrent Queue:     {:>10} ops/sec                   ║\n", .{concurrent_results.throughput_per_sec});
    std.debug.print("║ Adaptive Backoff:     {:>10} ops/sec                   ║\n", .{backoff_results.throughput_per_sec});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Verify minimum performance requirements
    const min_pool_throughput: u64 = 10000; // 10K ops/sec minimum
    const min_scheduler_throughput: u64 = 100000; // 100K ops/sec minimum
    const min_queue_throughput: u64 = 1000000; // 1M ops/sec minimum

    if (pool_results.throughput_per_sec < min_pool_throughput) {
        std.debug.print("WARNING: Thread pool throughput below minimum ({} < {})\n", .{ pool_results.throughput_per_sec, min_pool_throughput });
    }
    if (scheduler_results.throughput_per_sec < min_scheduler_throughput) {
        std.debug.print("WARNING: Scheduler throughput below minimum ({} < {})\n", .{ scheduler_results.throughput_per_sec, min_scheduler_throughput });
    }
    if (queue_results.throughput_per_sec < min_queue_throughput) {
        std.debug.print("WARNING: Queue throughput below minimum ({} < {})\n", .{ queue_results.throughput_per_sec, min_queue_throughput });
    }

    std.debug.print("Benchmark complete.\n", .{});
}

test "benchmark_transport_throughput: smoke test" {
    // Quick smoke test to verify benchmarks run
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = BenchConfig{
        .warmup_iterations = 10,
        .benchmark_iterations = 100,
        .report_interval = 50,
    };

    _ = try benchThreadPoolThroughput(allocator, config);
    _ = try benchSchedulerThroughput(allocator, config);
    _ = benchBoundedQueueThroughput(config);
    _ = benchAdaptiveBackoff(config);
}
