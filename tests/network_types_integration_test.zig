const std = @import("std");
const testing = std.testing;

// Network types integration tests
// CANARY: REQ=REQ-GQL-NET-TYPES-100; FEATURE="NetworkTypesIntegration"; ASPECT=EndToEndTesting; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_NET_TYPES_100_Integration; OWNER=types; UPDATED=2025-10-03

const types = @import("geode").types;
const IpAddr = types.network.IpAddr;
const Subnet = types.network.Subnet;
const Mac = types.network.Mac;

test "TestCANARY_REQ_GQL_NET_TYPES_100_Integration" {
    const allocator = testing.allocator;

    // Test comprehensive IPv4 functionality
    const ipv4 = try IpAddr.fromString("192.168.1.100");
    const ipv4_str = try ipv4.toString(allocator);
    defer allocator.free(ipv4_str);
    try testing.expectEqualStrings("192.168.1.100", ipv4_str);
    try testing.expect(ipv4.isPrivate());
    try testing.expect(!ipv4.isLoopback());
    try testing.expect(ipv4.family() == 4);

    // Test comprehensive IPv6 functionality
    const ipv6 = try IpAddr.fromString("2001:db8::1");
    const ipv6_str = try ipv6.toString(allocator);
    defer allocator.free(ipv6_str);
    try testing.expectEqualStrings("2001:db8::1", ipv6_str);
    try testing.expect(!ipv6.isPrivate());
    try testing.expect(!ipv6.isLoopback());
    try testing.expect(ipv6.family() == 6);

    // Test IPv6 loopback
    const ipv6_loopback = try IpAddr.fromString("::1");
    try testing.expect(ipv6_loopback.isLoopback());

    // Test subnet operations
    const subnet = try Subnet.fromString("192.168.0.0/16");
    const subnet_str = try subnet.toString(allocator);
    defer allocator.free(subnet_str);
    try testing.expectEqualStrings("192.168.0.0/16", subnet_str);
    try testing.expect(subnet.contains(ipv4));

    const subnet_narrow = try Subnet.fromString("192.168.1.0/24");
    try testing.expect(subnet.contains(ipv4));
    try testing.expect(subnet_narrow.contains(ipv4));
    try testing.expect(!subnet_narrow.contains(try IpAddr.fromString("192.168.2.1")));

    // Test subnet overlap detection
    try testing.expect(subnet.overlaps(subnet_narrow));
    try testing.expect(subnet_narrow.overlaps(subnet));

    const subnet_disjoint = try Subnet.fromString("10.0.0.0/8");
    try testing.expect(!subnet.overlaps(subnet_disjoint));

    // Test MAC address functionality
    const mac = try Mac.fromString("AA:BB:CC:DD:EE:FF");
    const mac_str = try mac.toString(allocator);
    defer allocator.free(mac_str);
    try testing.expectEqualStrings("aa:bb:cc:dd:ee:ff", mac_str);

    const mac_upper = try mac.toStringUppercase(allocator);
    defer allocator.free(mac_upper);
    try testing.expectEqualStrings("AA:BB:CC:DD:EE:FF", mac_upper);

    const mac_compact = try mac.toStringCompact(allocator);
    defer allocator.free(mac_compact);
    try testing.expectEqualStrings("aabbccddeeff", mac_compact);

    // Test MAC properties
    try testing.expect(mac.isUnicast());
    try testing.expect(!mac.isMulticast());
    try testing.expect(mac.isLocallyAdministered()); // AA has bit 1 set

    const oui = mac.getOui();
    try testing.expectEqual([3]u8{ 0xAA, 0xBB, 0xCC }, oui);

    const nic = mac.getNicSpecific();
    try testing.expectEqual([3]u8{ 0xDD, 0xEE, 0xFF }, nic);

    // Test special MAC addresses
    const broadcast_mac = try Mac.fromString("FF:FF:FF:FF:FF:FF");
    try testing.expect(broadcast_mac.isBroadcast());
    try testing.expect(broadcast_mac.isMulticast());

    const null_mac = try Mac.fromString("00:00:00:00:00:00");
    try testing.expect(null_mac.isNull());
    try testing.expect(null_mac.isUnicast());
}

test "Network types error handling and edge cases" {
    // Test invalid IP addresses
    try testing.expectError(error.InvalidIPv4Format, IpAddr.fromString("256.1.1.1"));
    try testing.expectError(error.InvalidIPv4Format, IpAddr.fromString("192.168.1"));
    try testing.expectError(error.InvalidIPv6Format, IpAddr.fromString("gggg::1"));

    // Test invalid subnets
    try testing.expectError(error.InvalidCIDRFormat, Subnet.fromString("192.168.1.1"));
    try testing.expectError(error.InvalidPrefixLength, Subnet.fromString("192.168.1.0/33"));
    try testing.expectError(error.InvalidPrefixLength, Subnet.fromString("2001:db8::/129"));

    // Test invalid MAC addresses
    try testing.expectError(error.InvalidMacFormat, Mac.fromString("invalid"));
    try testing.expectError(error.InvalidMacFormat, Mac.fromString("AA:BB:CC:DD:EE"));
    try testing.expectError(error.InvalidMacFormat, Mac.fromString("GG:BB:CC:DD:EE:FF"));
}

test "Network types binary encoding round-trip" {
    const allocator = testing.allocator;
    var buffer: [64]u8 = undefined;
    var fbs = std.Io.fixedBufferStream(&buffer);

    // Test IP address encoding
    const ip = try IpAddr.fromString("192.168.1.100");
    try ip.encode(fbs.writer());
    fbs.pos = 0;
    const decoded_ip = try IpAddr.decode(fbs.reader());
    const ip_str = try ip.toString(allocator);
    defer allocator.free(ip_str);
    const decoded_ip_str = try decoded_ip.toString(allocator);
    defer allocator.free(decoded_ip_str);
    try testing.expectEqualStrings(ip_str, decoded_ip_str);

    // Test subnet encoding
    fbs.pos = 0;
    const subnet = try Subnet.fromString("10.0.0.0/8");
    try subnet.encode(fbs.writer());
    fbs.pos = 0;
    const decoded_subnet = try Subnet.decode(fbs.reader());
    const subnet_str = try subnet.toString(allocator);
    defer allocator.free(subnet_str);
    const decoded_subnet_str = try decoded_subnet.toString(allocator);
    defer allocator.free(decoded_subnet_str);
    try testing.expectEqualStrings(subnet_str, decoded_subnet_str);

    // Test MAC encoding
    fbs.pos = 0;
    const mac = try Mac.fromString("12:34:56:78:9A:BC");
    try mac.encode(fbs.writer());
    fbs.pos = 0;
    const decoded_mac = try Mac.decode(fbs.reader());
    try testing.expect(mac.eql(decoded_mac));
}

test "Network types performance characteristics" {
    const allocator = testing.allocator;

    // Test IPv4 parsing performance (should be very fast)
    var timer = try std.time.Timer.start();
    const start_time = timer.lap();

    for (0..1000) |i| {
        _ = i;
        const ip = try IpAddr.fromString("192.168.1.100");
        _ = ip;
    }

    const elapsed = timer.lap() - start_time;
    const per_parse_ns = elapsed / 1000;

    // Should be less than 1μs per parse (1000ns)
    try testing.expect(per_parse_ns < 1000);

    // Test subnet containment performance
    const subnet = try Subnet.fromString("192.168.0.0/16");
    const ip = try IpAddr.fromString("192.168.1.100");

    timer = try std.time.Timer.start();
    const start_containment = timer.lap();

    for (0..10000) |i| {
        _ = i;
        const contained = subnet.contains(ip);
        _ = contained;
    }

    const containment_elapsed = timer.lap() - start_containment;
    const per_containment_ns = containment_elapsed / 10000;

    // Should be very fast O(1) operations (less than 100ns)
    try testing.expect(per_containment_ns < 100);

    // Test string formatting performance
    timer = try std.time.Timer.start();
    const start_format = timer.lap();

    for (0..1000) |i| {
        _ = i;
        const ip_str = try ip.toString(allocator);
        allocator.free(ip_str);
    }

    const format_elapsed = timer.lap() - start_format;
    const per_format_ns = format_elapsed / 1000;

    // Formatting should be reasonable (less than 2μs)
    try testing.expect(per_format_ns < 2000);
}

test "Network types utility functions" {
    // Test validation functions
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

    // Test parse functions
    const ip = try types.network.parseIpAddr("10.0.0.1");
    try testing.expect(ip.family() == 4);

    const subnet = try types.network.parseSubnet("10.0.0.0/8");
    try testing.expect(subnet.prefixLength() == 8);

    const mac = try types.network.parseMac("00:11:22:33:44:55");
    try testing.expect(mac.isGloballyUnique());
}

test "Complex network operations and edge cases" {
    const allocator = testing.allocator;

    // Test IPv6 zero compression edge cases
    const ipv6_full = try IpAddr.fromString("2001:0db8:85a3:0000:0000:8a2e:0370:7334");
    const ipv6_compressed = try IpAddr.fromString("2001:db8:85a3::8a2e:370:7334");

    const full_str = try ipv6_full.toString(allocator);
    defer allocator.free(full_str);
    const compressed_str = try ipv6_compressed.toString(allocator);
    defer allocator.free(compressed_str);

    // Both should result in the same canonical form
    try testing.expectEqualStrings(compressed_str, "2001:db8:85a3::8a2e:370:7334");

    // Test subnet edge cases
    const subnet_32 = try Subnet.fromString("192.168.1.100/32"); // Single host
    const subnet_0 = try Subnet.fromString("0.0.0.0/0"); // Everything

    try testing.expect(subnet_32.v4.hostCount() == 1);
    try testing.expect(subnet_0.contains(try IpAddr.fromString("8.8.8.8")));
    try testing.expect(subnet_0.contains(try IpAddr.fromString("192.168.1.1")));

    // Test MAC address format flexibility
    const mac_colon = try Mac.fromString("AA:BB:CC:DD:EE:FF");
    const mac_hyphen = try Mac.fromString("AA-BB-CC-DD-EE-FF");
    const mac_compact = try Mac.fromString("AABBCCDDEEFF");

    try testing.expect(mac_colon.eql(mac_hyphen));
    try testing.expect(mac_hyphen.eql(mac_compact));

    // Test MAC address ordering
    const mac1 = try Mac.fromString("AA:BB:CC:DD:EE:FE");
    const mac2 = try Mac.fromString("AA:BB:CC:DD:EE:FF");
    try testing.expectEqual(std.math.Order.lt, mac1.order(mac2));
    try testing.expectEqual(std.math.Order.gt, mac2.order(mac1));
}
