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

// CANARY: REQ=REQ-GQL-NET-FUNC-001; FEATURE="NetworkFunctions"; ASPECT=BuiltinFunctions; STATUS=TESTED; TEST=geodetestlab/specs/network_types_basic.yml; OWNER=types; UPDATED=2025-10-19
// Additional network utility functions for GQL integration

/// Alias for mac_is_locally_administered to match GQL naming convention
pub fn mac_is_local(mac: Mac) bool {
    return mac.isLocallyAdministered();
}

/// Extract network address from a subnet (returns the network base IP)
pub fn ip_network(subnet: Subnet) IpAddr {
    return switch (subnet) {
        .v4 => |v4| IpAddr{ .v4 = .{ .octets = v4.network } },
        .v6 => |v6| IpAddr{ .v6 = .{ .segments = v6.network } },
    };
}

/// Get the prefix length from a subnet
pub fn subnet_prefix_length(subnet: Subnet) u8 {
    return switch (subnet) {
        .v4 => |v4| v4.prefix_len,
        .v6 => |v6| v6.prefix_len,
    };
}

/// Create a subnet from an IP address and prefix length
pub fn ip_netmask(allocator: std.mem.Allocator, addr: IpAddr, prefix_len: u8) !Subnet {
    _ = allocator; // Not needed for this operation
    return switch (addr) {
        .v4 => |v4| blk: {
            if (prefix_len > 32) return error.InvalidPrefixLength;

            // Create network mask
            const mask = if (prefix_len == 0) 0 else ~@as(u32, 0) << @intCast(32 - prefix_len);

            // Convert IP to u32
            const addr_int = (@as(u32, v4.octets[0]) << 24) |
                (@as(u32, v4.octets[1]) << 16) |
                (@as(u32, v4.octets[2]) << 8) |
                @as(u32, v4.octets[3]);

            // Apply mask to get network address
            const network_int = addr_int & mask;
            const network = [4]u8{
                @intCast((network_int >> 24) & 0xFF),
                @intCast((network_int >> 16) & 0xFF),
                @intCast((network_int >> 8) & 0xFF),
                @intCast(network_int & 0xFF),
            };

            break :blk Subnet{ .v4 = .{
                .network = network,
                .prefix_len = prefix_len,
            } };
        },
        .v6 => |v6| blk: {
            if (prefix_len > 128) return error.InvalidPrefixLength;

            // Apply mask to each segment
            var network = v6.segments;
            const full_segments = prefix_len / 16;
            const remaining_bits = prefix_len % 16;

            // Zero out segments beyond prefix
            var i: usize = full_segments;
            while (i < 8) : (i += 1) {
                if (i == full_segments and remaining_bits > 0) {
                    const mask = ~@as(u16, 0) << @intCast(16 - remaining_bits);
                    network[i] = v6.segments[i] & mask;
                } else if (i > full_segments) {
                    network[i] = 0;
                }
            }

            break :blk Subnet{ .v6 = .{
                .network = network,
                .prefix_len = prefix_len,
            } };
        },
    };
}

/// Check if an IP address is multicast
pub fn ip_is_multicast(addr: IpAddr) bool {
    return addr.isMulticast();
}

/// Check if an IP address is link-local
pub fn ip_is_link_local(addr: IpAddr) bool {
    return switch (addr) {
        .v4 => |v4| v4.octets[0] == 169 and v4.octets[1] == 254,
        .v6 => |v6| (v6.segments[0] & 0xFFC0) == 0xFE80,
    };
}

/// Check if two subnets overlap
pub fn subnet_overlaps(a: Subnet, b: Subnet) bool {
    return switch (a) {
        .v4 => |v4a| switch (b) {
            .v4 => |v4b| v4a.overlaps(v4b),
            .v6 => false,
        },
        .v6 => |v6a| switch (b) {
            .v4 => false,
            .v6 => |v6b| v6a.overlaps(v6b),
        },
    };
}

/// Get the broadcast address for a subnet (IPv4 only)
pub fn subnet_broadcast(subnet: Subnet) !IpAddr {
    return switch (subnet) {
        .v4 => |v4| blk: {
            if (v4.prefix_len == 0) {
                break :blk IpAddr{ .v4 = .{ .octets = [4]u8{ 255, 255, 255, 255 } } };
            }

            const mask = ~@as(u32, 0) << @intCast(32 - v4.prefix_len);
            const network_int = (@as(u32, v4.network[0]) << 24) |
                (@as(u32, v4.network[1]) << 16) |
                (@as(u32, v4.network[2]) << 8) |
                @as(u32, v4.network[3]);

            const broadcast_int = network_int | ~mask;
            break :blk IpAddr{ .v4 = .{ .octets = [4]u8{
                @intCast((broadcast_int >> 24) & 0xFF),
                @intCast((broadcast_int >> 16) & 0xFF),
                @intCast((broadcast_int >> 8) & 0xFF),
                @intCast(broadcast_int & 0xFF),
            } } };
        },
        .v6 => error.BroadcastNotSupportedForIPv6,
    };
}

/// Get the number of usable hosts in a subnet
pub fn subnet_host_count(subnet: Subnet) u128 {
    return switch (subnet) {
        .v4 => |v4| if (v4.prefix_len >= 32) 1 else @as(u128, v4.hostCount()),
        .v6 => |v6| if (v6.prefix_len >= 128) 1 else @as(u128, 1) << @intCast(128 - v6.prefix_len),
    };
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
