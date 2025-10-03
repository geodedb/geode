// Network types module - exports all network-related types
// CANARY: REQ=REQ-GQL-NET-TYPES-000; FEATURE="Network Types Module"; ASPECT=Types; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_NET_TYPES_000_Module; OWNER=types; UPDATED=2025-01-03

pub const IpAddr = @import("ipaddr.zig").IpAddr;
pub const Subnet = @import("subnet.zig").Subnet;
pub const Mac = @import("mac.zig").Mac;

// Re-export IPv4/IPv6 specific types for direct access
pub const IPv4Addr = IpAddr.IPv4Addr;
pub const IPv6Addr = IpAddr.IPv6Addr;
pub const IPv4Subnet = Subnet.IPv4Subnet;
pub const IPv6Subnet = Subnet.IPv6Subnet;

// Utility functions for network type operations
pub fn parseIpAddr(addr_str: []const u8) !IpAddr {
    return IpAddr.fromString(addr_str);
}

pub fn parseSubnet(cidr_str: []const u8) !Subnet {
    return Subnet.fromString(cidr_str);
}

pub fn parseMac(mac_str: []const u8) !Mac {
    return Mac.fromString(mac_str);
}

// Network type detection utilities
pub fn isValidIpAddr(addr_str: []const u8) bool {
    return if (parseIpAddr(addr_str)) |_| true else |_| false;
}

pub fn isValidSubnet(cidr_str: []const u8) bool {
    return if (parseSubnet(cidr_str)) |_| true else |_| false;
}

pub fn isValidMac(mac_str: []const u8) bool {
    return if (parseMac(mac_str)) |_| true else |_| false;
}

test "network types module integration" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    // Test all network types work together
    const ip = try parseIpAddr("192.168.1.100");
    const subnet = try parseSubnet("192.168.1.0/24");
    const mac = try parseMac("AA:BB:CC:DD:EE:FF");

    // Test subnet containment
    try testing.expect(subnet.contains(ip));

    // Test string representations
    const ip_str = try ip.toString(allocator);
    defer allocator.free(ip_str);
    try testing.expectEqualStrings("192.168.1.100", ip_str);

    const subnet_str = try subnet.toString(allocator);
    defer allocator.free(subnet_str);
    try testing.expectEqualStrings("192.168.1.0/24", subnet_str);

    const mac_str = try mac.toString(allocator);
    defer allocator.free(mac_str);
    try testing.expectEqualStrings("aa:bb:cc:dd:ee:ff", mac_str);

    // Test validation functions
    try testing.expect(isValidIpAddr("192.168.1.1"));
    try testing.expect(!isValidIpAddr("invalid"));

    try testing.expect(isValidSubnet("10.0.0.0/8"));
    try testing.expect(!isValidSubnet("invalid"));

    try testing.expect(isValidMac("00:11:22:33:44:55"));
    try testing.expect(!isValidMac("invalid"));
}
