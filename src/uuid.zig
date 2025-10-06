const std = @import("std");

/// UUIDv7 implementation for unique, sortable, indexable IDs
/// Format: timestamp (48 bits) | version (4 bits) | random (12 bits) | variant (2 bits) | random (62 bits)
pub const UuidV7 = struct {
    bytes: [16]u8,

    const Self = @This();

    /// Generate a new UUIDv7
    pub fn new() Self {
        var uuid = Self{ .bytes = undefined };
        
        // Get current timestamp in milliseconds since Unix epoch
        const timestamp_ms = @as(u64, @intCast(std.time.milliTimestamp()));
        
        // First 48 bits: timestamp
        uuid.bytes[0] = @truncate(timestamp_ms >> 40);
        uuid.bytes[1] = @truncate(timestamp_ms >> 32);
        uuid.bytes[2] = @truncate(timestamp_ms >> 24);
        uuid.bytes[3] = @truncate(timestamp_ms >> 16);
        uuid.bytes[4] = @truncate(timestamp_ms >> 8);
        uuid.bytes[5] = @truncate(timestamp_ms);
        
        // Generate random bytes for the rest
        const seed: u64 = @as(u64, @intCast(std.time.nanoTimestamp()));
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        
        // Bytes 6-7: version (0111) and random
        uuid.bytes[6] = 0x70 | (random.int(u8) & 0x0F); // Version 7
        uuid.bytes[7] = random.int(u8);
        
        // Byte 8: variant (10) and random
        uuid.bytes[8] = 0x80 | (random.int(u8) & 0x3F); // Variant 10
        
        // Bytes 9-15: random
        random.bytes(uuid.bytes[9..16]);
        
        return uuid;
    }

    /// Create from existing bytes
    pub fn fromBytes(bytes: [16]u8) Self {
        return Self{ .bytes = bytes };
    }

    /// Create from hex string
    pub fn fromString(str: []const u8) !Self {
        if (str.len != 36 and str.len != 32) return error.InvalidUuidString;
        
        var uuid = Self{ .bytes = undefined };
        var byte_idx: usize = 0;
        var str_idx: usize = 0;
        
        while (byte_idx < 16 and str_idx < str.len) {
            // Skip hyphens
            if (str[str_idx] == '-') {
                str_idx += 1;
                continue;
            }
            
            if (str_idx + 1 >= str.len) return error.InvalidUuidString;
            
            const high = try std.fmt.charToDigit(str[str_idx], 16);
            const low = try std.fmt.charToDigit(str[str_idx + 1], 16);
            
            uuid.bytes[byte_idx] = (high << 4) | low;
            byte_idx += 1;
            str_idx += 2;
        }
        
        if (byte_idx != 16) return error.InvalidUuidString;
        
        return uuid;
    }

    /// Convert to string representation (with hyphens)
    pub fn toString(self: Self, allocator: std.mem.Allocator) ![]u8 {
        const str = try allocator.alloc(u8, 36);
        _ = try std.fmt.bufPrint(str, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
            self.bytes[0],  self.bytes[1],  self.bytes[2],  self.bytes[3],
            self.bytes[4],  self.bytes[5],  self.bytes[6],  self.bytes[7],
            self.bytes[8],  self.bytes[9],  self.bytes[10], self.bytes[11],
            self.bytes[12], self.bytes[13], self.bytes[14], self.bytes[15],
        });
        return str;
    }

    /// Convert to string without allocator (uses a buffer)
    pub fn toStringBuf(self: Self, buf: []u8) ![]u8 {
        if (buf.len < 36) return error.BufferTooSmall;
        return try std.fmt.bufPrint(buf, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
            self.bytes[0],  self.bytes[1],  self.bytes[2],  self.bytes[3],
            self.bytes[4],  self.bytes[5],  self.bytes[6],  self.bytes[7],
            self.bytes[8],  self.bytes[9],  self.bytes[10], self.bytes[11],
            self.bytes[12], self.bytes[13], self.bytes[14], self.bytes[15],
        });
    }

    /// Compare for ordering (lexicographical on bytes)
    pub fn compare(self: Self, other: Self) std.math.Order {
        return std.mem.order(u8, &self.bytes, &other.bytes);
    }

    /// Check equality
    pub fn eql(self: Self, other: Self) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    /// Get timestamp portion (first 48 bits) as milliseconds since Unix epoch
    pub fn getTimestamp(self: Self) u64 {
        return (@as(u64, self.bytes[0]) << 40) |
               (@as(u64, self.bytes[1]) << 32) |
               (@as(u64, self.bytes[2]) << 24) |
               (@as(u64, self.bytes[3]) << 16) |
               (@as(u64, self.bytes[4]) << 8) |
               @as(u64, self.bytes[5]);
    }

    /// Hash function for use in hash maps
    pub fn hash(self: Self, hasher: anytype) void {
        hasher.update(&self.bytes);
    }

    /// Context for AutoHashMap
    pub const HashContext = struct {
        pub fn hash(_: @This(), key: UuidV7) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(&key.bytes);
            return hasher.final();
        }
        
        pub fn eql(_: @This(), a: UuidV7, b: UuidV7) bool {
            return a.eql(b);
        }
    };

    /// Format function for std.fmt
    pub fn format(self: Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        var buf: [36]u8 = undefined;
        const str = try self.toStringBuf(&buf);
        try writer.writeAll(str);
    }
};

test "UUIDv7 generation" {
    const uuid1 = UuidV7.new();
    const uuid2 = UuidV7.new();
    
    // UUIDs should be different
    try std.testing.expect(!uuid1.eql(uuid2));
    
    // Version should be 7 (0111 in bits 48-51)
    try std.testing.expect((uuid1.bytes[6] & 0xF0) == 0x70);
    try std.testing.expect((uuid2.bytes[6] & 0xF0) == 0x70);
    
    // Variant should be 10 (10 in bits 64-65)
    try std.testing.expect((uuid1.bytes[8] & 0xC0) == 0x80);
    try std.testing.expect((uuid2.bytes[8] & 0xC0) == 0x80);
}

test "UUIDv7 string conversion" {
    const allocator = std.testing.allocator;
    const uuid = UuidV7.new();
    
    const str = try uuid.toString(allocator);
    defer allocator.free(str);
    
    // Should be 36 characters (32 hex + 4 hyphens)
    try std.testing.expectEqual(@as(usize, 36), str.len);
    
    // Parse it back
    const parsed = try UuidV7.fromString(str);
    try std.testing.expect(uuid.eql(parsed));
}

test "UUIDv7 ordering" {
    // Generate UUIDs with slight delay to ensure different timestamps
    const uuid1 = UuidV7.new();
    std.time.sleep(1_000_000); // 1ms
    const uuid2 = UuidV7.new();
    
    // uuid2 should be greater than uuid1 due to later timestamp
    try std.testing.expect(uuid1.compare(uuid2) == .lt);
}