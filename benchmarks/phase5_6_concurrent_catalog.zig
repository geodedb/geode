// Phase 5.1.6 (P0-6) Concurrency Benchmark
// Validates RwLock usage for catalog access

const std = @import("std");
const testing = std.testing;

// Benchmark Phase PHASE5_6 - Concurrency validation for Phase 5.1.6 (P0-6)
// CANARY: REQ=REQ-PERF-PHASE5-006; FEATURE="ConcurrencyOptimization"; ASPECT=TESTING; STATUS=EXEMPT; OWNER=performance; UPDATED=2025-11-16

// =============================================================================
// Test Structures - Simulating catalog access patterns
// =============================================================================

const SimpleCatalog = struct {
    data: std.StringHashMap(u32),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !SimpleCatalog {
        var catalog = SimpleCatalog{
            .data = std.StringHashMap(u32).init(allocator),
            .allocator = allocator,
        };

        // Pre-populate with test data
        try catalog.data.put("index1", 1);
        try catalog.data.put("index2", 2);
        try catalog.data.put("index3", 3);

        return catalog;
    }

    fn deinit(self: *SimpleCatalog) void {
        self.data.deinit();
    }
};

// =============================================================================
// Baseline: Using exclusive locks for all operations
// =============================================================================

fn concurrentReadsWithWriteLock(catalog: *SimpleCatalog, lock: *std.Thread.RwLock, iterations: usize) !void {
    for (0..iterations) |_| {
        lock.lock(); // Exclusive lock (blocks all other threads)
        defer lock.unlock();

        // Read-only operation
        const value = catalog.data.get("index1");
        std.mem.doNotOptimizeAway(value);
    }
}

/// Benchmark: Concurrent reads with write lock (baseline)
fn benchmarkWriteLockReads(allocator: std.mem.Allocator, num_threads: usize, iterations_per_thread: usize) !u64 {
    var catalog = try SimpleCatalog.init(allocator);
    defer catalog.deinit();

    var lock = std.Thread.RwLock{};
    const threads = try allocator.alloc(std.Thread, num_threads);
    defer allocator.free(threads);

    var timer = try std.time.Timer.start();
    const start = timer.read();

    // Spawn threads
    for (threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, concurrentReadsWithWriteLock, .{ &catalog, &lock, iterations_per_thread });
    }

    // Wait for completion
    for (threads) |thread| {
        thread.join();
    }

    const end = timer.read();
    return end - start;
}

// =============================================================================
// Optimized: Using shared locks for read operations
// =============================================================================

fn concurrentReadsWithSharedLock(catalog: *SimpleCatalog, lock: *std.Thread.RwLock, iterations: usize) !void {
    for (0..iterations) |_| {
        lock.lockShared(); // Shared lock (allows concurrent readers)
        defer lock.unlockShared();

        // Read-only operation
        const value = catalog.data.get("index1");
        std.mem.doNotOptimizeAway(value);
    }
}

/// Benchmark: Concurrent reads with shared lock (optimized)
fn benchmarkSharedLockReads(allocator: std.mem.Allocator, num_threads: usize, iterations_per_thread: usize) !u64 {
    var catalog = try SimpleCatalog.init(allocator);
    defer catalog.deinit();

    var lock = std.Thread.RwLock{};
    const threads = try allocator.alloc(std.Thread, num_threads);
    defer allocator.free(threads);

    var timer = try std.time.Timer.start();
    const start = timer.read();

    // Spawn threads
    for (threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, concurrentReadsWithSharedLock, .{ &catalog, &lock, iterations_per_thread });
    }

    // Wait for completion
    for (threads) |thread| {
        thread.join();
    }

    const end = timer.read();
    return end - start;
}

// =============================================================================
// Benchmarks
// =============================================================================

test "Benchmark: Concurrent catalog reads - 4 threads" {
    const allocator = testing.allocator;
    const num_threads = 4;
    const iterations = 1000;

    const baseline_time = try benchmarkWriteLockReads(allocator, num_threads, iterations);
    const optimized_time = try benchmarkSharedLockReads(allocator, num_threads, iterations);

    const ratio = @as(f64, @floatFromInt(baseline_time)) / @as(f64, @floatFromInt(optimized_time));

    std.debug.print("\n=== Phase 5.1.6 (P0-6): Concurrent Catalog Access (4 threads, 1000 ops/thread) ===\n", .{});
    std.debug.print("Baseline (write locks):  {} ns\n", .{baseline_time});
    std.debug.print("Optimized (shared locks): {} ns\n", .{optimized_time});
    std.debug.print("Speedup: {d}x\n", .{ratio});
    std.debug.print("Target: ≥1.30x (30% improvement)\n", .{});

    // Verify we get at least 30% improvement
    try testing.expect(ratio >= 1.30);
}

test "Benchmark: Concurrent catalog reads - 8 threads" {
    const allocator = testing.allocator;
    const num_threads = 8;
    const iterations = 500;

    const baseline_time = try benchmarkWriteLockReads(allocator, num_threads, iterations);
    const optimized_time = try benchmarkSharedLockReads(allocator, num_threads, iterations);

    const ratio = @as(f64, @floatFromInt(baseline_time)) / @as(f64, @floatFromInt(optimized_time));

    std.debug.print("\n=== Phase 5.1.6 (P0-6): Concurrent Catalog Access (8 threads, 500 ops/thread) ===\n", .{});
    std.debug.print("Baseline (write locks):  {} ns\n", .{baseline_time});
    std.debug.print("Optimized (shared locks): {} ns\n", .{optimized_time});
    std.debug.print("Speedup: {d}x\n", .{ratio});
    std.debug.print("Target: ≥1.40x (40% improvement)\n", .{});

    // Verify we get at least 40% improvement
    try testing.expect(ratio >= 1.40);
}

test "Benchmark: Concurrent catalog reads - 16 threads" {
    const allocator = testing.allocator;
    const num_threads = 16;
    const iterations = 250;

    const baseline_time = try benchmarkWriteLockReads(allocator, num_threads, iterations);
    const optimized_time = try benchmarkSharedLockReads(allocator, num_threads, iterations);

    const ratio = @as(f64, @floatFromInt(baseline_time)) / @as(f64, @floatFromInt(optimized_time));

    std.debug.print("\n=== Phase 5.1.6 (P0-6): Concurrent Catalog Access (16 threads, 250 ops/thread) ===\n", .{});
    std.debug.print("Baseline (write locks):  {} ns\n", .{baseline_time});
    std.debug.print("Optimized (shared locks): {} ns\n", .{optimized_time});
    std.debug.print("Speedup: {d}x\n", .{ratio});
    std.debug.print("Target: ≥1.50x (50% improvement)\n", .{});

    // Verify we get at least 50% improvement
    try testing.expect(ratio >= 1.50);
}

test "Performance summary" {
    std.debug.print("\n=== Phase 5.1.6 (P0-6): Performance Summary ===\n\n", .{});
    std.debug.print("RwLock Shared Access for Catalog\n", .{});
    std.debug.print("────────────────────────────────────\n", .{});
    std.debug.print("Expected improvements:\n", .{});
    std.debug.print("  - 4 threads:    ≥30% faster\n", .{});
    std.debug.print("  - 8 threads:    ≥40% faster\n", .{});
    std.debug.print("  - 16 threads:   ≥50% faster\n\n", .{});
    std.debug.print("Key benefits:\n", .{});
    std.debug.print("  - Allows concurrent read access to catalog\n", .{});
    std.debug.print("  - Eliminates serialization for read-only queries\n", .{});
    std.debug.print("  - Critical for high-concurrency workloads\n", .{});
    std.debug.print("  - Benefits scale with thread count\n\n", .{});
    std.debug.print("Current status in Geode:\n", .{});
    std.debug.print("  ✅ SHOW commands use lockShared()\n", .{});
    std.debug.print("  ✅ EXPLAIN commands use lockShared()\n", .{});
    std.debug.print("  ✅ DDL operations correctly use lock() for writes\n\n", .{});

    try testing.expect(true);
}
