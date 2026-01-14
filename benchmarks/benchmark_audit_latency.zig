const std = @import("std");
const Allocator = std.mem.Allocator;

// CANARY: REQ=REQ-BENCHMARK-AUDIT-001; FEATURE="Audit Latency Benchmark"; ASPECT=Performance; STATUS=IMPL; OWNER=monitoring; UPDATED=2026-01-14
// GAP-0168: Benchmark for audit latency to provide performance target evidence

/// Audit latency benchmark results
pub const AuditBenchmarkResult = struct {
    avg_latency_ns: u64,
    min_latency_ns: u64,
    max_latency_ns: u64,
    p50_latency_ns: u64,
    p95_latency_ns: u64,
    p99_latency_ns: u64,
    operations_per_second: u64,
    total_operations: u64,
};

/// Simulated audit entry for benchmarking
const AuditEntry = struct {
    timestamp: i64,
    event_type: []const u8,
    user_id: u64,
    resource: []const u8,
    action: []const u8,
    result: []const u8,
    details: []const u8,
};

/// Benchmark audit log write latency
pub fn benchmarkAuditWriteLatency(allocator: Allocator, iterations: u32) !AuditBenchmarkResult {
    var latencies = try allocator.alloc(u64, iterations);
    defer allocator.free(latencies);

    // Simulate audit log writes
    var audit_buffer = std.ArrayList(u8).init(allocator);
    defer audit_buffer.deinit();

    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();

        // Create audit entry
        const entry = AuditEntry{
            .timestamp = std.time.milliTimestamp(),
            .event_type = "query_executed",
            .user_id = 12345,
            .resource = "graph:default",
            .action = "MATCH",
            .result = "success",
            .details = "MATCH (n:User) RETURN n LIMIT 10",
        };

        // Serialize to JSON format (simulated audit write)
        audit_buffer.clearRetainingCapacity();
        try std.json.stringify(entry, .{}, audit_buffer.writer());

        // Add newline for log format
        try audit_buffer.append('\n');

        const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start));
        latencies[i] = elapsed;
    }

    // Sort latencies for percentile calculation
    std.sort.pdq(u64, latencies, {}, std.sort.asc(u64));

    // Calculate statistics
    var total_ns: u128 = 0;
    for (latencies) |l| {
        total_ns += l;
    }

    const avg_ns: u64 = @intCast(total_ns / iterations);
    const p50_idx = iterations / 2;
    const p95_idx = (iterations * 95) / 100;
    const p99_idx = (iterations * 99) / 100;

    return .{
        .avg_latency_ns = avg_ns,
        .min_latency_ns = latencies[0],
        .max_latency_ns = latencies[iterations - 1],
        .p50_latency_ns = latencies[p50_idx],
        .p95_latency_ns = latencies[p95_idx],
        .p99_latency_ns = latencies[p99_idx],
        .operations_per_second = if (avg_ns > 0) 1_000_000_000 / avg_ns else 0,
        .total_operations = iterations,
    };
}

/// Benchmark concurrent audit writes
pub fn benchmarkConcurrentAuditWrites(allocator: Allocator, threads: u32, iterations_per_thread: u32) !struct {
    total_throughput_ops: u64,
    avg_latency_ns: u64,
    wall_time_ms: u64,
} {
    const ThreadContext = struct {
        allocator: Allocator,
        iterations: u32,
        total_ns: u64,
    };

    const contexts = try allocator.alloc(ThreadContext, threads);
    defer allocator.free(contexts);

    for (contexts) |*ctx| {
        ctx.* = .{
            .allocator = allocator,
            .iterations = iterations_per_thread,
            .total_ns = 0,
        };
    }

    const wall_start = std.time.milliTimestamp();

    // Spawn threads
    var handles = try allocator.alloc(std.Thread, threads);
    defer allocator.free(handles);

    for (contexts, 0..) |*ctx, idx| {
        handles[idx] = try std.Thread.spawn(.{}, struct {
            fn run(c: *ThreadContext) void {
                var buffer = std.ArrayList(u8).init(c.allocator);
                defer buffer.deinit();

                var i: u32 = 0;
                while (i < c.iterations) : (i += 1) {
                    const start = std.time.nanoTimestamp();

                    buffer.clearRetainingCapacity();
                    buffer.appendSlice("{\"timestamp\":") catch continue;
                    std.fmt.formatInt(std.time.milliTimestamp(), 10, .lower, .{}, buffer.writer()) catch continue;
                    buffer.appendSlice(",\"event\":\"query\",\"user\":") catch continue;
                    std.fmt.formatInt(@as(u64, i), 10, .lower, .{}, buffer.writer()) catch continue;
                    buffer.appendSlice("}\n") catch continue;

                    c.total_ns += @as(u64, @intCast(std.time.nanoTimestamp() - start));
                }
            }
        }.run, .{ctx});
    }

    // Wait for all threads
    for (handles) |h| {
        h.join();
    }

    const wall_end = std.time.milliTimestamp();

    // Aggregate results
    var total_ns: u64 = 0;
    for (contexts) |ctx| {
        total_ns += ctx.total_ns;
    }

    const total_ops = @as(u64, threads) * @as(u64, iterations_per_thread);
    const avg_ns = total_ns / total_ops;

    return .{
        .total_throughput_ops = total_ops * 1000 / @as(u64, @intCast(wall_end - wall_start)),
        .avg_latency_ns = avg_ns,
        .wall_time_ms = @intCast(wall_end - wall_start),
    };
}

/// Benchmark WAL fsync ordering latency
pub fn benchmarkWALOrderingLatency(allocator: Allocator, iterations: u32) !struct {
    avg_fsync_latency_us: u64,
    fsync_operations: u64,
    write_throughput_mbps: f64,
} {
    // Create temporary file for WAL simulation
    const tmp_path = "/tmp/geode_bench_wal.bin";

    var file = std.fs.cwd().createFile(tmp_path, .{}) catch |err| {
        std.debug.print("Could not create temp file: {}\n", .{err});
        return .{
            .avg_fsync_latency_us = 0,
            .fsync_operations = 0,
            .write_throughput_mbps = 0,
        };
    };
    defer file.close();
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    // Write buffer (4KB pages typical for WAL)
    const page_size: usize = 4096;
    const write_buf = try allocator.alloc(u8, page_size);
    defer allocator.free(write_buf);
    std.crypto.random.bytes(write_buf);

    var total_fsync_us: u64 = 0;
    var total_bytes_written: u64 = 0;
    const total_start = std.time.microTimestamp();

    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        // Write data
        _ = file.write(write_buf) catch continue;
        total_bytes_written += page_size;

        // Measure fsync latency
        const fsync_start = std.time.microTimestamp();
        file.sync() catch {};
        total_fsync_us += @as(u64, @intCast(std.time.microTimestamp() - fsync_start));
    }

    const total_time_us = @as(u64, @intCast(std.time.microTimestamp() - total_start));

    return .{
        .avg_fsync_latency_us = if (iterations > 0) total_fsync_us / iterations else 0,
        .fsync_operations = iterations,
        .write_throughput_mbps = if (total_time_us > 0)
            @as(f64, @floatFromInt(total_bytes_written)) / @as(f64, @floatFromInt(total_time_us))
        else
            0,
    };
}

/// Main benchmark runner
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Audit Latency Benchmark ===\n", .{});
    std.debug.print("GAP-0168: Performance target evidence\n\n", .{});

    // Single-threaded audit write latency
    std.debug.print("Running single-threaded audit write benchmark...\n", .{});
    const single_result = try benchmarkAuditWriteLatency(allocator, 10000);
    std.debug.print("  Avg latency:  {} ns ({d:.2} us)\n", .{ single_result.avg_latency_ns, @as(f64, @floatFromInt(single_result.avg_latency_ns)) / 1000.0 });
    std.debug.print("  P50 latency:  {} ns\n", .{single_result.p50_latency_ns});
    std.debug.print("  P95 latency:  {} ns\n", .{single_result.p95_latency_ns});
    std.debug.print("  P99 latency:  {} ns\n", .{single_result.p99_latency_ns});
    std.debug.print("  Throughput:   {} ops/sec\n\n", .{single_result.operations_per_second});

    // Multi-threaded audit writes
    std.debug.print("Running multi-threaded audit write benchmark (4 threads)...\n", .{});
    const concurrent_result = try benchmarkConcurrentAuditWrites(allocator, 4, 2500);
    std.debug.print("  Total throughput:  {} ops/sec\n", .{concurrent_result.total_throughput_ops});
    std.debug.print("  Avg latency:       {} ns\n", .{concurrent_result.avg_latency_ns});
    std.debug.print("  Wall time:         {} ms\n\n", .{concurrent_result.wall_time_ms});

    // WAL fsync ordering
    std.debug.print("Running WAL fsync ordering benchmark...\n", .{});
    const wal_result = try benchmarkWALOrderingLatency(allocator, 100);
    std.debug.print("  Avg fsync latency: {} us\n", .{wal_result.avg_fsync_latency_us});
    std.debug.print("  Write throughput:  {d:.2} MB/s\n", .{wal_result.write_throughput_mbps});

    std.debug.print("\n=== Benchmark Complete ===\n", .{});
}

// Unit tests
test "audit write latency benchmark" {
    const allocator = std.testing.allocator;
    const result = try benchmarkAuditWriteLatency(allocator, 100);

    try std.testing.expect(result.avg_latency_ns > 0);
    try std.testing.expect(result.operations_per_second > 0);
    try std.testing.expect(result.p50_latency_ns <= result.p95_latency_ns);
    try std.testing.expect(result.p95_latency_ns <= result.p99_latency_ns);
}

test "wal ordering latency benchmark" {
    const allocator = std.testing.allocator;
    const result = try benchmarkWALOrderingLatency(allocator, 10);

    try std.testing.expect(result.fsync_operations == 10);
}
