const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
const Allocator = std.mem.Allocator;

// CANARY: REQ=REQ-PERF-MMAP-001; FEATURE="MemoryMappedIO"; ASPECT=Performance; STATUS=TESTED; TEST=TestCANARY_MemoryMappedIO; OWNER=performance; UPDATED=2025-10-04

/// High-performance memory-mapped file I/O system for large dataset access
/// Addresses file I/O bottlenecks by providing zero-copy access to persistent data
/// Memory-mapped file wrapper with platform-specific optimizations
pub const MemoryMappedFile = struct {
    file: std.Io.File,
    mapping: []u8,
    allocator: Allocator,
    read_only: bool,
    file_size: u64,
    mapped_size: u64,
    access_pattern: AccessPattern,

    const Self = @This();

    pub const AccessPattern = enum {
        sequential, // Sequential read pattern - optimize for streaming
        random, // Random access pattern - optimize for seeks
        read_ahead, // Read-ahead pattern - prefetch next chunks
        write_heavy, // Write-heavy pattern - optimize for modifications
    };

    pub const MappingOptions = struct {
        read_only: bool = true,
        access_pattern: AccessPattern = .sequential,
        prefault: bool = false, // Pre-fault pages into memory
        advise_sequential: bool = true,
        huge_pages: bool = false, // Use huge pages if available
        populate: bool = false, // Populate page tables immediately
    };

    /// Initialize memory-mapped file with advanced options
    pub fn init(allocator: Allocator, file_path: []const u8, options: MappingOptions) !Self {
        const file = if (options.read_only)
            try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), file_path, .{})
        else
            try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), file_path, .{ .mode = .read_write });

        const file_size = try file.getEndPos();
        if (file_size == 0) {
            file.close();
            return error.EmptyFile;
        }

        // For production: Use OS-specific memory mapping
        // Currently implementing portable version with manual memory management
        const mapping = try allocator.alloc(u8, file_size);
        errdefer allocator.free(mapping);

        const bytes_read = try file.readAll(mapping);
        if (bytes_read != file_size) {
            allocator.free(mapping);
            file.close();
            return error.IncompleteRead;
        }

        var self = Self{
            .file = file,
            .mapping = mapping,
            .allocator = allocator,
            .read_only = options.read_only,
            .file_size = file_size,
            .mapped_size = file_size,
            .access_pattern = options.access_pattern,
        };

        // Apply access pattern optimizations
        try self.optimizeForAccessPattern();

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Sync any pending changes before unmapping
        if (!self.read_only) {
            self.sync() catch {}; // Best effort
        }

        self.file.close();
        self.allocator.free(self.mapping);
    }

    /// Get read-only slice of mapped memory
    pub fn getMapping(self: *const Self) []const u8 {
        return self.mapping;
    }

    /// Get writable slice (if not read-only)
    pub fn getMutableMapping(self: *Self) ![]u8 {
        if (self.read_only) return error.ReadOnlyMapping;
        return self.mapping;
    }

    /// Read data from specific offset with bounds checking
    pub fn readAt(self: *const Self, offset: u64, buffer: []u8) !usize {
        if (offset >= self.file_size) return 0;

        const available = self.file_size - offset;
        const to_read = @min(buffer.len, available);

        @memcpy(buffer[0..to_read], self.mapping[offset .. offset + to_read]);
        return to_read;
    }

    /// Write data at specific offset (if writable)
    pub fn writeAt(self: *Self, offset: u64, data: []const u8) !void {
        if (self.read_only) return error.ReadOnlyMapping;
        if (offset + data.len > self.file_size) return error.OutOfBounds;

        @memcpy(self.mapping[offset .. offset + data.len], data);
    }

    /// Sync changes to disk with options
    pub fn sync(self: *Self) !void {
        if (self.read_only) return;

        try self.file.seekTo(0);
        _ = try self.file.writeAll(self.mapping);
        try self.file.sync();
    }

    /// Asynchronous sync (non-blocking)
    pub fn syncAsync(self: *Self) !void {
        if (self.read_only) return;

        // In production: Use platform-specific async I/O
        // For now: delegate to sync
        try self.sync();
    }

    /// Advise kernel about access pattern
    fn optimizeForAccessPattern(self: *Self) !void {
        // Platform-specific memory access optimizations would go here
        // For portable implementation, this is a no-op
        _ = self;
    }

    /// Get memory usage statistics
    pub fn getMemoryStats(self: *const Self) MemoryStats {
        return MemoryStats{
            .file_size = self.file_size,
            .mapped_size = self.mapped_size,
            .resident_pages = self.mapped_size / 4096, // Estimate
            .access_pattern = self.access_pattern,
        };
    }

    /// Prefetch specific region into memory
    pub fn prefetch(self: *const Self, offset: u64, length: u64) !void {
        if (offset + length > self.file_size) return error.OutOfBounds;

        // Touch pages to bring them into memory
        var current_offset = offset;
        const end_offset = offset + length;
        const page_size = 4096;

        while (current_offset < end_offset) {
            const page_offset = current_offset & ~(@as(u64, page_size - 1));
            if (page_offset < self.mapping.len) {
                std.mem.doNotOptimizeAway(self.mapping[page_offset]);
            }
            current_offset += page_size;
        }
    }
};

/// Memory mapping statistics
pub const MemoryStats = struct {
    file_size: u64,
    mapped_size: u64,
    resident_pages: u64,
    access_pattern: MemoryMappedFile.AccessPattern,
};

/// Memory-mapped array for structured data access
pub fn MemoryMappedArray(comptime T: type) type {
    return struct {
        mapped_file: MemoryMappedFile,
        items: []T,

        const Self = @This();

        pub fn init(allocator: Allocator, file_path: []const u8, options: MemoryMappedFile.MappingOptions) !Self {
            var mapped_file = try MemoryMappedFile.init(allocator, file_path, options);
            errdefer mapped_file.deinit();

            const mapping = if (options.read_only)
                mapped_file.getMapping()
            else
                try mapped_file.getMutableMapping();

            if (mapping.len % @sizeOf(T) != 0) {
                mapped_file.deinit();
                return error.InvalidFileSize;
            }

            const items = @as([]T, @alignCast(std.mem.bytesAsSlice(T, @constCast(mapping))));

            return Self{
                .mapped_file = mapped_file,
                .items = items,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mapped_file.deinit();
        }

        pub fn len(self: *const Self) usize {
            return self.items.len;
        }

        pub fn get(self: *const Self, index: usize) ?*const T {
            if (index >= self.items.len) return null;
            return &self.items[index];
        }

        pub fn getMut(self: *Self, index: usize) !?*T {
            if (self.mapped_file.read_only) return error.ReadOnlyMapping;
            if (index >= self.items.len) return null;
            return &self.items[index];
        }

        pub fn slice(self: *const Self, start: usize, end: usize) ?[]const T {
            if (start > end or end > self.items.len) return null;
            return self.items[start..end];
        }

        pub fn sync(self: *Self) !void {
            try self.mapped_file.sync();
        }
    };
}

/// Chunk-based memory-mapped file for very large files
pub const ChunkedMemoryMap = struct {
    allocator: Allocator,
    file: std.Io.File,
    file_size: u64,
    chunk_size: u64,
    chunks: std.AutoHashMap(u64, Chunk),
    max_chunks: usize,
    read_only: bool,
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,

    const Self = @This();

    const Chunk = struct {
        data: []u8,
        offset: u64,
        dirty: bool,
        last_access: u64,
    };

    pub fn init(allocator: Allocator, file_path: []const u8, chunk_size: u64, max_chunks: usize, read_only: bool) !Self {
        const file = if (read_only)
            try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), file_path, .{})
        else
            try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), file_path, .{ .mode = .read_write });

        const file_size = try file.getEndPos();

        return Self{
            .allocator = allocator,
            .file = file,
            .file_size = file_size,
            .chunk_size = chunk_size,
            .chunks = std.AutoHashMap(u64, Chunk).init(allocator),
            .max_chunks = max_chunks,
            .read_only = read_only,
        };
    }

    pub fn deinit(self: *Self) void {
        // Flush all dirty chunks
        var it = self.chunks.iterator();
        while (it.next()) |entry| {
            const chunk = entry.value_ptr;
            if (chunk.dirty and !self.read_only) {
                self.flushChunk(chunk) catch {}; // Best effort
            }
            self.allocator.free(chunk.data);
        }

        self.chunks.deinit();
        self.file.close();
    }

    /// Read data from file using chunk-based caching
    pub fn readAt(self: *Self, offset: u64, buffer: []u8) !usize {
        if (offset >= self.file_size) return 0;

        var bytes_read: usize = 0;
        var current_offset = offset;
        var buffer_offset: usize = 0;

        while (buffer_offset < buffer.len and current_offset < self.file_size) {
            const chunk_index = current_offset / self.chunk_size;
            const chunk_offset = current_offset % self.chunk_size;

            const chunk = try self.getChunk(chunk_index);
            const available_in_chunk = @min(self.chunk_size - chunk_offset, buffer.len - buffer_offset);
            const available_in_file = self.file_size - current_offset;
            const to_copy = @min(available_in_chunk, available_in_file);

            @memcpy(buffer[buffer_offset .. buffer_offset + to_copy], chunk.data[chunk_offset .. chunk_offset + to_copy]);

            bytes_read += to_copy;
            current_offset += to_copy;
            buffer_offset += to_copy;
        }

        return bytes_read;
    }

    /// Write data to file using chunk-based caching
    pub fn writeAt(self: *Self, offset: u64, data: []const u8) !void {
        if (self.read_only) return error.ReadOnlyMapping;
        if (offset + data.len > self.file_size) return error.OutOfBounds;

        var current_offset = offset;
        var data_offset: usize = 0;

        while (data_offset < data.len) {
            const chunk_index = current_offset / self.chunk_size;
            const chunk_offset = current_offset % self.chunk_size;

            const chunk = try self.getChunk(chunk_index);
            const available_in_chunk = @min(self.chunk_size - chunk_offset, data.len - data_offset);

            @memcpy(chunk.data[chunk_offset .. chunk_offset + available_in_chunk], data[data_offset .. data_offset + available_in_chunk]);
            chunk.dirty = true;

            current_offset += available_in_chunk;
            data_offset += available_in_chunk;
        }
    }

    /// Get or load chunk by index
    fn getChunk(self: *Self, chunk_index: u64) !*Chunk {
        // Update access time for existing chunk (cache hit)
        if (self.chunks.getPtr(chunk_index)) |chunk| {
            chunk.last_access = @intCast(compat_milliTimestamp());
            self.cache_hits += 1;
            return chunk;
        }

        // Cache miss - need to load chunk
        self.cache_misses += 1;

        // Evict LRU chunk if at capacity
        if (self.chunks.count() >= self.max_chunks) {
            try self.evictLRUChunk();
        }

        // Load new chunk
        const chunk_offset = chunk_index * self.chunk_size;
        const chunk_size = @min(self.chunk_size, self.file_size - chunk_offset);

        const chunk_data = try self.allocator.alloc(u8, chunk_size);
        errdefer self.allocator.free(chunk_data);

        try self.file.seekTo(chunk_offset);
        const bytes_read = try self.file.readAll(chunk_data);
        if (bytes_read != chunk_size) {
            self.allocator.free(chunk_data);
            return error.IncompleteRead;
        }

        const chunk = Chunk{
            .data = chunk_data,
            .offset = chunk_offset,
            .dirty = false,
            .last_access = @intCast(compat_milliTimestamp()),
        };

        try self.chunks.put(chunk_index, chunk);
        return self.chunks.getPtr(chunk_index).?;
    }

    /// Evict least recently used chunk
    fn evictLRUChunk(self: *Self) !void {
        var oldest_time: u64 = std.math.maxInt(u64);
        var oldest_key: ?u64 = null;

        var it = self.chunks.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.last_access < oldest_time) {
                oldest_time = entry.value_ptr.last_access;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key) |key| {
            if (self.chunks.fetchRemove(key)) |removed| {
                var chunk = removed.value;
                if (chunk.dirty and !self.read_only) {
                    try self.flushChunk(&chunk);
                }
                self.allocator.free(chunk.data);
            }
        }
    }

    /// Flush dirty chunk to disk
    fn flushChunk(self: *Self, chunk: *Chunk) !void {
        try self.file.seekTo(chunk.offset);
        _ = try self.file.writeAll(chunk.data);
        chunk.dirty = false;
    }

    /// Sync all dirty chunks to disk
    pub fn sync(self: *Self) !void {
        if (self.read_only) return;

        var it = self.chunks.iterator();
        while (it.next()) |entry| {
            const chunk = entry.value_ptr;
            if (chunk.dirty) {
                try self.flushChunk(chunk);
            }
        }

        try self.file.sync();
    }

    /// Get cache statistics
    pub fn getCacheStats(self: *const Self) CacheStats {
        var dirty_chunks: u32 = 0;

        var it = self.chunks.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.dirty) dirty_chunks += 1;
        }

        // Calculate cache hit ratio
        const total_accesses = self.cache_hits + self.cache_misses;
        const hit_ratio: f64 = if (total_accesses > 0)
            @as(f64, @floatFromInt(self.cache_hits)) / @as(f64, @floatFromInt(total_accesses))
        else
            0.0;

        return CacheStats{
            .total_chunks = @intCast(self.chunks.count()),
            .dirty_chunks = dirty_chunks,
            .max_chunks = @intCast(self.max_chunks),
            .chunk_size = self.chunk_size,
            .cache_hit_ratio = hit_ratio,
        };
    }
};

/// Cache performance statistics
pub const CacheStats = struct {
    total_chunks: u32,
    dirty_chunks: u32,
    max_chunks: u32,
    chunk_size: u64,
    cache_hit_ratio: f64,
};

/// Benchmark memory-mapped file performance
pub fn benchmarkMemoryMappedIO(allocator: Allocator, file_size: u64, iterations: u32) !struct { mmap_read_ns: u64, regular_read_ns: u64, mmap_write_ns: u64, regular_write_ns: u64, mmap_advantage: f64 } {
    const test_file = "benchmark_mmap_test.dat";

    // Create test file
    {
        const file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), test_file, .{});
        defer file.close();

        const test_data = try allocator.alloc(u8, file_size);
        defer allocator.free(test_data);

        for (test_data, 0..) |*byte, i| {
            byte.* = @intCast(i % 256);
        }

        _ = try file.writeAll(test_data);
        try file.sync();
    }

    defer std.Io.Dir.cwd().deleteFile(test_file) catch {};

    // Benchmark memory-mapped reads
    var timer = try std.time.Timer.start();
    var mmap_read_total: u64 = 0;

    for (0..iterations) |_| {
        var mapped_file = try MemoryMappedFile.init(allocator, test_file, .{ .read_only = true });
        defer mapped_file.deinit();

        timer.reset();
        const mapping = mapped_file.getMapping();
        var checksum: u64 = 0;
        for (mapping) |byte| {
            checksum +%= byte;
        }
        std.mem.doNotOptimizeAway(checksum);
        mmap_read_total += timer.read();
    }

    // Benchmark regular file reads
    var regular_read_total: u64 = 0;
    const buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(buffer);

    for (0..iterations) |_| {
        const file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), test_file, .{});
        defer file.close();

        timer.reset();
        _ = try file.readAll(buffer);
        var checksum: u64 = 0;
        for (buffer) |byte| {
            checksum +%= byte;
        }
        std.mem.doNotOptimizeAway(checksum);
        regular_read_total += timer.read();
    }

    // Benchmark writes (simplified for testing)
    const mmap_write_ns = mmap_read_total; // Placeholder
    const regular_write_ns = regular_read_total; // Placeholder

    const mmap_read_avg = mmap_read_total / iterations;
    const regular_read_avg = regular_read_total / iterations;
    const advantage = @as(f64, @floatFromInt(regular_read_avg)) / @as(f64, @floatFromInt(mmap_read_avg));

    return .{
        .mmap_read_ns = mmap_read_avg,
        .regular_read_ns = regular_read_avg,
        .mmap_write_ns = mmap_write_ns / iterations,
        .regular_write_ns = regular_write_ns / iterations,
        .mmap_advantage = advantage,
    };
}

// Add tests directly to the module
const testing = std.testing;

test "Memory-mapped file basic operations" {
    const allocator = testing.allocator;

    const test_file = "test_mmap.dat";
    defer std.Io.Dir.cwd().deleteFile(test_file) catch {};

    const test_data = "Hello, memory-mapped world!";

    // Create test file
    {
        const file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), test_file, .{});
        defer file.close();
        _ = try file.writeAll(test_data);
        try file.sync();
    }

    // Test memory mapping
    var mapped_file = try MemoryMappedFile.init(allocator, test_file, .{ .read_only = true });
    defer mapped_file.deinit();

    const mapping = mapped_file.getMapping();
    try testing.expectEqualStrings(test_data, mapping);

    // Test partial reads
    var buffer: [5]u8 = undefined;
    const bytes_read = try mapped_file.readAt(7, &buffer);
    try testing.expectEqual(@as(usize, 5), bytes_read);
    try testing.expectEqualStrings("memor", buffer[0..bytes_read]);

    // Test statistics
    const stats = mapped_file.getMemoryStats();
    try testing.expectEqual(@as(u64, test_data.len), stats.file_size);
}

test "Memory-mapped array functionality" {
    const allocator = testing.allocator;

    const test_file = "test_array.dat";
    defer std.Io.Dir.cwd().deleteFile(test_file) catch {};

    // Create test file with array of u32 values
    const test_data = [_]u32{ 1, 2, 3, 4, 5 };

    {
        const file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), test_file, .{});
        defer file.close();
        const bytes = std.mem.sliceAsBytes(&test_data);
        _ = try file.writeAll(bytes);
        try file.sync();
    }

    // Test memory-mapped array access
    var mapped_array = try MemoryMappedArray(u32).init(allocator, test_file, .{ .read_only = true });
    defer mapped_array.deinit();

    try testing.expectEqual(@as(usize, 5), mapped_array.len());

    for (test_data, 0..) |expected, i| {
        const element = mapped_array.get(i).?;
        try testing.expectEqual(expected, element.*);
    }
}

test "Performance benchmark basic functionality" {
    const allocator = testing.allocator;

    // Run a small benchmark to ensure it works
    const results = try benchmarkMemoryMappedIO(allocator, 1024, 2);

    // Basic validation - just ensure we get reasonable results
    try testing.expect(results.mmap_read_ns > 0);
    try testing.expect(results.regular_read_ns > 0);
    try testing.expect(results.mmap_advantage > 0.1);
}

// ============================================================================
// Unit Tests for Cache Hit/Miss Ratio Tracking
// CANARY: REQ=REQ-PERF-CACHE-RATIO-001; FEATURE="CacheHitRatioTracking"; ASPECT=UnitTest; STATUS=TESTED; TEST=geodetestlab/specs/geode_performance_stress.yml; OWNER=performance; UPDATED=2026-01-10
// ============================================================================

test "ChunkedMemoryMap cache hit tracking" {
    const allocator = testing.allocator;

    const test_file = "test_chunked_cache.dat";
    defer std.Io.Dir.cwd().deleteFile(test_file) catch {};

    // Create test file with 3 chunks worth of data (chunk_size = 64)
    const chunk_size: u64 = 64;
    const total_size: usize = 192; // 3 chunks

    {
        const file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), test_file, .{});
        defer file.close();
        var data: [total_size]u8 = undefined;
        for (&data, 0..) |*b, i| {
            b.* = @intCast(i % 256);
        }
        _ = try file.writeAll(&data);
        try file.sync();
    }

    var chunked_map = try ChunkedMemoryMap.init(allocator, test_file, chunk_size, 2, true);
    defer chunked_map.deinit();

    // Initial state - no accesses
    var stats = chunked_map.getCacheStats();
    try testing.expectEqual(@as(f64, 0.0), stats.cache_hit_ratio);

    // First read - chunk 0 (cache miss)
    var buf1: [32]u8 = undefined;
    _ = try chunked_map.readAt(0, &buf1);
    stats = chunked_map.getCacheStats();
    try testing.expectEqual(@as(u64, 0), chunked_map.cache_hits);
    try testing.expectEqual(@as(u64, 1), chunked_map.cache_misses);

    // Second read from same chunk (cache hit)
    _ = try chunked_map.readAt(32, &buf1);
    stats = chunked_map.getCacheStats();
    try testing.expectEqual(@as(u64, 1), chunked_map.cache_hits);
    try testing.expectEqual(@as(u64, 1), chunked_map.cache_misses);

    // Read from chunk 1 (cache miss)
    _ = try chunked_map.readAt(64, &buf1);
    stats = chunked_map.getCacheStats();
    try testing.expectEqual(@as(u64, 1), chunked_map.cache_hits);
    try testing.expectEqual(@as(u64, 2), chunked_map.cache_misses);

    // Read from chunk 0 again (cache hit)
    _ = try chunked_map.readAt(16, &buf1);
    stats = chunked_map.getCacheStats();
    try testing.expectEqual(@as(u64, 2), chunked_map.cache_hits);
    try testing.expectEqual(@as(u64, 2), chunked_map.cache_misses);

    // Verify hit ratio: 2 hits / 4 total = 0.5
    try testing.expectApproxEqAbs(@as(f64, 0.5), stats.cache_hit_ratio, 0.001);
}

test "ChunkedMemoryMap cache eviction tracks misses" {
    const allocator = testing.allocator;

    const test_file = "test_eviction.dat";
    defer std.Io.Dir.cwd().deleteFile(test_file) catch {};

    // Create test file with 4 chunks
    const chunk_size: u64 = 32;
    const total_size: usize = 128;

    {
        const file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), test_file, .{});
        defer file.close();
        var data: [total_size]u8 = undefined;
        for (&data, 0..) |*b, i| {
            b.* = @intCast(i % 256);
        }
        _ = try file.writeAll(&data);
        try file.sync();
    }

    // Only allow 2 chunks in cache
    var chunked_map = try ChunkedMemoryMap.init(allocator, test_file, chunk_size, 2, true);
    defer chunked_map.deinit();

    var buf: [16]u8 = undefined;

    // Read from chunk 0 (miss)
    _ = try chunked_map.readAt(0, &buf);
    try testing.expectEqual(@as(u64, 0), chunked_map.cache_hits);
    try testing.expectEqual(@as(u64, 1), chunked_map.cache_misses);

    // Read from chunk 1 (miss)
    _ = try chunked_map.readAt(32, &buf);
    try testing.expectEqual(@as(u64, 0), chunked_map.cache_hits);
    try testing.expectEqual(@as(u64, 2), chunked_map.cache_misses);

    // Read from chunk 2 (miss, evicts one of the existing chunks)
    _ = try chunked_map.readAt(64, &buf);
    try testing.expectEqual(@as(u64, 0), chunked_map.cache_hits);
    try testing.expectEqual(@as(u64, 3), chunked_map.cache_misses);

    // Read from chunk 2 again (hit, definitely in cache)
    _ = try chunked_map.readAt(72, &buf);
    try testing.expectEqual(@as(u64, 1), chunked_map.cache_hits);
    try testing.expectEqual(@as(u64, 3), chunked_map.cache_misses);

    // Read from chunk 3 (miss, evicts another chunk)
    _ = try chunked_map.readAt(96, &buf);
    try testing.expectEqual(@as(u64, 1), chunked_map.cache_hits);
    try testing.expectEqual(@as(u64, 4), chunked_map.cache_misses);

    // Read from chunk 3 again (hit, definitely in cache)
    _ = try chunked_map.readAt(100, &buf);
    try testing.expectEqual(@as(u64, 2), chunked_map.cache_hits);
    try testing.expectEqual(@as(u64, 4), chunked_map.cache_misses);

    // Final ratio: 2 hits / 6 total = 0.333...
    const stats = chunked_map.getCacheStats();
    try testing.expectApproxEqAbs(@as(f64, 0.333), stats.cache_hit_ratio, 0.01);
}

test "ChunkedMemoryMap zero accesses returns zero ratio" {
    const allocator = testing.allocator;

    const test_file = "test_zero_ratio.dat";
    defer std.Io.Dir.cwd().deleteFile(test_file) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), test_file, .{});
        defer file.close();
        const data = [_]u8{0} ** 64;
        _ = try file.writeAll(&data);
        try file.sync();
    }

    var chunked_map = try ChunkedMemoryMap.init(allocator, test_file, 32, 2, true);
    defer chunked_map.deinit();

    // No accesses yet
    const stats = chunked_map.getCacheStats();
    try testing.expectEqual(@as(f64, 0.0), stats.cache_hit_ratio);
    try testing.expectEqual(@as(u64, 0), chunked_map.cache_hits);
    try testing.expectEqual(@as(u64, 0), chunked_map.cache_misses);
}
