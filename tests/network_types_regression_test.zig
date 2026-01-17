const std = @import("std");
const testing = std.testing;

// Import network types
const types = @import("geode").types;
const IpAddr = types.network.IpAddr;
const Subnet = types.network.Subnet;
const Mac = types.network.Mac;

// CANARY: REQ=REQ-GQL-NET-TYPES-REGRESSION; FEATURE="Network Types Regression Tests"; ASPECT=Testing; STATUS=EXEMPT; TEST=TestCANARY_REQ_GQL_NET_TYPES_REGRESSION_All; OWNER=testing; UPDATED=2025-01-03

test "TestCANARY_REQ_GQL_NET_TYPES_001_IpAddr comprehensive functionality" {
    const allocator = testing.allocator;

    // IPv4 address tests
    const ipv4 = try IpAddr.fromString("192.168.1.100");
    try testing.expect(ipv4 == .v4);
    try testing.expectEqual(@as(u8, 4), ipv4.family());

    const ipv4_str = try ipv4.toString(allocator);
    defer allocator.free(ipv4_str);
    try testing.expectEqualStrings("192.168.1.100", ipv4_str);

    // IPv4 property tests
    try testing.expect(ipv4.isPrivate());
    try testing.expect(!ipv4.isLoopback());
    try testing.expect(!ipv4.isMulticast());

    // IPv4 special addresses
    const loopback = try IpAddr.fromString("127.0.0.1");
    try testing.expect(loopback.isLoopback());

    const multicast = try IpAddr.fromString("224.1.1.1");
    try testing.expect(multicast.isMulticast());

    const public_addr = try IpAddr.fromString("8.8.8.8");
    try testing.expect(!public_addr.isPrivate());

    // IPv6 address tests
    const ipv6 = try IpAddr.fromString("2001:db8::1");
    try testing.expect(ipv6 == .v6);
    try testing.expectEqual(@as(u8, 6), ipv6.family());

    const ipv6_loopback = try IpAddr.fromString("::1");
    try testing.expect(ipv6_loopback.isLoopback());

    const ipv6_multicast = try IpAddr.fromString("ff02::1");
    try testing.expect(ipv6_multicast.isMulticast());
}

test "TestCANARY_REQ_GQL_NET_TYPES_002_Subnet comprehensive functionality" {
    const allocator = testing.allocator;

    // IPv4 subnet tests
    const ipv4_subnet = try Subnet.fromString("192.168.1.0/24");
    try testing.expect(ipv4_subnet == .v4);
    try testing.expectEqual(@as(u8, 24), ipv4_subnet.prefixLength());

    const ipv4_subnet_str = try ipv4_subnet.toString(allocator);
    defer allocator.free(ipv4_subnet_str);
    try testing.expectEqualStrings("192.168.1.0/24", ipv4_subnet_str);

    // Containment tests
    const addr_in = try IpAddr.fromString("192.168.1.100");
    const addr_out = try IpAddr.fromString("192.168.2.100");
    try testing.expect(ipv4_subnet.contains(addr_in));
    try testing.expect(!ipv4_subnet.contains(addr_out));

    // Host count test
    try testing.expectEqual(@as(u32, 256), ipv4_subnet.v4.hostCount());

    // IPv6 subnet tests
    const ipv6_subnet = try Subnet.fromString("2001:db8::/32");
    try testing.expect(ipv6_subnet == .v6);
    try testing.expectEqual(@as(u8, 32), ipv6_subnet.prefixLength());

    const ipv6_addr_in = try IpAddr.fromString("2001:db8::1");
    const ipv6_addr_out = try IpAddr.fromString("2001:db9::1");
    try testing.expect(ipv6_subnet.contains(ipv6_addr_in));
    try testing.expect(!ipv6_subnet.contains(ipv6_addr_out));

    // Overlap tests
    const subnet1 = try Subnet.fromString("10.0.0.0/16");
    const subnet2 = try Subnet.fromString("10.0.1.0/24");
    const subnet3 = try Subnet.fromString("172.16.0.0/16");

    try testing.expect(subnet1.overlaps(subnet2));
    try testing.expect(subnet2.overlaps(subnet1));
    try testing.expect(!subnet1.overlaps(subnet3));
}

test "TestCANARY_REQ_GQL_NET_TYPES_003_Mac comprehensive functionality" {
    const allocator = testing.allocator;

    // MAC address parsing tests
    const mac_colon = try Mac.fromString("AA:BB:CC:DD:EE:FF");
    const mac_hyphen = try Mac.fromString("aa-bb-cc-dd-ee-ff");
    const mac_compact = try Mac.fromString("AABBCCDDEEFF");

    // All formats should produce same result
    try testing.expect(mac_colon.eql(mac_hyphen));
    try testing.expect(mac_colon.eql(mac_compact));

    // String representation tests
    const mac_str = try mac_colon.toString(allocator);
    defer allocator.free(mac_str);
    try testing.expectEqualStrings("aa:bb:cc:dd:ee:ff", mac_str);

    const mac_upper = try mac_colon.toStringUppercase(allocator);
    defer allocator.free(mac_upper);
    try testing.expectEqualStrings("AA:BB:CC:DD:EE:FF", mac_upper);

    const mac_compact_str = try mac_colon.toStringCompact(allocator);
    defer allocator.free(mac_compact_str);
    try testing.expectEqualStrings("aabbccddeeff", mac_compact_str);

    // OUI and NIC extraction
    const oui = mac_colon.getOui();
    const nic = mac_colon.getNicSpecific();
    try testing.expectEqual([3]u8{ 0xAA, 0xBB, 0xCC }, oui);
    try testing.expectEqual([3]u8{ 0xDD, 0xEE, 0xFF }, nic);

    // Property tests
    const unicast_mac = try Mac.fromString("00:11:22:33:44:55");
    const multicast_mac = try Mac.fromString("01:11:22:33:44:55");
    const local_mac = try Mac.fromString("02:11:22:33:44:55");
    const broadcast_mac = try Mac.fromString("FF:FF:FF:FF:FF:FF");
    const null_mac = try Mac.fromString("00:00:00:00:00:00");

    try testing.expect(unicast_mac.isUnicast());
    try testing.expect(multicast_mac.isMulticast());
    try testing.expect(local_mac.isLocallyAdministered());
    try testing.expect(unicast_mac.isGloballyUnique());
    try testing.expect(broadcast_mac.isBroadcast());
    try testing.expect(null_mac.isNull());
}

test "TestCANARY_REQ_GQL_NET_TYPES_004_Binary encoding round-trip" {
    var buffer: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    // Test IpAddr encoding/decoding
    const ipv4 = try IpAddr.fromString("10.0.0.1");
    try ipv4.encode(fbs.writer());
    fbs.pos = 0;
    const decoded_ipv4 = try IpAddr.decode(fbs.reader());
    try testing.expect(decoded_ipv4 == .v4);
    try testing.expectEqual(ipv4.v4.octets, decoded_ipv4.v4.octets);

    // Test IPv6 encoding
    fbs.pos = 0;
    const ipv6 = try IpAddr.fromString("2001:db8::1");
    try ipv6.encode(fbs.writer());
    fbs.pos = 0;
    const decoded_ipv6 = try IpAddr.decode(fbs.reader());
    try testing.expect(decoded_ipv6 == .v6);
    try testing.expectEqual(ipv6.v6.segments, decoded_ipv6.v6.segments);

    // Test Subnet encoding/decoding
    fbs.pos = 0;
    const subnet = try Subnet.fromString("192.168.0.0/16");
    try subnet.encode(fbs.writer());
    fbs.pos = 0;
    const decoded_subnet = try Subnet.decode(fbs.reader());
    try testing.expect(decoded_subnet == .v4);
    try testing.expectEqual(subnet.v4.network, decoded_subnet.v4.network);
    try testing.expectEqual(subnet.v4.prefix_len, decoded_subnet.v4.prefix_len);

    // Test Mac encoding/decoding
    fbs.pos = 0;
    const mac = try Mac.fromString("12:34:56:78:9A:BC");
    try mac.encode(fbs.writer());
    fbs.pos = 0;
    const decoded_mac = try Mac.decode(fbs.reader());
    try testing.expect(mac.eql(decoded_mac));
}

test "TestCANARY_REQ_GQL_NET_TYPES_005_Error handling comprehensive" {
    // IPv4 error cases
    try testing.expectError(error.InvalidIPv4Format, IpAddr.fromString("256.1.1.1"));
    try testing.expectError(error.InvalidIPv4Format, IpAddr.fromString("1.1.1"));
    try testing.expectError(error.InvalidIPv4Format, IpAddr.fromString("1.1.1.1.1"));
    try testing.expectError(error.InvalidIPv4Format, IpAddr.fromString("a.b.c.d"));

    // IPv6 error cases
    try testing.expectError(error.InvalidIPv6Format, IpAddr.fromString("gggg::1"));
    try testing.expectError(error.InvalidIPv6Format, IpAddr.fromString("1:2:3:4:5:6:7:8:9"));

    // Subnet error cases
    try testing.expectError(error.InvalidCIDRFormat, Subnet.fromString("192.168.1.0"));
    try testing.expectError(error.InvalidPrefixLength, Subnet.fromString("192.168.1.0/33"));
    try testing.expectError(error.InvalidPrefixLength, Subnet.fromString("2001:db8::/129"));

    // MAC error cases
    try testing.expectError(error.InvalidMacFormat, Mac.fromString("GG:BB:CC:DD:EE:FF"));
    try testing.expectError(error.InvalidMacFormat, Mac.fromString("AA:BB:CC:DD:EE"));
    try testing.expectError(error.InvalidMacFormat, Mac.fromString("AA:BB:CC:DD:EE:FF:00"));
    try testing.expectError(error.InvalidMacFormat, Mac.fromString("invalid"));
}

test "TestCANARY_REQ_GQL_NET_TYPES_006_Edge cases and boundary conditions" {
    const allocator = testing.allocator;

    // Test edge case subnets
    const full_ipv4 = try Subnet.fromString("0.0.0.0/0");
    const single_ipv4 = try Subnet.fromString("192.168.1.1/32");

    const any_addr = try IpAddr.fromString("8.8.8.8");
    const specific_addr = try IpAddr.fromString("192.168.1.1");

    try testing.expect(full_ipv4.contains(any_addr));
    try testing.expect(single_ipv4.contains(specific_addr));
    try testing.expect(!single_ipv4.contains(any_addr));

    // Test IPv6 zero compression edge cases
    const ipv6_all_zeros = try IpAddr.fromString("::");
    try testing.expect(ipv6_all_zeros == .v6);

    const ipv6_str = try ipv6_all_zeros.toString(allocator);
    defer allocator.free(ipv6_str);
    // Should compress to :: for all zeros

    // Test MAC address special cases
    const mac_all_f = try Mac.fromString("FF:FF:FF:FF:FF:FF");
    const mac_all_0 = try Mac.fromString("00:00:00:00:00:00");

    try testing.expect(mac_all_f.isBroadcast());
    try testing.expect(mac_all_0.isNull());

    // Test MAC random generation with different OUIs
    var prng = std.rand.DefaultPrng.init(12345);
    const rng = prng.random();

    const vmware_oui = [3]u8{ 0x00, 0x50, 0x56 };
    const random_mac = Mac.randomWithOui(vmware_oui, rng);
    try testing.expectEqual(vmware_oui, random_mac.getOui());
}

test "TestCANARY_REQ_GQL_NET_TYPES_007_Performance and memory efficiency" {
    const allocator = testing.allocator;

    // Performance test: parse many addresses quickly
    const test_ips = [_][]const u8{
        "192.168.1.1", "10.0.0.1", "172.16.0.1", "8.8.8.8",
        "2001:db8::1", "::1",      "fe80::1",    "ff02::1",
    };

    const test_subnets = [_][]const u8{
        "192.168.0.0/24", "10.0.0.0/8", "172.16.0.0/12",
        "2001:db8::/32",  "::/0",       "fe80::/64",
    };

    const test_macs = [_][]const u8{
        "00:11:22:33:44:55", "AA:BB:CC:DD:EE:FF",
        "aa-bb-cc-dd-ee-ff", "112233445566",
    };

    // Test that all parsing works quickly
    for (test_ips) |ip_str| {
        const ip = try IpAddr.fromString(ip_str);
        const str = try ip.toString(allocator);
        allocator.free(str);
    }

    for (test_subnets) |subnet_str| {
        const subnet = try Subnet.fromString(subnet_str);
        const str = try subnet.toString(allocator);
        allocator.free(str);
    }

    for (test_macs) |mac_str| {
        const mac = try Mac.fromString(mac_str);
        const str = try mac.toString(allocator);
        allocator.free(str);
    }

    // Memory efficiency: test that types are compact
    try testing.expectEqual(@sizeOf([4]u8) + @sizeOf(u8), @sizeOf(IpAddr.IPv4Addr));
    try testing.expectEqual(@sizeOf([8]u16) + @sizeOf(u8), @sizeOf(IpAddr.IPv6Addr));
    try testing.expectEqual(@sizeOf([6]u8), @sizeOf(Mac));
}

test "TestCANARY_REQ_GQL_NET_TYPES_008_Cross-type operations" {
    // Test interactions between different network types
    const ipv4_addr = try IpAddr.fromString("192.168.1.100");
    const ipv6_addr = try IpAddr.fromString("2001:db8::100");

    const ipv4_subnet = try Subnet.fromString("192.168.1.0/24");
    const ipv6_subnet = try Subnet.fromString("2001:db8::/64");

    // IPv4 address in IPv4 subnet
    try testing.expect(ipv4_subnet.contains(ipv4_addr));
    try testing.expect(!ipv4_subnet.contains(ipv6_addr));

    // IPv6 address in IPv6 subnet
    try testing.expect(ipv6_subnet.contains(ipv6_addr));
    try testing.expect(!ipv6_subnet.contains(ipv4_addr));

    // Subnets of different families don't overlap
    try testing.expect(!ipv4_subnet.overlaps(ipv6_subnet));
    try testing.expect(!ipv6_subnet.overlaps(ipv4_subnet));

    // Test comparison and ordering
    const mac1 = try Mac.fromString("00:11:22:33:44:55");
    const mac2 = try Mac.fromString("00:11:22:33:44:56");
    const mac3 = try Mac.fromString("00:11:22:33:44:55");

    try testing.expectEqual(std.math.Order.lt, mac1.order(mac2));
    try testing.expectEqual(std.math.Order.gt, mac2.order(mac1));
    try testing.expectEqual(std.math.Order.eq, mac1.order(mac3));
}

test "TestCANARY_REQ_GQL_NET_TYPES_009_Utility functions regression" {
    // Test that all network utility functions work correctly
    try testing.expect(types.network.isValidIpAddr("192.168.1.1"));
    try testing.expect(types.network.isValidIpAddr("2001:db8::1"));
    try testing.expect(!types.network.isValidIpAddr("invalid"));
    try testing.expect(!types.network.isValidIpAddr("256.1.1.1"));

    try testing.expect(types.network.isValidSubnet("192.168.0.0/24"));
    try testing.expect(types.network.isValidSubnet("2001:db8::/64"));
    try testing.expect(!types.network.isValidSubnet("invalid"));
    try testing.expect(!types.network.isValidSubnet("192.168.1.1/33"));

    try testing.expect(types.network.isValidMac("AA:BB:CC:DD:EE:FF"));
    try testing.expect(types.network.isValidMac("aa-bb-cc-dd-ee-ff"));
    try testing.expect(types.network.isValidMac("AABBCCDDEEFF"));
    try testing.expect(!types.network.isValidMac("invalid"));
    try testing.expect(!types.network.isValidMac("GG:BB:CC:DD:EE:FF"));

    // Test parse functions work correctly
    const ip = try types.network.parseIpAddr("10.0.0.1");
    try testing.expect(ip.family() == 4);

    const subnet = try types.network.parseSubnet("10.0.0.0/8");
    try testing.expect(subnet.prefixLength() == 8);

    const mac = try types.network.parseMac("00:11:22:33:44:55");
    try testing.expect(mac.isGloballyUnique());
}

test "TestCANARY_REQ_GQL_NET_TYPES_010_GQL integration functions" {
    // Test built-in functions for GQL integration
    const ip = try IpAddr.fromString("192.168.1.100");
    const subnet = try Subnet.fromString("192.168.1.0/24");
    const mac = try Mac.fromString("AA:BB:CC:DD:EE:FF");

    // Test subnet containment function
    try testing.expect(types.network.ip_contains(subnet, ip));
    try testing.expect(!types.network.ip_contains(subnet, try IpAddr.fromString("10.0.0.1")));

    // Test IP property functions
    try testing.expect(types.network.ip_is_private(ip));
    try testing.expect(!types.network.ip_is_loopback(ip));
    try testing.expect(types.network.ip_is_loopback(try IpAddr.fromString("127.0.0.1")));

    // Test MAC property functions
    const oui = types.network.mac_vendor_oui(mac);
    try testing.expectEqual([3]u8{ 0xAA, 0xBB, 0xCC }, oui);
    try testing.expect(!types.network.mac_is_multicast(mac));
    try testing.expect(types.network.mac_is_locally_administered(mac));
}

test "TestCANARY_REQ_GQL_NET_TYPES_011_IPv6_canonicalization_regression" {
    const allocator = testing.allocator;

    // Test RFC 5952 canonicalization consistency
    const test_cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "2001:db8:0:0:0:0:0:1", .expected = "2001:db8::1" },
        .{ .input = "2001:0db8:0000:0000:0000:0000:0000:0001", .expected = "2001:db8::1" },
        .{ .input = "::1", .expected = "::1" },
        .{ .input = "::", .expected = "::" },
        .{ .input = "fe80::1", .expected = "fe80::1" },
        .{ .input = "2001:db8:85a3::8a2e:370:7334", .expected = "2001:db8:85a3::8a2e:370:7334" },
    };

    for (test_cases) |case| {
        const ip = try IpAddr.fromString(case.input);
        try testing.expect(ip.family() == 6);
        const str = try ip.toString(allocator);
        defer allocator.free(str);
        try testing.expectEqualStrings(case.expected, str);
    }
}

test "TestCANARY_REQ_GQL_NET_TYPES_012_Subnet_boundary_regression" {
    // Test subnet boundary conditions
    const subnet_24 = try Subnet.fromString("192.168.1.0/24");
    const subnet_25 = try Subnet.fromString("192.168.1.0/25");
    const subnet_23 = try Subnet.fromString("192.168.0.0/23");

    const ip_first = try IpAddr.fromString("192.168.1.0");
    const ip_last_24 = try IpAddr.fromString("192.168.1.255");
    const ip_middle = try IpAddr.fromString("192.168.1.100");
    const ip_outside = try IpAddr.fromString("192.168.2.1");

    // Test /24 subnet boundaries
    try testing.expect(subnet_24.contains(ip_first));
    try testing.expect(subnet_24.contains(ip_last_24));
    try testing.expect(subnet_24.contains(ip_middle));
    try testing.expect(!subnet_24.contains(ip_outside));

    // Test subnet hierarchy
    try testing.expect(subnet_23.contains(ip_first));
    try testing.expect(subnet_25.contains(ip_first));
    try testing.expect(!subnet_25.contains(ip_last_24)); // 192.168.1.255 not in /25

    // Test prefix length boundaries for IPv4
    for (0..33) |prefix| {
        const subnet_str = try std.fmt.allocPrint(testing.allocator, "192.168.1.0/{d}", .{prefix});
        defer testing.allocator.free(subnet_str);
        const subnet = try Subnet.fromString(subnet_str);
        try testing.expect(subnet.prefixLength() == prefix);
    }

    // Test prefix length boundaries for IPv6
    for (0..129) |prefix| {
        const subnet_str = try std.fmt.allocPrint(testing.allocator, "2001:db8::/{d}", .{prefix});
        defer testing.allocator.free(subnet_str);
        const subnet = try Subnet.fromString(subnet_str);
        try testing.expect(subnet.prefixLength() == prefix);
    }
}
