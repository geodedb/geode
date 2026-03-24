// Network type implementations: IpAddr, Subnet, Mac
// CANARY: REQ=REQ-GQL-TYPES; FEATURE="NetworkTypes"; ASPECT=Implementation; STATUS=TESTED; TEST=test_type_extensions.zig; BENCH=benchmark_patricia_trie.zig; OWNER=types-team; UPDATED=2025-10-03

// =============================================================================
// Re-export core types from the external advanced_types library
// =============================================================================
const advanced_types = @import("advanced_types_lib");

pub const Ipv4Addr = advanced_types.Ipv4Addr;
pub const Ipv6Addr = advanced_types.Ipv6Addr;
pub const IpAddr = advanced_types.IpAddr;
pub const Subnet = advanced_types.Subnet;
pub const Mac = advanced_types.Mac;

const std = @import("std");
const testing = std.testing;

// =============================================================================
// Module-level utility functions (preserve existing public API)
// =============================================================================

pub fn parseIpAddr(addr_str: []const u8) !IpAddr {
    return IpAddr.parse(addr_str);
}

pub fn parseSubnet(cidr_str: []const u8) !Subnet {
    return Subnet.parse(cidr_str);
}

pub fn parseMac(mac_str: []const u8) !Mac {
    return Mac.parse(mac_str);
}

pub fn isValidIpAddr(addr_str: []const u8) bool {
    return if (parseIpAddr(addr_str)) |_| true else |_| false;
}

pub fn isValidSubnet(cidr_str: []const u8) bool {
    return if (parseSubnet(cidr_str)) |_| true else |_| false;
}

pub fn isValidMac(mac_str: []const u8) bool {
    return if (parseMac(mac_str)) |_| true else |_| false;
}

// =============================================================================
// GQL integration functions
// =============================================================================

// CANARY: REQ=REQ-GQL-NET-FUNC-001; FEATURE="NetworkFunctions"; ASPECT=BuiltinFunctions; STATUS=TESTED; TEST=geodetestlab/specs/network_types_basic.yml; OWNER=types; UPDATED=2025-10-19

pub fn ip_contains(subnet: Subnet, addr: IpAddr) bool {
    return subnet.contains(addr);
}

pub fn ip_is_private(addr: IpAddr) bool {
    return switch (addr) {
        .v4 => |v4| v4.isPrivate(),
        .v6 => false,
    };
}

pub fn ip_is_loopback(addr: IpAddr) bool {
    return switch (addr) {
        .v4 => |v4| v4.isLoopback(),
        .v6 => |v6| v6.isLoopback(),
    };
}

pub fn mac_vendor_oui(mac: Mac) [3]u8 {
    return mac.octets[0..3].*;
}

pub fn mac_is_multicast(mac: Mac) bool {
    return mac.isMulticast();
}

pub fn mac_is_locally_administered(mac: Mac) bool {
    return mac.isLocallyAdministered();
}

/// Alias for mac_is_locally_administered to match GQL naming convention
pub fn mac_is_local(mac: Mac) bool {
    return mac.isLocallyAdministered();
}

/// Extract network address from a subnet (returns the network base IP)
pub fn ip_network(subnet: Subnet) IpAddr {
    return subnet.network;
}

/// Get the prefix length from a subnet
pub fn subnet_prefix_length(subnet: Subnet) u8 {
    return subnet.prefix_len;
}

/// Create a subnet from an IP address and prefix length
pub fn ip_netmask(allocator: std.mem.Allocator, addr: IpAddr, prefix_len: u8) !Subnet {
    _ = allocator; // Not needed for this operation
    const max_prefix: u8 = switch (addr) {
        .v4 => 32,
        .v6 => 128,
    };
    if (prefix_len > max_prefix) return error.InvalidPrefixLength;

    // Apply mask to get network address
    const network_addr = switch (addr) {
        .v4 => |v4| blk: {
            if (prefix_len == 0) {
                break :blk IpAddr{ .v4 = Ipv4Addr.fromU32(0) };
            }
            const mask = ~@as(u32, 0) << @intCast(@as(u8, 32) - prefix_len);
            break :blk IpAddr{ .v4 = Ipv4Addr.fromU32(v4.toU32() & mask) };
        },
        .v6 => |v6| blk: {
            var octets = v6.octets;
            const full_bytes = prefix_len / 8;
            const remaining_bits: u3 = @intCast(prefix_len % 8);

            // Zero out bits beyond prefix
            if (remaining_bits > 0 and full_bytes < 16) {
                const shift: u3 = @intCast(@as(u4, 8) - @as(u4, remaining_bits));
                const byte_mask: u8 = @as(u8, 0xFF) << shift;
                octets[full_bytes] = octets[full_bytes] & byte_mask;
                var i: usize = full_bytes + 1;
                while (i < 16) : (i += 1) {
                    octets[i] = 0;
                }
            } else if (full_bytes < 16) {
                var i: usize = full_bytes;
                while (i < 16) : (i += 1) {
                    octets[i] = 0;
                }
            }
            break :blk IpAddr{ .v6 = .{ .octets = octets } };
        },
    };

    return Subnet{
        .network = network_addr,
        .prefix_len = prefix_len,
    };
}

/// Check if an IP address is multicast
pub fn ip_is_multicast(addr: IpAddr) bool {
    return switch (addr) {
        .v4 => |v4| v4.isMulticast(),
        .v6 => false, // simplified
    };
}

/// Check if an IP address is link-local
pub fn ip_is_link_local(addr: IpAddr) bool {
    return switch (addr) {
        .v4 => |v4| v4.octets[0] == 169 and v4.octets[1] == 254,
        .v6 => |v6| {
            // fe80::/10 — first two bytes form the segment, check top 10 bits
            const first_seg = @as(u16, v6.octets[0]) << 8 | @as(u16, v6.octets[1]);
            return (first_seg & 0xFFC0) == 0xFE80;
        },
    };
}

/// Check if two subnets overlap
pub fn subnet_overlaps(a: Subnet, b: Subnet) bool {
    return a.contains(b.network) or b.contains(a.network);
}

/// Get the broadcast address for a subnet (IPv4 only)
pub fn subnet_broadcast(subnet: Subnet) !IpAddr {
    return switch (subnet.network) {
        .v4 => |v4| blk: {
            if (subnet.prefix_len == 0) {
                break :blk IpAddr{ .v4 = Ipv4Addr.broadcast };
            }

            const mask = ~@as(u32, 0) << @intCast(@as(u8, 32) - subnet.prefix_len);
            const broadcast_int = v4.toU32() | ~mask;
            break :blk IpAddr{ .v4 = Ipv4Addr.fromU32(broadcast_int) };
        },
        .v6 => error.BroadcastNotSupportedForIPv6,
    };
}

/// Get the number of usable hosts in a subnet
pub fn subnet_host_count(subnet: Subnet) u128 {
    return switch (subnet.network) {
        .v4 => if (subnet.prefix_len >= 32) 1 else @as(u128, 1) << @intCast(@as(u8, 32) - subnet.prefix_len),
        .v6 => if (subnet.prefix_len >= 128) 1 else @as(u128, 1) << @intCast(@as(u8, 128) - subnet.prefix_len),
    };
}

// =============================================================================
// Compatibility test
// =============================================================================

test "Network types integration compatibility" {
    const allocator = testing.allocator;

    // Test IP address
    const ip = try IpAddr.parse("192.168.1.100");
    var ip_buf: [64]u8 = undefined;
    const ip_str = try std.fmt.bufPrint(&ip_buf, "{f}", .{ip});
    try testing.expectEqualStrings("192.168.1.100", ip_str);

    // Test subnet
    const subnet = try Subnet.parse("192.168.1.0/24");
    var subnet_buf: [64]u8 = undefined;
    const subnet_str = try std.fmt.bufPrint(&subnet_buf, "{f}", .{subnet});
    try testing.expectEqualStrings("192.168.1.0/24", subnet_str);

    // Test containment
    try testing.expect(ip_contains(subnet, ip));
    try testing.expect(ip_is_private(ip));

    // Test MAC address
    const mac = try Mac.parse("AA:BB:CC:DD:EE:FF");
    var mac_buf: [64]u8 = undefined;
    const mac_str = try std.fmt.bufPrint(&mac_buf, "{f}", .{mac});
    try testing.expectEqualStrings("AA:BB:CC:DD:EE:FF", mac_str);

    _ = allocator;

    // Test MAC functions
    const oui = mac_vendor_oui(mac);
    try testing.expectEqual([3]u8{ 0xAA, 0xBB, 0xCC }, oui);
}
