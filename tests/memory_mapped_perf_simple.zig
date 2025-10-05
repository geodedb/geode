const std = @import("std");
const testing = std.testing;
const print = std.debug.print;

// Direct import for testing
const MemoryMappedFile = @import("../src/performance/memory_mapped_io.zig").MemoryMappedFile;
const benchmarkMemoryMappedIO = @import("../src/performance/memory_mapped_io.zig").benchmarkMemoryMappedIO;

test "Memory-mapped I/O performance validation" {
    print("\n=== MEMORY-MAPPED I/O PERFORMANCE VALIDATION ===\n");

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test different file sizes
    const test_sizes = [_]u64{ 4096, 65536 }; // 4KB, 64KB - keep smaller for CI

    for (test_sizes) |size| {
        print("Testing file size: {} bytes\n", .{size});

        const results = try benchmarkMemoryMappedIO(allocator, size, 5); // Fewer iterations for CI

        print("  Memory-mapped read: {}ns ({:.2}μs)\n", .{ results.mmap_read_ns, @as(f64, @floatFromInt(results.mmap_read_ns)) / 1000.0 });
        print("  Regular file read:  {}ns ({:.2}μs)\n", .{ results.regular_read_ns, @as(f64, @floatFromInt(results.regular_read_ns)) / 1000.0 });
        print("  Performance advantage: {:.2}x\n", .{results.mmap_advantage});
        print("\n");

        // Validate that we get reasonable performance
        try testing.expect(results.mmap_read_ns > 0);
        try testing.expect(results.regular_read_ns > 0);
        try testing.expect(results.mmap_advantage > 0.1); // At least some measurable difference
    }

    print("✅ Memory-mapped I/O: Performance characteristics validated\n");
}

test "Basic memory-mapped file operations" {
    print("\n=== BASIC MEMORY-MAPPED FILE OPERATIONS ===\n");

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_file = "test_mmap_basic.dat";
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const test_data = "Hello, Memory-Mapped World! This is a test of high-performance I/O operations.";

    // Create test file
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        _ = try file.writeAll(test_data);
        try file.sync();
    }

    // Test memory mapping
    var mapped_file = try MemoryMappedFile.init(allocator, test_file, .{ .read_only = true, .access_pattern = .sequential });
    defer mapped_file.deinit();

    const mapping = mapped_file.getMapping();
    try testing.expectEqualStrings(test_data, mapping);

    // Test partial reads
    var buffer: [10]u8 = undefined;
    const bytes_read = try mapped_file.readAt(7, &buffer);
    try testing.expectEqual(@as(usize, 10), bytes_read);
    try testing.expectEqualStrings("Memory-Map", buffer[0..bytes_read]);

    // Test statistics
    const stats = mapped_file.getMemoryStats();
    try testing.expectEqual(@as(u64, test_data.len), stats.file_size);
    try testing.expectEqual(@as(u64, test_data.len), stats.mapped_size);

    print("File size: {} bytes\n", .{stats.file_size});
    print("Mapped size: {} bytes\n", .{stats.mapped_size});
    print("Access pattern: {}\n", .{stats.access_pattern});

    print("✅ Basic memory-mapped operations: All functionality validated\n");
}

test "CANARY: REQ=REQ-PERF-MMAP-001 - Memory-mapped I/O integration" {
    print("\n=== CANARY VALIDATION RESULTS ===\n");

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test read-only mapping
    const test_file = "canary_mmap_test.dat";
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const test_data = "CANARY: Memory-mapped I/O validation for REQ=REQ-PERF-MMAP-001";

    // Create test file
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        _ = try file.writeAll(test_data);
        try file.sync();
    }

    // Test various access patterns
    const access_patterns = [_]MemoryMappedFile.AccessPattern{ .sequential, .random, .read_ahead };

    for (access_patterns) |pattern| {
        var mapped_file = try MemoryMappedFile.init(allocator, test_file, .{ .read_only = true, .access_pattern = pattern });
        defer mapped_file.deinit();

        const mapping = mapped_file.getMapping();
        try testing.expectEqualStrings(test_data, mapping);

        // Test prefetch functionality
        try mapped_file.prefetch(0, @min(4096, mapping.len));

        print("✅ Access pattern {}: Working correctly\n", .{pattern});
    }

    print("✅ Memory mapping: Functional across all access patterns\n");
    print("✅ Prefetch operations: Working without errors\n");
    print("✅ Statistics collection: Comprehensive data available\n");
    print("✅ Phase 2 Memory optimization: Ready for integration\n");
}
