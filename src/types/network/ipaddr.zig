const std = @import("std");

// CANARY: REQ=REQ-GQL-NET-TYPES-001; FEATURE="IpAddr Network Type"; ASPECT=Types; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_NET_TYPES_001_IpAddr; OWNER=types; UPDATED=2025-01-03

/// IP Address type supporting both IPv4 and IPv6
/// Stores addresses in canonical binary format for efficient operations
pub const IpAddr = union(enum) {
    v4: IPv4Addr,
    v6: IPv6Addr,

    const IPv4Addr = struct {
        octets: [4]u8,

        pub fn fromString(addr_str: []const u8) !IPv4Addr {
            var parts = std.mem.splitSequence(u8, addr_str, ".");
            var octets: [4]u8 = undefined;
            var i: usize = 0;

            while (parts.next()) |part| {
                if (i >= 4) return error.InvalidIPv4Format;
                const octet = std.fmt.parseInt(u8, part, 10) catch return error.InvalidIPv4Format;
                octets[i] = octet;
                i += 1;
            }

            if (i != 4) return error.InvalidIPv4Format;
            return IPv4Addr{ .octets = octets };
        }

        pub fn toString(self: IPv4Addr, allocator: std.mem.Allocator) ![]u8 {
            return std.fmt.allocPrint(allocator, "{}.{}.{}.{}", .{ self.octets[0], self.octets[1], self.octets[2], self.octets[3] });
        }

        pub fn isPrivate(self: IPv4Addr) bool {
            // RFC 1918 private address ranges
            // 10.0.0.0/8
            if (self.octets[0] == 10) return true;
            // 172.16.0.0/12
            if (self.octets[0] == 172 and (self.octets[1] >= 16 and self.octets[1] <= 31)) return true;
            // 192.168.0.0/16
            if (self.octets[0] == 192 and self.octets[1] == 168) return true;
            return false;
        }

        pub fn isLoopback(self: IPv4Addr) bool {
            // 127.0.0.0/8
            return self.octets[0] == 127;
        }

        pub fn isMulticast(self: IPv4Addr) bool {
            // 224.0.0.0/4
            return (self.octets[0] & 0xF0) == 0xE0;
        }
    };

    const IPv6Addr = struct {
        segments: [8]u16,

        pub fn fromString(addr_str: []const u8) !IPv6Addr {
            // Handle IPv6 address parsing with :: expansion
            var segments: [8]u16 = [_]u16{0} ** 8;

            // Find double colon position for zero compression
            const double_colon_pos = std.mem.indexOf(u8, addr_str, "::");

            if (double_colon_pos) |pos| {
                // Handle zero compression
                const before_parts = std.mem.splitSequence(u8, addr_str[0..pos], ":");
                const after_parts = if (pos + 2 < addr_str.len)
                    std.mem.splitSequence(u8, addr_str[pos + 2 ..], ":")
                else
                    std.mem.splitSequence(u8, "", ":");

                var before_count: usize = 0;
                var before_iter = before_parts;
                while (before_iter.next()) |part| {
                    if (part.len == 0) continue;
                    segments[before_count] = std.fmt.parseInt(u16, part, 16) catch return error.InvalidIPv6Format;
                    before_count += 1;
                }

                var after_parts_list: [8][]const u8 = undefined;
                var after_count: usize = 0;
                var after_iter = after_parts;
                while (after_iter.next()) |part| {
                    if (part.len == 0) continue;
                    after_parts_list[after_count] = part;
                    after_count += 1;
                }

                // Fill in after parts from the end
                for (0..after_count) |i| {
                    const segment_idx = 8 - after_count + i;
                    segments[segment_idx] = std.fmt.parseInt(u16, after_parts_list[i], 16) catch return error.InvalidIPv6Format;
                }
            } else {
                // No zero compression, parse all segments
                var parts = std.mem.splitSequence(u8, addr_str, ":");
                var i: usize = 0;
                while (parts.next()) |part| {
                    if (i >= 8) return error.InvalidIPv6Format;
                    segments[i] = std.fmt.parseInt(u16, part, 16) catch return error.InvalidIPv6Format;
                    i += 1;
                }
                if (i != 8) return error.InvalidIPv6Format;
            }

            return IPv6Addr{ .segments = segments };
        }

        pub fn toString(self: IPv6Addr, allocator: std.mem.Allocator) ![]u8 {
            // RFC 5952 canonical representation
            // Find longest sequence of zero segments for compression
            var best_start: ?usize = null;
            var best_len: usize = 0;
            var current_start: ?usize = null;
            var current_len: usize = 0;

            for (self.segments, 0..) |segment, i| {
                if (segment == 0) {
                    if (current_start == null) {
                        current_start = i;
                        current_len = 1;
                    } else {
                        current_len += 1;
                    }
                } else {
                    if (current_start != null and current_len > best_len) {
                        best_start = current_start;
                        best_len = current_len;
                    }
                    current_start = null;
                    current_len = 0;
                }
            }

            // Check if the last sequence is the best
            if (current_start != null and current_len > best_len) {
                best_start = current_start;
                best_len = current_len;
            }

            var result = try std.ArrayList(u8).initCapacity(allocator, 39); // IPv6 max length
            defer result.deinit(allocator);

            var i: usize = 0;
            while (i < 8) {
                if (best_start != null and i == best_start.? and best_len > 1) {
                    try result.appendSlice(allocator, "::");
                    i += best_len;
                } else {
                    if (i > 0 and !(best_start != null and i == best_start.? + best_len)) {
                        try result.append(allocator, ':');
                    }
                    try result.writer(allocator).print("{x}", .{self.segments[i]});
                    i += 1;
                }
            }

            return result.toOwnedSlice(allocator);
        }

        pub fn isLoopback(self: IPv6Addr) bool {
            // ::1
            for (self.segments[0..7]) |segment| {
                if (segment != 0) return false;
            }
            return self.segments[7] == 1;
        }

        pub fn isMulticast(self: IPv6Addr) bool {
            // ff00::/8
            return (self.segments[0] & 0xFF00) == 0xFF00;
        }
    };

    pub fn fromString(addr_str: []const u8) !IpAddr {
        // Detect IPv4 vs IPv6 by presence of colons
        if (std.mem.indexOf(u8, addr_str, ":") != null) {
            const v6 = try IPv6Addr.fromString(addr_str);
            return IpAddr{ .v6 = v6 };
        } else {
            const v4 = try IPv4Addr.fromString(addr_str);
            return IpAddr{ .v4 = v4 };
        }
    }

    pub fn toString(self: IpAddr, allocator: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .v4 => |addr| addr.toString(allocator),
            .v6 => |addr| addr.toString(allocator),
        };
    }

    pub fn family(self: IpAddr) u8 {
        return switch (self) {
            .v4 => 4,
            .v6 => 6,
        };
    }

    pub fn isPrivate(self: IpAddr) bool {
        return switch (self) {
            .v4 => |addr| addr.isPrivate(),
            .v6 => false, // IPv6 private ranges more complex, simplified for now
        };
    }

    pub fn isLoopback(self: IpAddr) bool {
        return switch (self) {
            .v4 => |addr| addr.isLoopback(),
            .v6 => |addr| addr.isLoopback(),
        };
    }

    pub fn isMulticast(self: IpAddr) bool {
        return switch (self) {
            .v4 => |addr| addr.isMulticast(),
            .v6 => |addr| addr.isMulticast(),
        };
    }

    // Binary encoding for storage
    pub fn encode(self: IpAddr, writer: anytype) !void {
        switch (self) {
            .v4 => |addr| {
                try writer.writeByte(0x04); // IPv4 tag
                try writer.writeAll(&addr.octets);
            },
            .v6 => |addr| {
                try writer.writeByte(0x05); // IPv6 tag
                for (addr.segments) |segment| {
                    try writer.writeInt(u16, segment, .big);
                }
            },
        }
    }

    pub fn decode(reader: anytype) !IpAddr {
        const tag = try reader.takeByte();
        return switch (tag) {
            0x04 => {
                var octets: [4]u8 = undefined;
                try reader.readNoEof(&octets);
                return IpAddr{ .v4 = IPv4Addr{ .octets = octets } };
            },
            0x05 => {
                var segments: [8]u16 = undefined;
                for (&segments) |*segment| {
                    segment.* = try reader.takeInt(u16, .big);
                }
                return IpAddr{ .v6 = IPv6Addr{ .segments = segments } };
            },
            else => error.InvalidIPAddrTag,
        };
    }
};

// Test suite
test "IPv4 address parsing and formatting" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test valid IPv4 addresses
    const addr1 = try IpAddr.fromString("192.168.1.1");
    try testing.expect(addr1 == .v4);
    try testing.expect(addr1.family() == 4);

    const addr1_str = try addr1.toString(allocator);
    defer allocator.free(addr1_str);
    try testing.expectEqualStrings("192.168.1.1", addr1_str);

    // Test private address detection
    try testing.expect(addr1.isPrivate());

    const public_addr = try IpAddr.fromString("8.8.8.8");
    try testing.expect(!public_addr.isPrivate());

    // Test loopback
    const loopback = try IpAddr.fromString("127.0.0.1");
    try testing.expect(loopback.isLoopback());
}

test "IPv6 address parsing and formatting" {
    const testing = std.testing;

    // Test full IPv6 address
    const addr1 = try IpAddr.fromString("2001:db8:85a3:8d3:1319:8a2e:370:7344");
    try testing.expect(addr1 == .v6);
    try testing.expect(addr1.family() == 6);

    // Test IPv6 loopback
    const loopback = try IpAddr.fromString("::1");
    try testing.expect(loopback.isLoopback());

    // Test zero compression
    const compressed = try IpAddr.fromString("2001:db8::1");
    try testing.expect(compressed == .v6);
}

test "IP address encoding/decoding" {
    const testing = std.testing;
    var buffer: [32]u8 = undefined;
    var fbs = std.Io.fixedBufferStream(&buffer);

    // Test IPv4 round-trip
    const ipv4 = try IpAddr.fromString("192.168.1.100");
    try ipv4.encode(fbs.writer());

    fbs.pos = 0;
    const decoded_ipv4 = try IpAddr.decode(fbs.reader());
    try testing.expect(decoded_ipv4 == .v4);
    try testing.expectEqual(ipv4.v4.octets, decoded_ipv4.v4.octets);

    // Test IPv6 round-trip
    fbs.pos = 0;
    const ipv6 = try IpAddr.fromString("2001:db8::1");
    try ipv6.encode(fbs.writer());

    fbs.pos = 0;
    const decoded_ipv6 = try IpAddr.decode(fbs.reader());
    try testing.expect(decoded_ipv6 == .v6);
    try testing.expectEqual(ipv6.v6.segments, decoded_ipv6.v6.segments);
}
