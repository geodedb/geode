const std = @import("std");
const IpAddr = @import("ipaddr.zig").IpAddr;

// CANARY: REQ=REQ-GQL-NET-TYPES-002; FEATURE="Subnet CIDR Type"; ASPECT=Types; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_NET_TYPES_002_Subnet; OWNER=types; UPDATED=2025-01-03

/// CIDR subnet representation supporting both IPv4 and IPv6
/// Stores network address with prefix length for efficient containment operations
pub const Subnet = union(enum) {
    v4: IPv4Subnet,
    v6: IPv6Subnet,

    const IPv4Subnet = struct {
        network: [4]u8, // Network address (host bits zeroed)
        prefix_len: u8, // Prefix length (0-32)

        pub fn fromString(cidr_str: []const u8) !IPv4Subnet {
            const slash_pos = std.mem.indexOf(u8, cidr_str, "/") orelse return error.InvalidCIDRFormat;

            const addr_str = cidr_str[0..slash_pos];
            const prefix_str = cidr_str[slash_pos + 1 ..];

            const prefix_len = std.fmt.parseInt(u8, prefix_str, 10) catch return error.InvalidPrefixLength;
            if (prefix_len > 32) return error.InvalidPrefixLength;

            // Parse the IP address part
            const addr = try IpAddr.fromString(addr_str);
            if (addr != .v4) return error.IPv6InIPv4Subnet;

            // Create network mask and apply it
            const mask = if (prefix_len == 0) 0 else ~@as(u32, 0) << @intCast(32 - prefix_len);
            const addr_int = (@as(u32, addr.v4.octets[0]) << 24) |
                (@as(u32, addr.v4.octets[1]) << 16) |
                (@as(u32, addr.v4.octets[2]) << 8) |
                @as(u32, addr.v4.octets[3]);

            const network_int = addr_int & mask;
            const network = [4]u8{
                @intCast((network_int >> 24) & 0xFF),
                @intCast((network_int >> 16) & 0xFF),
                @intCast((network_int >> 8) & 0xFF),
                @intCast(network_int & 0xFF),
            };

            return IPv4Subnet{
                .network = network,
                .prefix_len = prefix_len,
            };
        }

        pub fn toString(self: IPv4Subnet, allocator: std.mem.Allocator) ![]u8 {
            return std.fmt.allocPrint(allocator, "{}.{}.{}.{}/{}", .{ self.network[0], self.network[1], self.network[2], self.network[3], self.prefix_len });
        }

        pub fn contains(self: IPv4Subnet, addr: IpAddr) bool {
            if (addr != .v4) return false;

            if (self.prefix_len == 0) return true; // 0.0.0.0/0 contains everything

            const mask = ~@as(u32, 0) << @intCast(32 - self.prefix_len);

            const network_int = (@as(u32, self.network[0]) << 24) |
                (@as(u32, self.network[1]) << 16) |
                (@as(u32, self.network[2]) << 8) |
                @as(u32, self.network[3]);

            const addr_int = (@as(u32, addr.v4.octets[0]) << 24) |
                (@as(u32, addr.v4.octets[1]) << 16) |
                (@as(u32, addr.v4.octets[2]) << 8) |
                @as(u32, addr.v4.octets[3]);

            return (network_int & mask) == (addr_int & mask);
        }

        pub fn overlaps(self: IPv4Subnet, other: IPv4Subnet) bool {
            // Two subnets overlap if one contains the network address of the other
            const self_net_addr = IpAddr{ .v4 = .{ .octets = self.network } };
            const other_net_addr = IpAddr{ .v4 = .{ .octets = other.network } };

            return self.contains(other_net_addr) or other.contains(self_net_addr);
        }

        pub fn hostCount(self: IPv4Subnet) u32 {
            if (self.prefix_len >= 32) return 1;
            return @as(u32, 1) << @intCast(32 - self.prefix_len);
        }
    };

    const IPv6Subnet = struct {
        network: [8]u16, // Network address (host bits zeroed)
        prefix_len: u8, // Prefix length (0-128)

        pub fn fromString(cidr_str: []const u8) !IPv6Subnet {
            const slash_pos = std.mem.indexOf(u8, cidr_str, "/") orelse return error.InvalidCIDRFormat;

            const addr_str = cidr_str[0..slash_pos];
            const prefix_str = cidr_str[slash_pos + 1 ..];

            const prefix_len = std.fmt.parseInt(u8, prefix_str, 10) catch return error.InvalidPrefixLength;
            if (prefix_len > 128) return error.InvalidPrefixLength;

            // Parse the IP address part
            const addr = try IpAddr.fromString(addr_str);
            if (addr != .v6) return error.IPv4InIPv6Subnet;

            // Apply network mask to zero host bits
            var network = addr.v6.segments;
            const full_segments = prefix_len / 16;
            const remaining_bits = prefix_len % 16;

            // Zero out segments beyond the prefix
            for (full_segments..8) |i| {
                network[i] = 0;
            }

            // Apply partial mask to the segment at the boundary
            if (remaining_bits > 0 and full_segments < 8) {
                const mask = (~@as(u16, 0)) << @intCast(16 - remaining_bits);
                network[full_segments] &= mask;
            }

            return IPv6Subnet{
                .network = network,
                .prefix_len = prefix_len,
            };
        }

        pub fn toString(self: IPv6Subnet, allocator: std.mem.Allocator) ![]u8 {
            // Use IPv6 canonical format for network address
            const network_addr = IpAddr{ .v6 = .{ .segments = self.network } };
            const network_str = try network_addr.toString(allocator);
            defer allocator.free(network_str);

            return std.fmt.allocPrint(allocator, "{s}/{}", .{ network_str, self.prefix_len });
        }

        pub fn contains(self: IPv6Subnet, addr: IpAddr) bool {
            if (addr != .v6) return false;

            if (self.prefix_len == 0) return true; // ::/0 contains everything

            const full_segments = self.prefix_len / 16;
            const remaining_bits = self.prefix_len % 16;

            // Check full segments
            for (0..full_segments) |i| {
                if (self.network[i] != addr.v6.segments[i]) return false;
            }

            // Check partial segment if exists
            if (remaining_bits > 0 and full_segments < 8) {
                const mask = (~@as(u16, 0)) << @intCast(16 - remaining_bits);
                if ((self.network[full_segments] & mask) != (addr.v6.segments[full_segments] & mask)) {
                    return false;
                }
            }

            return true;
        }

        pub fn overlaps(self: IPv6Subnet, other: IPv6Subnet) bool {
            // Two subnets overlap if one contains the network address of the other
            const self_net_addr = IpAddr{ .v6 = .{ .segments = self.network } };
            const other_net_addr = IpAddr{ .v6 = .{ .segments = other.network } };

            return self.contains(other_net_addr) or other.contains(self_net_addr);
        }
    };

    pub fn fromString(cidr_str: []const u8) !Subnet {
        // Detect IPv4 vs IPv6 by presence of colons
        if (std.mem.indexOf(u8, cidr_str, ":") != null) {
            const v6 = try IPv6Subnet.fromString(cidr_str);
            return Subnet{ .v6 = v6 };
        } else {
            const v4 = try IPv4Subnet.fromString(cidr_str);
            return Subnet{ .v4 = v4 };
        }
    }

    pub fn toString(self: Subnet, allocator: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .v4 => |subnet| subnet.toString(allocator),
            .v6 => |subnet| subnet.toString(allocator),
        };
    }

    pub fn contains(self: Subnet, addr: IpAddr) bool {
        return switch (self) {
            .v4 => |subnet| subnet.contains(addr),
            .v6 => |subnet| subnet.contains(addr),
        };
    }

    pub fn overlaps(self: Subnet, other: Subnet) bool {
        return switch (self) {
            .v4 => |subnet| switch (other) {
                .v4 => |other_subnet| subnet.overlaps(other_subnet),
                .v6 => false, // IPv4 and IPv6 subnets don't overlap
            },
            .v6 => |subnet| switch (other) {
                .v6 => |other_subnet| subnet.overlaps(other_subnet),
                .v4 => false, // IPv6 and IPv4 subnets don't overlap
            },
        };
    }

    pub fn prefixLength(self: Subnet) u8 {
        return switch (self) {
            .v4 => |subnet| subnet.prefix_len,
            .v6 => |subnet| subnet.prefix_len,
        };
    }

    // Binary encoding for storage
    pub fn encode(self: Subnet, writer: anytype) !void {
        switch (self) {
            .v4 => |subnet| {
                try writer.writeByte(0x06); // IPv4 subnet tag
                try writer.writeAll(&subnet.network);
                try writer.writeByte(subnet.prefix_len);
            },
            .v6 => |subnet| {
                try writer.writeByte(0x07); // IPv6 subnet tag
                for (subnet.network) |segment| {
                    try writer.writeInt(u16, segment, .big);
                }
                try writer.writeByte(subnet.prefix_len);
            },
        }
    }

    pub fn decode(reader: anytype) !Subnet {
        const tag = try reader.readByte();
        return switch (tag) {
            0x06 => {
                var network: [4]u8 = undefined;
                try reader.readNoEof(&network);
                const prefix_len = try reader.readByte();
                return Subnet{ .v4 = IPv4Subnet{ .network = network, .prefix_len = prefix_len } };
            },
            0x07 => {
                var network: [8]u16 = undefined;
                for (&network) |*segment| {
                    segment.* = try reader.readInt(u16, .big);
                }
                const prefix_len = try reader.readByte();
                return Subnet{ .v6 = IPv6Subnet{ .network = network, .prefix_len = prefix_len } };
            },
            else => error.InvalidSubnetTag,
        };
    }
};

// Test suite
test "IPv4 subnet parsing and operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test subnet parsing
    const subnet = try Subnet.fromString("192.168.1.0/24");
    try testing.expect(subnet == .v4);
    try testing.expectEqual(@as(u8, 24), subnet.prefixLength());

    // Test string representation
    const subnet_str = try subnet.toString(allocator);
    defer allocator.free(subnet_str);
    try testing.expectEqualStrings("192.168.1.0/24", subnet_str);

    // Test containment
    const addr_in = try IpAddr.fromString("192.168.1.100");
    const addr_out = try IpAddr.fromString("192.168.2.100");

    try testing.expect(subnet.contains(addr_in));
    try testing.expect(!subnet.contains(addr_out));

    // Test host count
    try testing.expectEqual(@as(u32, 256), subnet.v4.hostCount());
}

test "IPv6 subnet parsing and operations" {
    const testing = std.testing;

    // Test IPv6 subnet parsing
    const subnet = try Subnet.fromString("2001:db8::/32");
    try testing.expect(subnet == .v6);
    try testing.expectEqual(@as(u8, 32), subnet.prefixLength());

    // Test containment
    const addr_in = try IpAddr.fromString("2001:db8::1");
    const addr_out = try IpAddr.fromString("2001:db9::1");

    try testing.expect(subnet.contains(addr_in));
    try testing.expect(!subnet.contains(addr_out));
}

test "Subnet overlap detection" {
    const testing = std.testing;

    const subnet1 = try Subnet.fromString("192.168.0.0/16");
    const subnet2 = try Subnet.fromString("192.168.1.0/24");
    const subnet3 = try Subnet.fromString("10.0.0.0/8");

    // subnet2 is contained in subnet1
    try testing.expect(subnet1.overlaps(subnet2));
    try testing.expect(subnet2.overlaps(subnet1));

    // subnet1 and subnet3 don't overlap
    try testing.expect(!subnet1.overlaps(subnet3));
    try testing.expect(!subnet3.overlaps(subnet1));
}

test "Subnet encoding/decoding" {
    const testing = std.testing;
    var buffer: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    // Test IPv4 subnet round-trip
    const ipv4_subnet = try Subnet.fromString("10.0.0.0/8");
    try ipv4_subnet.encode(fbs.writer());

    fbs.pos = 0;
    const decoded_ipv4 = try Subnet.decode(fbs.reader());
    try testing.expect(decoded_ipv4 == .v4);
    try testing.expectEqual(ipv4_subnet.v4.network, decoded_ipv4.v4.network);
    try testing.expectEqual(ipv4_subnet.v4.prefix_len, decoded_ipv4.v4.prefix_len);

    // Test IPv6 subnet round-trip
    fbs.pos = 0;
    const ipv6_subnet = try Subnet.fromString("2001:db8::/64");
    try ipv6_subnet.encode(fbs.writer());

    fbs.pos = 0;
    const decoded_ipv6 = try Subnet.decode(fbs.reader());
    try testing.expect(decoded_ipv6 == .v6);
    try testing.expectEqual(ipv6_subnet.v6.network, decoded_ipv6.v6.network);
    try testing.expectEqual(ipv6_subnet.v6.prefix_len, decoded_ipv6.v6.prefix_len);
}
