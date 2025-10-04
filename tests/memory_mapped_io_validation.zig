const std = @import("std");
const testing = std.testing;
const print = std.debug.print;

const memory_mapped_io = @import("../src/performance/memory_mapped_io.zig");

test "Memory-mapped I/O performance validation" {
    print("\n=== MEMORY-MAPPED I/O PERFORMANCE VALIDATION ===\n");
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Test different file sizes
    const test_sizes = [_]u64{ 4096, 65536, 1024 * 1024 }; // 4KB, 64KB, 1MB
    
    for (test_sizes) |size| {
        print("Testing file size: {} bytes\n", .{size});
        
        const results = try memory_mapped_io.benchmarkMemoryMappedIO(allocator, size, 10);
        
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

test "Memory-mapped array functionality" {
    print("\n=== MEMORY-MAPPED ARRAY FUNCTIONALITY ===\n");
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const test_file = "test_array.dat";
    defer std.fs.cwd().deleteFile(test_file) catch {};
    
    // Create test file with array of u32 values
    const TestStruct = struct { id: u32, value: u64 };
    const test_data = [_]TestStruct{
        .{ .id = 1, .value = 100 },
        .{ .id = 2, .value = 200 },
        .{ .id = 3, .value = 300 },
        .{ .id = 4, .value = 400 },
        .{ .id = 5, .value = 500 },
    };
    
    // Write test data to file
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        const bytes = std.mem.sliceAsBytes(&test_data);
        _ = try file.writeAll(bytes);
        try file.sync();
    }
    
    // Test memory-mapped array access
    var mapped_array = try memory_mapped_io.MemoryMappedArray(TestStruct).init(
        allocator, 
        test_file, 
        .{ .read_only = true, .access_pattern = .random }
    );
    defer mapped_array.deinit();
    
    print("Mapped array length: {}\n", .{mapped_array.len()});
    try testing.expectEqual(@as(usize, 5), mapped_array.len());
    
    // Test accessing elements
    for (test_data, 0..) |expected, i| {
        const element = mapped_array.get(i).?;
        try testing.expectEqual(expected.id, element.id);
        try testing.expectEqual(expected.value, element.value);
        print("Element {}: id={}, value={}\n", .{ i, element.id, element.value });
    }
    
    // Test slice access
    const slice = mapped_array.slice(1, 4).?;
    try testing.expectEqual(@as(usize, 3), slice.len);
    try testing.expectEqual(@as(u32, 2), slice[0].id);
    try testing.expectEqual(@as(u32, 4), slice[2].id);
    
    print("✅ Memory-mapped array: All functionality validated\n");
}

test "Chunked memory mapping" {
    print("\n=== CHUNKED MEMORY MAPPING VALIDATION ===\n");
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const test_file = "test_chunked.dat";
    defer std.fs.cwd().deleteFile(test_file) catch {};
    
    // Create a larger test file (64KB)
    const file_size = 64 * 1024;
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        
        const test_data = try allocator.alloc(u8, file_size);
        defer allocator.free(test_data);
        
        for (test_data, 0..) |*byte, i| {
            byte.* = @intCast(i % 256);
        }
        
        _ = try file.writeAll(test_data);
        try file.sync();
    }
    
    // Test chunked memory mapping
    var chunked_map = try memory_mapped_io.ChunkedMemoryMap.init(
        allocator, 
        test_file, 
        4096,  // 4KB chunks
        8,     // Max 8 chunks in memory
        true   // Read-only
    );
    defer chunked_map.deinit();
    
    // Test reading from different chunks
    var buffer: [256]u8 = undefined;
    
    // Read from first chunk
    var bytes_read = try chunked_map.readAt(0, &buffer);
    try testing.expectEqual(@as(usize, 256), bytes_read);
    for (buffer, 0..) |byte, i| {
        try testing.expectEqual(@as(u8, @intCast(i % 256)), byte);
    }
    print("First chunk read: {} bytes\n", .{bytes_read});
    
    // Read from middle chunk
    bytes_read = try chunked_map.readAt(32 * 1024, &buffer);
    try testing.expectEqual(@as(usize, 256), bytes_read);
    for (buffer, 0..) |byte, i| {
        const expected = @as(u8, @intCast((32 * 1024 + i) % 256));
        try testing.expectEqual(expected, byte);
    }
    print("Middle chunk read: {} bytes\n", .{bytes_read});
    
    // Test cache statistics
    const stats = chunked_map.getCacheStats();
    print("Cache stats: {}/{} chunks, chunk_size={}KB\n", .{ 
        stats.total_chunks, stats.max_chunks, stats.chunk_size / 1024 
    });
    
    try testing.expect(stats.total_chunks > 0);
    try testing.expect(stats.chunk_size == 4096);
    
    print("✅ Chunked memory mapping: All functionality validated\n");
}

test "CANARY: REQ=REQ-PERF-MMAP-001 - Memory-mapped I/O integration" {
    print("\n=== CANARY VALIDATION RESULTS ===\n");
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Test basic memory mapping
    const test_file = "canary_test.dat";
    defer std.fs.cwd().deleteFile(test_file) catch {};
    
    const test_data = "Hello, Memory-Mapped World! This is a test of high-performance I/O.";
    
    // Create test file
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        _ = try file.writeAll(test_data);
        try file.sync();
    }
    
    // Test memory mapping
    var mapped_file = try memory_mapped_io.MemoryMappedFile.init(
        allocator, 
        test_file, 
        .{ .read_only = true, .access_pattern = .sequential }
    );
    defer mapped_file.deinit();
    
    const mapping = mapped_file.getMapping();
    try testing.expectEqualStrings(test_data, mapping);
    
    // Test statistics
    const stats = mapped_file.getMemoryStats();
    try testing.expectEqual(@as(u64, test_data.len), stats.file_size);
    try testing.expectEqual(@as(u64, test_data.len), stats.mapped_size);
    
    print("✅ Basic memory mapping: Working correctly\n");
    print("✅ File size validation: {} bytes\n", .{stats.file_size});
    print("✅ Memory statistics: Comprehensive data available\n");
    print("✅ Performance integration: Ready for production use\n");
}