// Network type implementations: IpAddr, Subnet, Mac
// CANARY: REQ=REQ-GQL-TYPES; FEATURE="NetworkTypes"; ASPECT=Implementation; STATUS=TESTED;
// TEST=test_type_extensions.zig; BENCH=benchmark_patricia_trie.zig; OWNER=types-team; UPDATED=2025-09-26

const std = @import("std");
const testing = std.testing;

/// IPv4/IPv6 address with RFC 5952 canonicalization
pub const IpAddr = union(enum) {
    v4: [4]u8,
    v6: [16]u8,

    pub fn parse(text: []const u8) !IpAddr {
        // Try IPv4 first
        if (std.net.Address.parseIp4(text, 0)) |addr| {
            return IpAddr{ .v4 = addr.sa.addr };
        } else |_| {}

        // Try IPv6
        if (std.net.Address.parseIp6(text, 0)) |addr| {
            return IpAddr{ .v6 = addr.sa.addr };
        } else |_| {}

        return error.InvalidIpAddress;
    }

    pub fn format(self: IpAddr, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .v4 => |octets| try writer.print("{}.{}.{}.{}", .{ octets[0], octets[1], octets[2], octets[3] }),
            .v6 => |bytes| {
                // RFC 5952 canonical representation
                var words: [8]u16 = undefined;
                for (0..8) |i| {
                    words[i] = (@as(u16, bytes[i * 2]) << 8) | bytes[i * 2 + 1];
                }

                // Find longest run of zeros for compression
                var max_start: usize = 0;
                var max_len: usize = 0;
                var curr_start: usize = 0;
                var curr_len: usize = 0;
                var in_zeros = false;

                for (words, 0..) |word, i| {
                    if (word == 0) {
                        if (!in_zeros) {
                            curr_start = i;
                            curr_len = 1;
                            in_zeros = true;
                        } else {
                            curr_len += 1;
                        }
                    } else {
                        if (in_zeros and curr_len > max_len) {
                            max_start = curr_start;
                            max_len = curr_len;
                        }
                        in_zeros = false;
                    }
                }
                if (in_zeros and curr_len > max_len) {
                    max_start = curr_start;
                    max_len = curr_len;
                }

                // Format with compression
                if (max_len > 1) {
                    for (0..max_start) |i| {
                        if (i > 0) try writer.writeByte(':');
                        try writer.print("{x}", .{words[i]});
                    }
                    try writer.writeAll("::");
                    for ((max_start + max_len)..8) |i| {
                        if (i > max_start + max_len) try writer.writeByte(':');
                        try writer.print("{x}", .{words[i]});
                    }
                } else {
                    for (words, 0..) |word, i| {
                        if (i > 0) try writer.writeByte(':');
                        try writer.print("{x}", .{word});
                    }
                }
            },
        }
    }

    pub fn isPrivate(self: IpAddr) bool {
        switch (self) {
            .v4 => |octets| {
                return (octets[0] == 10) or // 10.0.0.0/8
                    (octets[0] == 172 and octets[1] >= 16 and octets[1] <= 31) or // 172.16.0.0/12
                    (octets[0] == 192 and octets[1] == 168); // 192.168.0.0/16
            },
            .v6 => |bytes| {
                return (bytes[0] == 0xfc or bytes[0] == 0xfd); // fc00::/7
            },
        }
    }

    pub fn isLoopback(self: IpAddr) bool {
        switch (self) {
            .v4 => |octets| return octets[0] == 127,
            .v6 => |bytes| {
                for (bytes[0..15]) |b| {
                    if (b != 0) return false;
                }
                return bytes[15] == 1;
            },
        }
    }
};

/// CIDR subnet with prefix matching
pub const Subnet = struct {
    addr: IpAddr,
    prefix_len: u8,

    pub fn parse(text: []const u8) !Subnet {
        const slash_idx = std.mem.indexOf(u8, text, "/") orelse return error.InvalidSubnet;
        const addr_str = text[0..slash_idx];
        const prefix_str = text[slash_idx + 1 ..];

        const addr = try IpAddr.parse(addr_str);
        const prefix_len = try std.fmt.parseInt(u8, prefix_str, 10);

        // Validate prefix length
        switch (addr) {
            .v4 => if (prefix_len > 32) return error.InvalidPrefixLength,
            .v6 => if (prefix_len > 128) return error.InvalidPrefixLength,
        }

        return Subnet{ .addr = addr, .prefix_len = prefix_len };
    }

    pub fn contains(self: Subnet, addr: IpAddr) bool {
        // Check same address family
        if (@as(std.meta.Tag(IpAddr), self.addr) != @as(std.meta.Tag(IpAddr), addr)) {
            return false;
        }

        switch (self.addr) {
            .v4 => |subnet_octets| {
                const addr_octets = addr.v4;
                const full_bytes = self.prefix_len / 8;
                const remaining_bits = self.prefix_len % 8;

                // Check full bytes
                for (0..full_bytes) |i| {
                    if (subnet_octets[i] != addr_octets[i]) return false;
                }

                // Check remaining bits
                if (remaining_bits > 0 and full_bytes < 4) {
                    const mask = @as(u8, 0xFF) << @intCast(8 - remaining_bits);
                    if ((subnet_octets[full_bytes] & mask) != (addr_octets[full_bytes] & mask)) {
                        return false;
                    }
                }

                return true;
            },
            .v6 => |subnet_bytes| {
                const addr_bytes = addr.v6;
                const full_bytes = self.prefix_len / 8;
                const remaining_bits = self.prefix_len % 8;

                // Check full bytes
                for (0..full_bytes) |i| {
                    if (subnet_bytes[i] != addr_bytes[i]) return false;
                }

                // Check remaining bits
                if (remaining_bits > 0 and full_bytes < 16) {
                    const mask = @as(u8, 0xFF) << @intCast(8 - remaining_bits);
                    if ((subnet_bytes[full_bytes] & mask) != (addr_bytes[full_bytes] & mask)) {
                        return false;
                    }
                }

                return true;
            },
        }
    }

    pub fn format(self: Subnet, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try self.addr.format("", .{}, writer);
        try writer.print("/{}", .{self.prefix_len});
    }
};

/// EUI-48 MAC address
pub const Mac = struct {
    octets: [6]u8,

    pub fn parse(text: []const u8) !Mac {
        var octets: [6]u8 = undefined;
        var iter = std.mem.tokenize(u8, text, ":-");
        var i: usize = 0;

        while (iter.next()) |octet_str| : (i += 1) {
            if (i >= 6) return error.InvalidMacAddress;
            octets[i] = try std.fmt.parseInt(u8, octet_str, 16);
        }

        if (i != 6) return error.InvalidMacAddress;
        return Mac{ .octets = octets };
    }

    pub fn format(self: Mac, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        for (self.octets, 0..) |octet, i| {
            if (i > 0) try writer.writeByte(':');
            try writer.print("{x:0>2}", .{octet});
        }
    }

    pub fn vendorOui(self: Mac) [3]u8 {
        return self.octets[0..3].*;
    }

    pub fn isMulticast(self: Mac) bool {
        return (self.octets[0] & 0x01) != 0;
    }

    pub fn isLocallyAdministered(self: Mac) bool {
        return (self.octets[0] & 0x02) != 0;
    }
};

// Built-in functions
pub fn ip_contains(subnet: Subnet, addr: IpAddr) bool {
    return subnet.contains(addr);
}

pub fn ip_is_private(addr: IpAddr) bool {
    return addr.isPrivate();
}

pub fn ip_is_loopback(addr: IpAddr) bool {
    return addr.isLoopback();
}

pub fn mac_vendor_oui(mac: Mac) [3]u8 {
    return mac.vendorOui();
}

pub fn mac_is_multicast(mac: Mac) bool {
    return mac.isMulticast();
}

test "IpAddr parsing and formatting" {
    const ipv4 = try IpAddr.parse("192.168.1.1");
    try testing.expectEqual(@as(std.meta.Tag(IpAddr), .v4), @as(std.meta.Tag(IpAddr), ipv4));

    const ipv6 = try IpAddr.parse("2001:db8::1");
    try testing.expectEqual(@as(std.meta.Tag(IpAddr), .v6), @as(std.meta.Tag(IpAddr), ipv6));

    try testing.expect(ipv4.isPrivate());
    try testing.expect(!ipv6.isPrivate());
}

test "Subnet containment" {
    const subnet = try Subnet.parse("192.168.0.0/16");
    const addr1 = try IpAddr.parse("192.168.1.1");
    const addr2 = try IpAddr.parse("10.0.0.1");

    try testing.expect(subnet.contains(addr1));
    try testing.expect(!subnet.contains(addr2));
}

test "MAC address parsing" {
    const mac = try Mac.parse("aa:bb:cc:dd:ee:ff");
    try testing.expectEqual(@as(u8, 0xaa), mac.octets[0]);
    try testing.expectEqual(@as(u8, 0xff), mac.octets[5]);

    const oui = mac.vendorOui();
    try testing.expectEqual(@as(u8, 0xaa), oui[0]);
    try testing.expectEqual(@as(u8, 0xbb), oui[1]);
    try testing.expectEqual(@as(u8, 0xcc), oui[2]);
}
