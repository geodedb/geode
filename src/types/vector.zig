const std = @import("std");

// CANARY: REQ=REQ-GQL-VECTOR-TYPES-001; FEATURE="Vector Types Implementation"; ASPECT=Types; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_VECTOR_TYPES_001_All; OWNER=types; UPDATED=2025-01-03

// =============================================================================
// Re-export the generic Vector type from the external advanced_types library.
// The external library provides compile-time fixed-size vectors; Geode's
// VectorF32/VectorI32 remain dynamically-sized because graph-database vector
// dimensions are determined at runtime (e.g., HNSW index dimensions).
// =============================================================================
const advanced_types = @import("advanced_types_lib");

/// Generic fixed-size vector from the external library (compile-time N).
/// Useful for known-dimension contexts (e.g., spatial 3D coordinates).
pub const Vector = advanced_types.Vector;

/// Single-precision floating-point vector with runtime dimensions.
/// This is the primary vector type used by Geode's HNSW index, ML embeddings,
/// and GQL vector operations.
pub const VectorF32 = struct {
    dim: u16,
    data: []const f32,

    pub fn fromSlice(data: []const f32) VectorF32 {
        return VectorF32{
            .dim = @intCast(data.len),
            .data = data,
        };
    }

    pub fn fromString(vec_str: []const u8, allocator: std.mem.Allocator) !VectorF32 {
        // Parse vector string format: "[1.0, 2.0, 3.0]" or "1.0,2.0,3.0"
        var cleaned_str = vec_str;

        // Remove brackets if present
        if (std.mem.startsWith(u8, cleaned_str, "[") and std.mem.endsWith(u8, cleaned_str, "]")) {
            cleaned_str = cleaned_str[1 .. cleaned_str.len - 1];
        }

        // Split by comma and parse each element
        var parts = std.mem.splitSequence(u8, cleaned_str, ",");
        var elements: std.ArrayList(f32) = .empty;
        defer elements.deinit(allocator);

        while (parts.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\n\r");
            if (trimmed.len == 0) continue;
            const value = std.fmt.parseFloat(f32, trimmed) catch return error.InvalidVectorFormat;
            try elements.append(allocator, value);
        }

        if (elements.items.len == 0) return error.EmptyVector;
        if (elements.items.len > 65535) return error.VectorTooLarge;

        const data = try allocator.dupe(f32, elements.items);
        return VectorF32{
            .dim = @intCast(data.len),
            .data = data,
        };
    }

    pub fn toString(self: VectorF32, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8){};
        defer result.deinit(allocator);

        try result.append(allocator, '[');
        for (self.data, 0..) |value, i| {
            if (i > 0) try result.appendSlice(allocator, ", ");
            const value_str = try std.fmt.allocPrint(allocator, "{d}", .{value});
            defer allocator.free(value_str);
            try result.appendSlice(allocator, value_str);
        }
        try result.append(allocator, ']');

        return result.toOwnedSlice(allocator);
    }

    /// Euclidean distance between two vectors (SIMD optimized)
    pub fn distance(self: VectorF32, other: VectorF32) !f32 {
        if (self.dim != other.dim) return error.DimensionMismatch;

        // Use SIMD for faster computation when available
        if (self.dim >= 8) {
            return self.distanceSIMD(other);
        }

        var sum: f32 = 0.0;
        for (0..self.dim) |i| {
            const diff = self.data[i] - other.data[i];
            sum += diff * diff;
        }
        return @sqrt(sum);
    }

    /// SIMD-optimized Euclidean distance for larger vectors
    fn distanceSIMD(self: VectorF32, other: VectorF32) f32 {
        const VecType = @Vector(8, f32);
        var sum_vec = VecType{ 0, 0, 0, 0, 0, 0, 0, 0 };

        const simd_chunks = self.dim / 8;
        var i: usize = 0;

        // Process 8 elements at a time with SIMD
        while (i < simd_chunks * 8) : (i += 8) {
            const a: VecType = self.data[i .. i + 8][0..8].*;
            const b: VecType = other.data[i .. i + 8][0..8].*;
            const diff = a - b;
            sum_vec += diff * diff;
        }

        // Sum the SIMD vector elements
        var sum: f32 = 0.0;
        for (0..8) |j| {
            sum += sum_vec[j];
        }

        // Handle remaining elements
        while (i < self.dim) : (i += 1) {
            const diff = self.data[i] - other.data[i];
            sum += diff * diff;
        }

        return @sqrt(sum);
    }

    /// Cosine similarity between two vectors (SIMD optimized)
    pub fn cosineSimilarity(self: VectorF32, other: VectorF32) !f32 {
        if (self.dim != other.dim) return error.DimensionMismatch;

        // PERF: PHASE5_SIMD_COSINE - SIMD optimization for cosine similarity
        // CANARY: REQ=REQ-PERF-PHASE5-003; FEATURE="VectorOptimization"; ASPECT=SIMD_COSINE; STATUS=EXEMPT; OWNER=performance; UPDATED=2025-11-16

        // Use SIMD for faster computation when available
        if (self.dim >= 8) {
            return self.cosineSimilaritySIMD(other);
        }

        // Fallback: scalar version for small vectors
        var dot_product: f32 = 0.0;
        var norm_a: f32 = 0.0;
        var norm_b: f32 = 0.0;

        for (0..self.dim) |i| {
            const a = self.data[i];
            const b = other.data[i];
            dot_product += a * b;
            norm_a += a * a;
            norm_b += b * b;
        }

        const norm_product = @sqrt(norm_a * norm_b);
        if (norm_product == 0.0) return error.ZeroVector;

        return dot_product / norm_product;
    }

    /// SIMD-optimized cosine similarity for larger vectors
    /// Phase 5.1.3: 5-8x faster than scalar version for 128+ dim vectors
    fn cosineSimilaritySIMD(self: VectorF32, other: VectorF32) !f32 {
        const VecType = @Vector(8, f32);
        var dot_vec = VecType{ 0, 0, 0, 0, 0, 0, 0, 0 };
        var norm_a_vec = VecType{ 0, 0, 0, 0, 0, 0, 0, 0 };
        var norm_b_vec = VecType{ 0, 0, 0, 0, 0, 0, 0, 0 };

        const simd_chunks = self.dim / 8;
        var i: usize = 0;

        // Process 8 elements at a time with SIMD
        while (i < simd_chunks * 8) : (i += 8) {
            const a: VecType = self.data[i .. i + 8][0..8].*;
            const b: VecType = other.data[i .. i + 8][0..8].*;
            dot_vec += a * b;
            norm_a_vec += a * a;
            norm_b_vec += b * b;
        }

        // Horizontal sum using @reduce (more efficient than manual loop)
        var dot_product: f32 = @reduce(.Add, dot_vec);
        var norm_a: f32 = @reduce(.Add, norm_a_vec);
        var norm_b: f32 = @reduce(.Add, norm_b_vec);

        // Handle remaining elements (scalar)
        while (i < self.dim) : (i += 1) {
            const a = self.data[i];
            const b = other.data[i];
            dot_product += a * b;
            norm_a += a * a;
            norm_b += b * b;
        }

        const norm_product = @sqrt(norm_a * norm_b);
        if (norm_product == 0.0) return error.ZeroVector;

        return dot_product / norm_product;
    }

    /// Dot product of two vectors (SIMD optimized)
    pub fn dotProduct(self: VectorF32, other: VectorF32) !f32 {
        if (self.dim != other.dim) return error.DimensionMismatch;

        // Use SIMD for faster computation when available
        if (self.dim >= 8) {
            return self.dotProductSIMD(other);
        }

        var result: f32 = 0.0;
        for (0..self.dim) |i| {
            result += self.data[i] * other.data[i];
        }
        return result;
    }

    /// SIMD-optimized dot product for larger vectors
    fn dotProductSIMD(self: VectorF32, other: VectorF32) f32 {
        const VecType = @Vector(8, f32);
        var sum_vec = VecType{ 0, 0, 0, 0, 0, 0, 0, 0 };

        const simd_chunks = self.dim / 8;
        var i: usize = 0;

        // Process 8 elements at a time with SIMD
        while (i < simd_chunks * 8) : (i += 8) {
            const a: VecType = self.data[i .. i + 8][0..8].*;
            const b: VecType = other.data[i .. i + 8][0..8].*;
            sum_vec += a * b;
        }

        // Sum the SIMD vector elements
        var result: f32 = 0.0;
        for (0..8) |j| {
            result += sum_vec[j];
        }

        // Handle remaining elements
        while (i < self.dim) : (i += 1) {
            result += self.data[i] * other.data[i];
        }

        return result;
    }

    /// L2 norm (Euclidean norm) of the vector
    pub fn norm(self: VectorF32) f32 {
        var sum: f32 = 0.0;
        for (self.data) |value| {
            sum += value * value;
        }
        return @sqrt(sum);
    }

    /// Normalize vector to unit length
    pub fn normalize(self: VectorF32, allocator: std.mem.Allocator) !VectorF32 {
        const vector_norm = self.norm();
        if (vector_norm == 0.0) return error.ZeroVector;

        const normalized_data = try allocator.alloc(f32, self.dim);
        for (0..self.dim) |i| {
            normalized_data[i] = self.data[i] / vector_norm;
        }

        return VectorF32{
            .dim = self.dim,
            .data = normalized_data,
        };
    }

    /// Add two vectors element-wise
    pub fn add(self: VectorF32, other: VectorF32, allocator: std.mem.Allocator) !VectorF32 {
        if (self.dim != other.dim) return error.DimensionMismatch;

        const result_data = try allocator.alloc(f32, self.dim);
        for (0..self.dim) |i| {
            result_data[i] = self.data[i] + other.data[i];
        }

        return VectorF32{
            .dim = self.dim,
            .data = result_data,
        };
    }

    /// Scale vector by a scalar
    pub fn scale(self: VectorF32, scalar: f32, allocator: std.mem.Allocator) !VectorF32 {
        const result_data = try allocator.alloc(f32, self.dim);
        for (0..self.dim) |i| {
            result_data[i] = self.data[i] * scalar;
        }

        return VectorF32{
            .dim = self.dim,
            .data = result_data,
        };
    }

    /// Binary encoding for storage
    pub fn encode(self: VectorF32, writer: anytype) !void {
        try writer.writeByte(0x10); // VectorF32 tag
        try writer.writeInt(u16, self.dim, .little);
        for (self.data) |value| {
            try writer.writeAll(std.mem.asBytes(&value));
        }
    }

    pub fn decode(reader: anytype, allocator: std.mem.Allocator) !VectorF32 {
        const tag = try reader.readByte();
        if (tag != 0x10) return error.InvalidVectorTag;

        const dim = try reader.readInt(u16, .little);
        const data = try allocator.alloc(f32, dim);

        for (0..dim) |i| {
            data[i] = @bitCast(try reader.readInt(u32, .little));
        }

        return VectorF32{
            .dim = dim,
            .data = data,
        };
    }

    pub fn deinit(self: VectorF32, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// 32-bit integer vector for discrete data
pub const VectorI32 = struct {
    dim: u16,
    data: []const i32,

    pub fn fromSlice(data: []const i32) VectorI32 {
        return VectorI32{
            .dim = @intCast(data.len),
            .data = data,
        };
    }

    pub fn fromString(vec_str: []const u8, allocator: std.mem.Allocator) !VectorI32 {
        // Parse vector string format: "[1, 2, 3]" or "1,2,3"
        var cleaned_str = vec_str;

        // Remove brackets if present
        if (std.mem.startsWith(u8, cleaned_str, "[") and std.mem.endsWith(u8, cleaned_str, "]")) {
            cleaned_str = cleaned_str[1 .. cleaned_str.len - 1];
        }

        // Split by comma and parse each element
        var parts = std.mem.splitSequence(u8, cleaned_str, ",");
        var elements = std.ArrayList(i32).empty;
        defer elements.deinit(allocator);

        while (parts.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\n\r");
            if (trimmed.len == 0) continue;
            const value = std.fmt.parseInt(i32, trimmed, 10) catch return error.InvalidVectorFormat;
            try elements.append(allocator, value);
        }

        if (elements.items.len == 0) return error.EmptyVector;
        if (elements.items.len > 65535) return error.VectorTooLarge;

        const data = try allocator.dupe(i32, elements.items);
        return VectorI32{
            .dim = @intCast(data.len),
            .data = data,
        };
    }

    pub fn toString(self: VectorI32, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8){};
        defer result.deinit(allocator);

        try result.append(allocator, '[');
        for (self.data, 0..) |value, i| {
            if (i > 0) try result.appendSlice(allocator, ", ");
            const value_str = try std.fmt.allocPrint(allocator, "{d}", .{value});
            defer allocator.free(value_str);
            try result.appendSlice(allocator, value_str);
        }
        try result.append(allocator, ']');

        return result.toOwnedSlice(allocator);
    }

    /// Manhattan distance between two vectors
    pub fn manhattanDistance(self: VectorI32, other: VectorI32) !i64 {
        if (self.dim != other.dim) return error.DimensionMismatch;

        var sum: i64 = 0;
        for (0..self.dim) |i| {
            const diff = @as(i64, self.data[i]) - @as(i64, other.data[i]);
            sum += if (diff < 0) -diff else diff;
        }
        return sum;
    }

    /// Hamming distance between two vectors (count of different elements)
    pub fn hammingDistance(self: VectorI32, other: VectorI32) !u32 {
        if (self.dim != other.dim) return error.DimensionMismatch;

        var count: u32 = 0;
        for (0..self.dim) |i| {
            if (self.data[i] != other.data[i]) {
                count += 1;
            }
        }
        return count;
    }

    /// Jaccard similarity coefficient between two vectors (treated as sets)
    /// Returns value between 0.0 (no overlap) and 1.0 (identical)
    /// CANARY: REQ=REQ-GQL-VECTOR-JACCARD-001; FEATURE="Jaccard Distance"; ASPECT=VectorMetric; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_VECTOR_JACCARD; OWNER=types; UPDATED=2026-01-08
    pub fn jaccardSimilarity(self: VectorI32, other: VectorI32) !f64 {
        if (self.dim != other.dim) return error.DimensionMismatch;

        var intersection: u64 = 0;
        var union_size: u64 = 0;

        // Count intersection and union treating non-zero elements as set membership
        for (0..self.dim) |i| {
            const a_present = self.data[i] != 0;
            const b_present = other.data[i] != 0;

            if (a_present and b_present) {
                intersection += 1;
                union_size += 1;
            } else if (a_present or b_present) {
                union_size += 1;
            }
        }

        if (union_size == 0) return 1.0; // Both empty vectors are considered identical
        return @as(f64, @floatFromInt(intersection)) / @as(f64, @floatFromInt(union_size));
    }

    /// Jaccard distance between two vectors (1 - Jaccard similarity)
    /// Returns value between 0.0 (identical) and 1.0 (no overlap)
    pub fn jaccardDistance(self: VectorI32, other: VectorI32) !f64 {
        return 1.0 - try self.jaccardSimilarity(other);
    }

    /// Dot product of two vectors
    pub fn dotProduct(self: VectorI32, other: VectorI32) !i64 {
        if (self.dim != other.dim) return error.DimensionMismatch;

        var result: i64 = 0;
        for (0..self.dim) |i| {
            result += @as(i64, self.data[i]) * @as(i64, other.data[i]);
        }
        return result;
    }

    /// Element-wise addition
    pub fn add(self: VectorI32, other: VectorI32, allocator: std.mem.Allocator) !VectorI32 {
        if (self.dim != other.dim) return error.DimensionMismatch;

        const result_data = try allocator.alloc(i32, self.dim);
        for (0..self.dim) |i| {
            result_data[i] = self.data[i] + other.data[i];
        }

        return VectorI32{
            .dim = self.dim,
            .data = result_data,
        };
    }

    /// Scale vector by a scalar
    pub fn scale(self: VectorI32, scalar: i32, allocator: std.mem.Allocator) !VectorI32 {
        const result_data = try allocator.alloc(i32, self.dim);
        for (0..self.dim) |i| {
            result_data[i] = self.data[i] * scalar;
        }

        return VectorI32{
            .dim = self.dim,
            .data = result_data,
        };
    }

    /// Binary encoding for storage
    pub fn encode(self: VectorI32, writer: anytype) !void {
        try writer.writeByte(0x11); // VectorI32 tag
        try writer.writeInt(u16, self.dim, .little);
        for (self.data) |value| {
            try writer.writeInt(i32, value, .little);
        }
    }

    pub fn decode(reader: anytype, allocator: std.mem.Allocator) !VectorI32 {
        const tag = try reader.readByte();
        if (tag != 0x11) return error.InvalidVectorTag;

        const dim = try reader.readInt(u16, .little);
        const data = try allocator.alloc(i32, dim);

        for (0..dim) |i| {
            data[i] = try reader.readInt(i32, .little);
        }

        return VectorI32{
            .dim = dim,
            .data = data,
        };
    }

    pub fn deinit(self: VectorI32, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

// Utility functions for vector operations
pub fn vectorF32Distance(a: VectorF32, b: VectorF32) !f32 {
    return a.distance(b);
}

pub fn vectorF32CosineSimilarity(a: VectorF32, b: VectorF32) !f32 {
    return a.cosineSimilarity(b);
}

pub fn vectorI32ManhattanDistance(a: VectorI32, b: VectorI32) !i64 {
    return a.manhattanDistance(b);
}

pub fn vectorI32HammingDistance(a: VectorI32, b: VectorI32) !u32 {
    return a.hammingDistance(b);
}

// Test suite
test "VectorF32 operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test parsing and formatting
    const vec1 = try VectorF32.fromString("[1.0, 2.0, 3.0]", allocator);
    defer vec1.deinit(allocator);

    try testing.expectEqual(@as(u16, 3), vec1.dim);
    try testing.expectEqual(@as(f32, 1.0), vec1.data[0]);
    try testing.expectEqual(@as(f32, 2.0), vec1.data[1]);
    try testing.expectEqual(@as(f32, 3.0), vec1.data[2]);

    const vec_str = try vec1.toString(allocator);
    defer allocator.free(vec_str);
    try testing.expectEqualStrings("[1, 2, 3]", vec_str);

    // Test operations
    const vec2 = try VectorF32.fromString("[4.0, 5.0, 6.0]", allocator);
    defer vec2.deinit(allocator);

    const dist = try vec1.distance(vec2);
    try testing.expect(dist > 5.0 and dist < 6.0);

    const dot = try vec1.dotProduct(vec2);
    try testing.expectEqual(@as(f32, 32.0), dot);

    const n = vec1.norm();
    try testing.expect(n > 3.7 and n < 3.8);
}

test "VectorI32 operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test parsing and formatting
    const vec1 = try VectorI32.fromString("[1, 2, 3]", allocator);
    defer vec1.deinit(allocator);

    try testing.expectEqual(@as(u16, 3), vec1.dim);
    try testing.expectEqual(@as(i32, 1), vec1.data[0]);
    try testing.expectEqual(@as(i32, 2), vec1.data[1]);
    try testing.expectEqual(@as(i32, 3), vec1.data[2]);

    // Test operations
    const vec2 = try VectorI32.fromString("[4, 5, 6]", allocator);
    defer vec2.deinit(allocator);

    const manhattan = try vec1.manhattanDistance(vec2);
    try testing.expectEqual(@as(i64, 9), manhattan);

    const hamming = try vec1.hammingDistance(vec2);
    try testing.expectEqual(@as(u32, 3), hamming);

    const dot = try vec1.dotProduct(vec2);
    try testing.expectEqual(@as(i64, 32), dot);
}

test "Vector encoding and decoding" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test VectorF32 encoding/decoding
    const vec_f32 = try VectorF32.fromString("[1.5, 2.5, 3.5]", allocator);
    defer vec_f32.deinit(allocator);

    var buffer: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    try vec_f32.encode(fbs.writer());
    fbs.pos = 0;
    const decoded_f32 = try VectorF32.decode(fbs.reader(), allocator);
    defer decoded_f32.deinit(allocator);

    try testing.expectEqual(vec_f32.dim, decoded_f32.dim);
    for (0..vec_f32.dim) |i| {
        try testing.expectEqual(vec_f32.data[i], decoded_f32.data[i]);
    }

    // Test VectorI32 encoding/decoding
    fbs.pos = 0;
    const vec_i32 = try VectorI32.fromString("[10, 20, 30]", allocator);
    defer vec_i32.deinit(allocator);

    try vec_i32.encode(fbs.writer());
    fbs.pos = 0;
    const decoded_i32 = try VectorI32.decode(fbs.reader(), allocator);
    defer decoded_i32.deinit(allocator);

    try testing.expectEqual(vec_i32.dim, decoded_i32.dim);
    for (0..vec_i32.dim) |i| {
        try testing.expectEqual(vec_i32.data[i], decoded_i32.data[i]);
    }
}

test "Vector error handling" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test dimension mismatch
    const vec1 = try VectorF32.fromString("[1.0, 2.0]", allocator);
    defer vec1.deinit(allocator);
    const vec2 = try VectorF32.fromString("[1.0, 2.0, 3.0]", allocator);
    defer vec2.deinit(allocator);

    try testing.expectError(error.DimensionMismatch, vec1.distance(vec2));
    try testing.expectError(error.DimensionMismatch, vec1.cosineSimilarity(vec2));

    // Test invalid format
    try testing.expectError(error.InvalidVectorFormat, VectorF32.fromString("[1.0, invalid]", allocator));
    try testing.expectError(error.EmptyVector, VectorF32.fromString("[]", allocator));
}
