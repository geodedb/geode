const std = @import("std");

// CANARY: REQ=REQ-GQL-NET-TYPES-VALIDATION; FEATURE="Network Types Validation Script"; ASPECT=Testing; STATUS=EXEMPT; TEST=TestCANARY_REQ_GQL_NET_TYPES_VALIDATION_Script; OWNER=testing; UPDATED=2025-01-03

// Validation script to test current Geode features and Network Types implementation
// This script validates that our Network Types are properly integrated and working

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Geode Network Types Validation ===\n", .{});

    // Test 1: Validate Network Types compilation
    std.debug.print("\n1. Testing Network Types compilation...\n", .{});
    try testNetworkTypesCompilation();
    std.debug.print("   ✅ Network Types compile successfully\n", .{});

    // Test 2: Validate basic network operations
    std.debug.print("\n2. Testing basic network operations...\n", .{});
    try testBasicNetworkOperations(allocator);
    std.debug.print("   ✅ Basic network operations work\n", .{});

    // Test 3: Validate error handling
    std.debug.print("\n3. Testing error handling...\n", .{});
    try testErrorHandling();
    std.debug.print("   ✅ Error handling works correctly\n", .{});

    // Test 4: Validate binary encoding/decoding
    std.debug.print("\n4. Testing binary encoding/decoding...\n", .{});
    try testBinaryEncoding();
    std.debug.print("   ✅ Binary encoding/decoding works\n", .{});

    // Test 5: Performance validation
    std.debug.print("\n5. Testing performance characteristics...\n", .{});
    try testPerformance(allocator);
    std.debug.print("   ✅ Performance characteristics acceptable\n", .{});

    std.debug.print("\n=== All Network Types validations passed! ===\n", .{});
    std.debug.print("✅ Network Types (IpAddr, Subnet, Mac) are ready for integration\n", .{});
    std.debug.print("✅ Ready to proceed with GQL parser integration\n", .{});
}

fn testNetworkTypesCompilation() !void {
    // This test verifies that all network types compile
    const IpAddr = @import("src/types/network/ipaddr.zig").IpAddr;
    const Subnet = @import("src/types/network/subnet.zig").Subnet;
    const Mac = @import("src/types/network/mac.zig").Mac;

    // Verify types are available
    _ = IpAddr;
    _ = Subnet; 
    _ = Mac;
}

fn testBasicNetworkOperations(allocator: std.mem.Allocator) !void {
    const IpAddr = @import("src/types/network/ipaddr.zig").IpAddr;
    const Subnet = @import("src/types/network/subnet.zig").Subnet;
    const Mac = @import("src/types/network/mac.zig").Mac;

    // Test IPv4 operations
    const ipv4 = try IpAddr.fromString("192.168.1.100");
    const ipv4_str = try ipv4.toString(allocator);
    defer allocator.free(ipv4_str);
    
    if (!std.mem.eql(u8, ipv4_str, "192.168.1.100")) {
        return error.IPv4StringMismatch;
    }

    // Test IPv6 operations
    const ipv6 = try IpAddr.fromString("2001:db8::1");
    const ipv6_str = try ipv6.toString(allocator);
    defer allocator.free(ipv6_str);
    
    if (!std.mem.eql(u8, ipv6_str, "2001:db8::1")) {
        return error.IPv6StringMismatch;
    }

    // Test subnet operations
    const subnet = try Subnet.fromString("192.168.1.0/24");
    const subnet_str = try subnet.toString(allocator);
    defer allocator.free(subnet_str);
    
    if (!std.mem.eql(u8, subnet_str, "192.168.1.0/24")) {
        return error.SubnetStringMismatch;
    }

    // Test containment
    if (!subnet.contains(ipv4)) {
        return error.SubnetContainmentFailed;
    }

    // Test MAC operations
    const mac = try Mac.fromString("AA:BB:CC:DD:EE:FF");
    const mac_str = try mac.toString(allocator);
    defer allocator.free(mac_str);
    
    if (!std.mem.eql(u8, mac_str, "aa:bb:cc:dd:ee:ff")) {
        return error.MacStringMismatch;
    }

    // Test MAC properties
    if (!mac.isUnicast() or mac.isMulticast()) {
        return error.MacPropertiesFailed;
    }
}

fn testErrorHandling() !void {
    const IpAddr = @import("src/types/network/ipaddr.zig").IpAddr;
    const Subnet = @import("src/types/network/subnet.zig").Subnet;
    const Mac = @import("src/types/network/mac.zig").Mac;

    // Test IPv4 error cases
    if (IpAddr.fromString("256.1.1.1")) |_| {
        return error.IPv4ErrorHandlingFailed;
    } else |err| {
        if (err != error.InvalidIPv4Format) {
            return error.IPv4WrongError;
        }
    }

    // Test IPv6 error cases
    if (IpAddr.fromString("gggg::1")) |_| {
        return error.IPv6ErrorHandlingFailed;
    } else |err| {
        if (err != error.InvalidIPv6Format) {
            return error.IPv6WrongError;
        }
    }

    // Test subnet error cases
    if (Subnet.fromString("192.168.1.0/33")) |_| {
        return error.SubnetErrorHandlingFailed;
    } else |err| {
        if (err != error.InvalidPrefixLength) {
            return error.SubnetWrongError;
        }
    }

    // Test MAC error cases
    if (Mac.fromString("GG:BB:CC:DD:EE:FF")) |_| {
        return error.MacErrorHandlingFailed;
    } else |err| {
        if (err != error.InvalidMacFormat) {
            return error.MacWrongError;
        }
    }
}

fn testBinaryEncoding() !void {
    const IpAddr = @import("src/types/network/ipaddr.zig").IpAddr;
    const Subnet = @import("src/types/network/subnet.zig").Subnet;
    const Mac = @import("src/types/network/mac.zig").Mac;

    var buffer: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    // Test IpAddr encoding/decoding
    const ipv4 = try IpAddr.fromString("10.0.0.1");
    try ipv4.encode(fbs.writer());
    fbs.pos = 0;
    const decoded_ipv4 = try IpAddr.decode(fbs.reader());
    
    if (decoded_ipv4 != .v4 or !std.mem.eql(u8, &ipv4.v4.octets, &decoded_ipv4.v4.octets)) {
        return error.IPv4EncodingFailed;
    }

    // Test Subnet encoding/decoding
    fbs.pos = 0;
    const subnet = try Subnet.fromString("192.168.0.0/16");
    try subnet.encode(fbs.writer());
    fbs.pos = 0;
    const decoded_subnet = try Subnet.decode(fbs.reader());
    
    if (decoded_subnet != .v4 or decoded_subnet.v4.network.octets[0] != 192) {
        return error.SubnetEncodingFailed;
    }

    // Test Mac encoding/decoding
    fbs.pos = 0;
    const mac = try Mac.fromString("12:34:56:78:9A:BC");
    try mac.encode(fbs.writer());
    fbs.pos = 0;
    const decoded_mac = try Mac.decode(fbs.reader());
    
    if (!mac.eql(decoded_mac)) {
        return error.MacEncodingFailed;
    }
}

fn testPerformance(allocator: std.mem.Allocator) !void {
    const IpAddr = @import("src/types/network/ipaddr.zig").IpAddr;
    const Mac = @import("src/types/network/mac.zig").Mac;

    const iterations = 1000;
    
    // Test parsing performance
    var timer = try std.time.Timer.start();
    
    for (0..iterations) |i| {
        const ip_str = try std.fmt.allocPrint(allocator, "192.168.1.{d}", .{i % 255 + 1});
        defer allocator.free(ip_str);
        
        const ip = try IpAddr.fromString(ip_str);
        const result_str = try ip.toString(allocator);
        allocator.free(result_str);
    }
    
    const ip_duration = timer.lap();
    
    // Test MAC performance
    for (0..iterations) |i| {
        const mac_str = try std.fmt.allocPrint(allocator, "00:11:22:33:44:{x:0>2}", .{i % 255});
        defer allocator.free(mac_str);
        
        const mac = try Mac.fromString(mac_str);
        const result_str = try mac.toString(allocator);
        allocator.free(result_str);
    }
    
    const mac_duration = timer.read();
    
    std.debug.print("   📊 Performance: {d} IP operations in {d}ns ({d}ns/op)\n", .{ iterations, ip_duration, ip_duration / iterations });
    std.debug.print("   📊 Performance: {d} MAC operations in {d}ns ({d}ns/op)\n", .{ iterations, mac_duration - ip_duration, (mac_duration - ip_duration) / iterations });
    
    // Ensure performance is reasonable (< 10μs per operation)
    if (ip_duration / iterations > 10_000 or (mac_duration - ip_duration) / iterations > 10_000) {
        return error.PerformanceTooSlow;
    }
}