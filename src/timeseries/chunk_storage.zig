const std = @import("std");
const timeseries = @import("timeseries.zig");

/// Gorilla-inspired compression for time-series data
/// Each chunk holds up to 4096 points compressed
pub const ChunkConfig = struct {
    max_points_per_chunk: usize = 4096,
    compression_algorithm: CompressionAlgorithm = .gorilla,
    retention_days: u32 = 30,
};

pub const CompressionAlgorithm = enum {
    none,
    gorilla,
    delta_of_delta,
    zstd,
};

/// Compressed chunk metadata
pub const ChunkMeta = struct {
    series_id: u64,
    start_ts: i64,
    end_ts: i64,
    num_points: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    compression: CompressionAlgorithm,
    page_offset: u64, // Offset in storage file
};

/// Gorilla compression context
const GorillaEncoder = struct {
    bits: std.DynamicBitSet,
    prev_ts: i64,
    prev_delta: i64,
    prev_value: i64,
    prev_xor: u64,
    prev_leading: u8,
    prev_trailing: u8,

    pub fn init(allocator: std.mem.Allocator) !GorillaEncoder {
        return .{
            .bits = try std.DynamicBitSet.initEmpty(allocator, 65536),
            .prev_ts = 0,
            .prev_delta = 0,
            .prev_value = 0,
            .prev_xor = 0,
            .prev_leading = 0,
            .prev_trailing = 0,
        };
    }

    pub fn deinit(self: *GorillaEncoder) void {
        self.bits.deinit();
    }

    /// Encode a time-series point using Gorilla compression
    pub fn encodePoint(self: *GorillaEncoder, point: timeseries.Point) !void {
        // First point - store raw values
        if (self.prev_ts == 0) {
            try self.writeRaw(64, @bitCast(point.ts));
            try self.writeRaw(64, @bitCast(point.value));
            self.prev_ts = point.ts;
            self.prev_value = point.value;
            return;
        }

        // Encode timestamp using delta-of-delta
        const delta = point.ts - self.prev_ts;
        const delta_of_delta = delta - self.prev_delta;

        if (delta_of_delta == 0) {
            try self.writeBit(0);
        } else if (delta_of_delta >= -63 and delta_of_delta <= 64) {
            try self.writeBits(2, 0b10);
            try self.writeBits(7, @bitCast(@as(i8, @intCast(delta_of_delta))));
        } else if (delta_of_delta >= -255 and delta_of_delta <= 256) {
            try self.writeBits(3, 0b110);
            try self.writeBits(9, @bitCast(@as(i16, @intCast(delta_of_delta))));
        } else if (delta_of_delta >= -2047 and delta_of_delta <= 2048) {
            try self.writeBits(4, 0b1110);
            try self.writeBits(12, @bitCast(@as(i16, @intCast(delta_of_delta))));
        } else {
            try self.writeBits(4, 0b1111);
            try self.writeBits(32, @bitCast(@as(i32, @intCast(delta_of_delta))));
        }

        self.prev_delta = delta;
        self.prev_ts = point.ts;

        // Encode value using XOR compression
        const xor: u64 = @bitCast(point.value ^ self.prev_value);

        if (xor == 0) {
            try self.writeBit(0);
        } else {
            try self.writeBit(1);

            const leading = @clz(xor);
            const trailing = @ctz(xor);

            if (leading >= self.prev_leading and trailing >= self.prev_trailing) {
                try self.writeBit(0);
                const significant_bits = 64 - self.prev_leading - self.prev_trailing;
                const shifted = xor >> @intCast(self.prev_trailing);
                try self.writeBits(@intCast(significant_bits), shifted);
            } else {
                try self.writeBit(1);
                try self.writeBits(5, leading);
                const significant_bits = 64 - leading - trailing;
                try self.writeBits(6, significant_bits);
                const shifted = xor >> @intCast(trailing);
                try self.writeBits(@intCast(significant_bits), shifted);

                self.prev_leading = leading;
                self.prev_trailing = trailing;
            }
        }

        self.prev_value = point.value;
        self.prev_xor = xor;
    }

    fn writeBit(self: *GorillaEncoder, bit: u1) !void {
        const idx = self.bits.count();
        if (idx >= self.bits.capacity()) {
            try self.bits.resize(self.bits.capacity() * 2, false);
        }
        self.bits.setValue(idx, bit == 1);
        self.bits.setRangeValue(.{ .start = idx + 1, .end = idx + 1 }, false);
    }

    fn writeBits(self: *GorillaEncoder, num_bits: u8, value: u64) !void {
        var i: u8 = num_bits;
        while (i > 0) : (i -= 1) {
            const bit: u1 = @intCast((value >> @intCast(i - 1)) & 1);
            try self.writeBit(bit);
        }
    }

    fn writeRaw(self: *GorillaEncoder, num_bits: u8, value: u64) !void {
        try self.writeBits(num_bits, value);
    }

    pub fn getCompressedData(self: *GorillaEncoder, allocator: std.mem.Allocator) ![]u8 {
        const bit_count = self.bits.count();
        const byte_count = (bit_count + 7) / 8;
        var result = try allocator.alloc(u8, byte_count);

        var i: usize = 0;
        while (i < byte_count) : (i += 1) {
            var byte: u8 = 0;
            var j: usize = 0;
            while (j < 8 and i * 8 + j < bit_count) : (j += 1) {
                if (self.bits.isSet(i * 8 + j)) {
                    byte |= @as(u8, 1) << @intCast(7 - j);
                }
            }
            result[i] = byte;
        }

        return result;
    }
};

/// Chunk storage manager
pub const ChunkStorage = struct {
    allocator: std.mem.Allocator,
    config: ChunkConfig,
    chunks: std.ArrayList(ChunkMeta),
    index: std.AutoHashMap(u64, std.ArrayList(usize)), // series_id -> chunk indices
    data_file: ?std.fs.File,
    data_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8, config: ChunkConfig) !ChunkStorage {
        // Ensure data directory exists
        std.fs.cwd().makePath(data_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const chunks_path = try std.fmt.allocPrint(allocator, "{s}/chunks.dat", .{data_dir});
        defer allocator.free(chunks_path);

        const file = try std.fs.cwd().createFile(chunks_path, .{
            .read = true,
            .truncate = false,
        });

        return .{
            .allocator = allocator,
            .config = config,
            .chunks = std.ArrayList(ChunkMeta).init(allocator),
            .index = std.AutoHashMap(u64, std.ArrayList(usize)).init(allocator),
            .data_file = file,
            .data_dir = try allocator.dupe(u8, data_dir),
        };
    }

    pub fn deinit(self: *ChunkStorage) void {
        var it = self.index.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.index.deinit();
        self.chunks.deinit();
        if (self.data_file) |file| {
            file.close();
        }
        self.allocator.free(self.data_dir);
    }

    /// Write a batch of points to chunks
    pub fn writePoints(self: *ChunkStorage, series_id: u64, points: []const timeseries.Point) !void {
        if (points.len == 0) return;

        var encoder = try GorillaEncoder.init(self.allocator);
        defer encoder.deinit();

        // Encode points
        for (points) |point| {
            try encoder.encodePoint(point);
        }

        // Get compressed data
        const compressed = try encoder.getCompressedData(self.allocator);
        defer self.allocator.free(compressed);

        // Create chunk metadata
        const meta = ChunkMeta{
            .series_id = series_id,
            .start_ts = points[0].ts,
            .end_ts = points[points.len - 1].ts,
            .num_points = @intCast(points.len),
            .compressed_size = @intCast(compressed.len),
            .uncompressed_size = @intCast(points.len * @sizeOf(timeseries.Point)),
            .compression = self.config.compression_algorithm,
            .page_offset = if (self.data_file) |f| try f.getPos() else 0,
        };

        // Write compressed data to file
        if (self.data_file) |file| {
            _ = try file.write(compressed);
        }

        // Update index
        const chunk_idx = self.chunks.items.len;
        try self.chunks.append(meta);

        var indices = self.index.get(series_id) orelse std.ArrayList(usize).init(self.allocator);
        try indices.append(chunk_idx);
        try self.index.put(series_id, indices);
    }

    /// Query chunks for a time range
    pub fn queryRange(
        self: *ChunkStorage,
        series_id: u64,
        start_ts: i64,
        end_ts: i64,
        allocator: std.mem.Allocator,
    ) ![]timeseries.Point {
        const indices = self.index.get(series_id) orelse return &.{};

        var results = std.ArrayList(timeseries.Point).init(allocator);
        defer results.deinit();

        for (indices.items) |idx| {
            const chunk = self.chunks.items[idx];

            // Skip chunks outside time range
            if (chunk.end_ts < start_ts or chunk.start_ts > end_ts) continue;

            // For now, return empty - decompression would go here
            // This is a scaffold for actual decompression implementation
        }

        return try results.toOwnedSlice();
    }

    /// Run retention policy to prune old chunks
    pub fn runRetention(self: *ChunkStorage, current_time: i64) !void {
        const retention_ms = @as(i64, self.config.retention_days) * 24 * 60 * 60 * 1000;
        const cutoff_time = current_time - retention_ms;

        var new_chunks = std.ArrayList(ChunkMeta).init(self.allocator);
        defer new_chunks.deinit();

        // Clear index
        var it = self.index.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.index.clearAndFree();

        // Rebuild index with non-expired chunks
        for (self.chunks.items, 0..) |chunk, i| {
            if (chunk.end_ts >= cutoff_time) {
                try new_chunks.append(chunk);

                var indices = self.index.get(chunk.series_id) orelse
                    std.ArrayList(usize).init(self.allocator);
                try indices.append(new_chunks.items.len - 1);
                try self.index.put(chunk.series_id, indices);
            }
        }

        self.chunks.deinit();
        self.chunks = new_chunks;
    }

    /// Get compression ratio statistics
    pub fn getCompressionStats(self: *ChunkStorage) struct {
        total_compressed: u64,
        total_uncompressed: u64,
        ratio: f64,
        avg_chunk_size: f64,
        total_chunks: usize,
    } {
        var total_compressed: u64 = 0;
        var total_uncompressed: u64 = 0;

        for (self.chunks.items) |chunk| {
            total_compressed += chunk.compressed_size;
            total_uncompressed += chunk.uncompressed_size;
        }

        const ratio = if (total_uncompressed > 0)
            @as(f64, @floatFromInt(total_compressed)) / @as(f64, @floatFromInt(total_uncompressed))
        else
            0.0;

        const avg_size = if (self.chunks.items.len > 0)
            @as(f64, @floatFromInt(total_compressed)) / @as(f64, @floatFromInt(self.chunks.items.len))
        else
            0.0;

        return .{
            .total_compressed = total_compressed,
            .total_uncompressed = total_uncompressed,
            .ratio = ratio,
            .avg_chunk_size = avg_size,
            .total_chunks = self.chunks.items.len,
        };
    }
};

test "chunk_storage: compression and stats" {
    const ally = std.testing.allocator;

    // Create temporary directory for test
    const test_dir = "test_chunks";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var storage = try ChunkStorage.init(ally, test_dir, .{});
    defer storage.deinit();

    // Generate test data
    var points = std.ArrayList(timeseries.Point).init(ally);
    defer points.deinit();

    var i: i64 = 0;
    while (i < 100) : (i += 1) {
        try points.append(.{
            .ts = 1000 + i * 1000,
            .value = 100 + i % 10,
        });
    }

    // Write points
    try storage.writePoints(42, points.items);

    // Check compression stats
    const stats = storage.getCompressionStats();
    try std.testing.expect(stats.total_chunks == 1);
    try std.testing.expect(stats.ratio < 1.0); // Should achieve some compression
    try std.testing.expect(stats.total_compressed < stats.total_uncompressed);
}

test "chunk_storage: retention" {
    const ally = std.testing.allocator;

    const test_dir = "test_retention";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var storage = try ChunkStorage.init(ally, test_dir, .{ .retention_days = 1 });
    defer storage.deinit();

    const current_time: i64 = 1000000000;
    const day_ms: i64 = 24 * 60 * 60 * 1000;

    // Add old chunk (should be pruned)
    try storage.writePoints(1, &[_]timeseries.Point{
        .{ .ts = current_time - 2 * day_ms, .value = 1 },
    });

    // Add recent chunk (should be kept)
    try storage.writePoints(2, &[_]timeseries.Point{
        .{ .ts = current_time - 1000, .value = 2 },
    });

    try std.testing.expect(storage.chunks.items.len == 2);

    // Run retention
    try storage.runRetention(current_time);

    // Should only have 1 chunk left
    try std.testing.expect(storage.chunks.items.len == 1);
    try std.testing.expect(storage.chunks.items[0].series_id == 2);
}
