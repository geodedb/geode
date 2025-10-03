// Network type implementations: IpAddr, Subnet, Mac
// CANARY: REQ=REQ-GQL-TYPES; FEATURE="NetworkTypes"; ASPECT=Implementation; STATUS=TESTED; TEST=test_type_extensions.zig; BENCH=benchmark_patricia_trie.zig; OWNER=types-team; UPDATED=2025-10-03

// Re-export the comprehensive network types from the network/ directory
pub const IpAddr = @import("network/ipaddr.zig").IpAddr;
pub const Subnet = @import("network/subnet.zig").Subnet;
pub const Mac = @import("network/mac.zig").Mac;

// Re-export the module utilities
pub const parseIpAddr = @import("network/mod.zig").parseIpAddr;
pub const parseSubnet = @import("network/mod.zig").parseSubnet;
pub const parseMac = @import("network/mod.zig").parseMac;
pub const isValidIpAddr = @import("network/mod.zig").isValidIpAddr;
pub const isValidSubnet = @import("network/mod.zig").isValidSubnet;
pub const isValidMac = @import("network/mod.zig").isValidMac;

const std = @import("std");
const testing = std.testing;

// Built-in functions for GQL integration
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
    return mac.getOui();
}

pub fn mac_is_multicast(mac: Mac) bool {
    return mac.isMulticast();
}

pub fn mac_is_locally_administered(mac: Mac) bool {
    return mac.isLocallyAdministered();
}

// Compatibility test to ensure the network types work correctly
test "Network types integration compatibility" {
    const allocator = testing.allocator;

    // Test IP address
    const ip = try IpAddr.fromString("192.168.1.100");
    const ip_str = try ip.toString(allocator);
    defer allocator.free(ip_str);
    try testing.expectEqualStrings("192.168.1.100", ip_str);

    // Test subnet
    const subnet = try Subnet.fromString("192.168.1.0/24");
    const subnet_str = try subnet.toString(allocator);
    defer allocator.free(subnet_str);
    try testing.expectEqualStrings("192.168.1.0/24", subnet_str);

    // Test containment
    try testing.expect(ip_contains(subnet, ip));
    try testing.expect(ip_is_private(ip));

    // Test MAC address
    const mac = try Mac.fromString("AA:BB:CC:DD:EE:FF");
    const mac_str = try mac.toString(allocator);
    defer allocator.free(mac_str);
    try testing.expectEqualStrings("aa:bb:cc:dd:ee:ff", mac_str);

    // Test MAC functions
    const oui = mac_vendor_oui(mac);
    try testing.expectEqual([3]u8{ 0xAA, 0xBB, 0xCC }, oui);
}