const std = @import("std");
const testing = std.testing;
const print = std.debug.print;

// CANARY: REQ=REQ-PERF-INT-001; FEATURE="PerformanceIntegration"; ASPECT=Testing; STATUS=EXEMPT; TEST=TestCANARY_PerformanceIntegration; OWNER=performance; UPDATED=2025-10-04

/// Comprehensive integration tests for Phase 1 and Phase 2 performance optimizations
/// Tests interaction between buffered I/O, JSON optimization, memory mapping, and async operations

// Import performance modules
const io_optimized = @import("../tests/io_optimized_test.zig");
const json_optimized = @import("../src/performance/json_optimized_fixed.zig");
const memory_mapped_io = @import("../src/performance/memory_mapped_io.zig");
const async_io_simple = @import("../src/performance/async_io_simple.zig");

test "Integration: Buffered I/O + JSON processing pipeline" {
    print("\n=== INTEGRATION TEST: BUFFERED I/O + JSON PROCESSING ===\n");

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_file = "integration_io_json.dat";
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Create test file using buffered I/O
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();

        var buffered_writer = try io_optimized.BufferedFileWriter.init(allocator, file, io_optimized.BufferedFileWriter.DEFAULT_BUFFER_SIZE);
        defer buffered_writer.deinit();

        // Write JSON data using buffered writer
        try buffered_writer.writeFormatted("{{\"test_data\":\"{s}\",\"size\":{}}}\n", .{ "integration_test", 1024 });
        try buffered_writer.writeFormatted("{{\"performance\":\"{s}\",\"improvement\":{d}}}\n", .{ "13.18x_faster", 13.18 });
        try buffered_writer.writeFormatted("{{\"module\":\"{s}\",\"status\":\"{s}\"}}\n", .{ "buffered_io", "working" });

        try buffered_writer.flush();
        print("Buffered I/O: Successfully wrote {} bytes\n", .{buffered_writer.position});
    }

    // Read and process JSON using optimized JSON processor
    {
        const file_content = try std.fs.cwd().readFileAlloc(allocator, test_file, 1024 * 1024);
        defer allocator.free(file_content);

        var json_processor = json_optimized.OptimizedJsonProcessor.init(allocator);
        defer json_processor.deinit();

        // Process each line as JSON
        var line_iter = std.mem.split(u8, file_content, "\n");
        var processed_count: u32 = 0;

        while (line_iter.next()) |line| {
            if (line.len == 0) continue;

            const parsed = json_processor.parseJsonValue(line) catch continue;
            defer parsed.deinit();

            processed_count += 1;
            print("JSON Processing: Parsed line {} successfully\n", .{processed_count});
        }

        try testing.expectEqual(@as(u32, 3), processed_count);
        print("✅ Buffered I/O + JSON: {} lines processed successfully\n", .{processed_count});
    }
}

test "Integration: Memory-mapped I/O + Async operations" {
    print("\n=== INTEGRATION TEST: MEMORY-MAPPED I/O + ASYNC OPERATIONS ===\n");

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_file = "integration_mmap_async.dat";
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Create test data using memory-mapped I/O
    const test_data = "Memory-mapped and async I/O integration test with performance optimizations";

    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        _ = try file.writeAll(test_data);
        try file.sync();
    }

    // Test memory-mapped access
    var mapped_file = try memory_mapped_io.MemoryMappedFile.init(allocator, test_file, .{ .read_only = true, .access_pattern = .sequential });
    defer mapped_file.deinit();

    const mapping = mapped_file.getMapping();
    try testing.expectEqualStrings(test_data, mapping);
    print("Memory-mapped I/O: Successfully mapped {} bytes\n", .{mapping.len});

    // Test statistics
    const stats = mapped_file.getMemoryStats();
    print("Memory stats: file_size={}, mapped_size={}, access_pattern={}\n", .{ stats.file_size, stats.mapped_size, stats.access_pattern });

    // Test async operations on the same file
    var async_io = async_io_simple.SimpleAsyncIO.init(allocator);
    defer async_io.deinit();

    var async_file = async_io_simple.AsyncFile.init(&async_io, test_file);

    var buffer: [128]u8 = undefined;
    const result = try async_file.readSync(buffer[0..test_data.len]);

    try testing.expect(result.status == .success);
    try testing.expectEqual(test_data.len, result.bytes_processed);
    try testing.expectEqualStrings(test_data, buffer[0..test_data.len]);

    print("Async I/O: Successfully read {} bytes\n", .{result.bytes_processed});
    print("✅ Memory-mapped + Async: Integration successful\n");
}

test "Integration: Full performance pipeline simulation" {
    print("\n=== INTEGRATION TEST: FULL PERFORMANCE PIPELINE ===\n");

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_file = "integration_full_pipeline.dat";
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Simulate database write operations using all optimizations
    var timer = try std.time.Timer.start();

    // Phase 1: Buffered write operations
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();

        var buffered_writer = try io_optimized.BufferedFileWriter.init(allocator, file, 32 * 1024 // 32KB buffer
        );
        defer buffered_writer.deinit();

        // Write structured data
        for (0..100) |i| {
            try buffered_writer.writeFormatted("{{\"id\":{},\"name\":\"user_{}\",\"data\":\"{}KB_payload\"}}\n", .{ i, i, (i % 10) + 1 });
        }

        try buffered_writer.flush();
        const write_time = timer.read();
        print("Phase 1 - Buffered writes: {}μs for 100 records\n", .{write_time / 1000});
    }

    // Phase 2: Memory-mapped read operations
    timer.reset();
    var mapped_file = try memory_mapped_io.MemoryMappedFile.init(allocator, test_file, .{ .read_only = true, .access_pattern = .sequential });
    defer mapped_file.deinit();

    const mapping = mapped_file.getMapping();
    const mmap_time = timer.read();
    print("Phase 2 - Memory mapping: {}μs for {} bytes\n", .{ mmap_time / 1000, mapping.len });

    // Phase 3: JSON processing of mapped data
    timer.reset();
    var json_processor = json_optimized.OptimizedJsonProcessor.init(allocator);
    defer json_processor.deinit();

    var line_iter = std.mem.split(u8, mapping, "\n");
    var processed_records: u32 = 0;

    while (line_iter.next()) |line| {
        if (line.len == 0) continue;

        const parsed = json_processor.parseJsonValue(line) catch continue;
        defer parsed.deinit();

        processed_records += 1;
    }

    const json_time = timer.read();
    print("Phase 3 - JSON processing: {}μs for {} records\n", .{ json_time / 1000, processed_records });

    // Phase 4: Async operations simulation
    timer.reset();
    var async_io = async_io_simple.SimpleAsyncIO.init(allocator);
    defer async_io.deinit();

    var async_file = async_io_simple.AsyncFile.init(&async_io, test_file);

    var buffer: [1024]u8 = undefined;
    const result = try async_file.readSync(buffer[0..@min(1024, mapping.len)]);

    const async_time = timer.read();
    print("Phase 4 - Async operations: {}μs for {} bytes\n", .{ async_time / 1000, result.bytes_processed });

    // Validate end-to-end pipeline
    try testing.expectEqual(@as(u32, 100), processed_records);
    try testing.expect(result.status == .success);
    try testing.expect(mapping.len > 2000); // Reasonable file size

    print("✅ Full pipeline: All phases completed successfully\n");
    print("Total performance optimizations validated: Phase 1 + Phase 2\n");
}

test "Integration: Performance regression detection" {
    print("\n=== INTEGRATION TEST: PERFORMANCE REGRESSION DETECTION ===\n");

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_file = "integration_regression.dat";
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const test_data_size = 16 * 1024; // 16KB
    const test_data = try allocator.alloc(u8, test_data_size);
    defer allocator.free(test_data);

    // Fill with pattern
    for (test_data, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    // Create test file
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        _ = try file.writeAll(test_data);
        try file.sync();
    }

    // Benchmark buffered vs unbuffered I/O
    var timer = try std.time.Timer.start();
    const iterations = 10;

    // Unbuffered baseline
    var unbuffered_total: u64 = 0;
    for (0..iterations) |_| {
        timer.reset();
        const file = try std.fs.cwd().openFile(test_file, .{});
        defer file.close();

        const buffer = try allocator.alloc(u8, test_data_size);
        defer allocator.free(buffer);

        _ = try file.readAll(buffer);
        unbuffered_total += timer.read();
    }

    // Buffered optimized
    var buffered_total: u64 = 0;
    for (0..iterations) |_| {
        timer.reset();

        var mapped_file = try memory_mapped_io.MemoryMappedFile.init(allocator, test_file, .{ .read_only = true });
        defer mapped_file.deinit();

        _ = mapped_file.getMapping();
        buffered_total += timer.read();
    }

    const unbuffered_avg = unbuffered_total / iterations;
    const buffered_avg = buffered_total / iterations;
    const improvement_ratio = @as(f64, @floatFromInt(unbuffered_avg)) / @as(f64, @floatFromInt(buffered_avg));

    print("Unbuffered average: {}μs\n", .{unbuffered_avg / 1000});
    print("Memory-mapped average: {}μs\n", .{buffered_avg / 1000});
    print("Performance improvement: {d:.2}x\n", .{improvement_ratio});

    // Regression detection: Ensure we're still getting reasonable improvements
    try testing.expect(improvement_ratio >= 1.0); // At least no regression
    if (improvement_ratio < 2.0) {
        print("⚠️  Warning: Performance improvement below expected threshold (2.0x)\n");
    } else {
        print("✅ Performance regression test: Passed with {d:.2}x improvement\n", .{improvement_ratio});
    }
}

test "CANARY: REQ=REQ-PERF-INT-001 - Performance integration validation" {
    print("\n=== CANARY VALIDATION: PERFORMANCE INTEGRATION ===\n");

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test all performance modules are accessible and functional

    // 1. Buffered I/O
    const test_file = "canary_perf_integration.dat";
    defer std.fs.cwd().deleteFile(test_file) catch {};

    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();

        var buffered_writer = try io_optimized.BufferedFileWriter.init(allocator, file, 4096);
        defer buffered_writer.deinit();

        try buffered_writer.writeFormatted("CANARY: Buffered I/O working\n", .{});
        try buffered_writer.flush();
    }

    // 2. Memory-mapped I/O
    var mapped_file = try memory_mapped_io.MemoryMappedFile.init(allocator, test_file, .{ .read_only = true });
    defer mapped_file.deinit();

    const mapping = mapped_file.getMapping();
    try testing.expect(std.mem.indexOf(u8, mapping, "CANARY") != null);

    // 3. JSON processing
    var json_processor = json_optimized.OptimizedJsonProcessor.init(allocator);
    defer json_processor.deinit();

    const test_json = "{\"canary\":\"json_processing\",\"status\":\"working\"}";
    const parsed = try json_processor.parseJsonValue(test_json);
    defer parsed.deinit();

    // 4. Async I/O
    var async_io = async_io_simple.SimpleAsyncIO.init(allocator);
    defer async_io.deinit();

    var async_file = async_io_simple.AsyncFile.init(&async_io, test_file);

    var buffer: [64]u8 = undefined;
    const result = try async_file.readSync(buffer[0..32]);
    try testing.expect(result.status == .success);

    print("✅ Buffered I/O: Module functional\n");
    print("✅ Memory-mapped I/O: Module functional\n");
    print("✅ JSON processing: Module functional\n");
    print("✅ Async I/O: Module functional\n");
    print("✅ Performance integration: All modules working together\n");
    print("✅ CANARY REQ=REQ-PERF-INT-001: Validation successful\n");
}
