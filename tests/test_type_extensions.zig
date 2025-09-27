const std = @import("std");
const heap = @import("../src/storage/heap.zig");
const patricia = @import("../src/index/patricia.zig");
const rtree = @import("../src/index/rtree.zig");
const hnsw = @import("../src/index/hnsw.zig");
const eval_extended = @import("../src/eval_extended.zig");

test "IPv4 encode/decode roundtrip" {
    const allocator = std.testing.allocator;
    
    const ip = heap.Value{ .IpAddr = .{ .v4 = .{ 192, 168, 1, 1 } } };
    const encoded = try heap.encodeValue(allocator, ip);
    defer allocator.free(encoded);
    
    const decoded = try heap.decodeValue(allocator, encoded);
    
    try std.testing.expect(decoded == .IpAddr);
    try std.testing.expect(decoded.IpAddr == .v4);
    try std.testing.expectEqualSlices(u8, &ip.IpAddr.v4, &decoded.IpAddr.v4);
}

test "IPv6 encode/decode roundtrip" {
    const allocator = std.testing.allocator;
    
    const ip = heap.Value{ .IpAddr = .{ .v6 = .{ 
        0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 
        0, 0, 0, 0, 0, 0, 0, 1 
    } } };
    const encoded = try heap.encodeValue(allocator, ip);
    defer allocator.free(encoded);
    
    const decoded = try heap.decodeValue(allocator, encoded);
    
    try std.testing.expect(decoded == .IpAddr);
    try std.testing.expect(decoded.IpAddr == .v6);
    try std.testing.expectEqualSlices(u8, &ip.IpAddr.v6, &decoded.IpAddr.v6);
}

test "Subnet encode/decode roundtrip" {
    const allocator = std.testing.allocator;
    
    const subnet = heap.Value{ .Subnet = .{ 
        .addr = .{ .v4 = .{ 10, 0, 0, 0 } }, 
        .prefix_len = 8 
    } };
    const encoded = try heap.encodeValue(allocator, subnet);
    defer allocator.free(encoded);
    
    const decoded = try heap.decodeValue(allocator, encoded);
    
    try std.testing.expect(decoded == .Subnet);
    try std.testing.expect(decoded.Subnet.addr == .v4);
    try std.testing.expectEqual(@as(u8, 8), decoded.Subnet.prefix_len);
}

test "MAC address encode/decode" {
    const allocator = std.testing.allocator;
    
    const mac = heap.Value{ .Mac = .{ .bytes = .{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF } } };
    const encoded = try heap.encodeValue(allocator, mac);
    defer allocator.free(encoded);
    
    const decoded = try heap.decodeValue(allocator, encoded);
    
    try std.testing.expect(decoded == .Mac);
    try std.testing.expectEqualSlices(u8, &mac.Mac.bytes, &decoded.Mac.bytes);
}

test "Currency encode/decode" {
    const allocator = std.testing.allocator;
    
    const cur = heap.Value{ .Currency = .{ .code = "USD".* } };
    const encoded = try heap.encodeValue(allocator, cur);
    defer allocator.free(encoded);
    
    const decoded = try heap.decodeValue(allocator, encoded);
    
    try std.testing.expect(decoded == .Currency);
    try std.testing.expectEqualSlices(u8, &cur.Currency.code, &decoded.Currency.code);
}

test "LatLon encode/decode" {
    const allocator = std.testing.allocator;
    
    const ll = heap.Value{ .LatLon = .{ .lat = 51.5, .lon = -0.1 } };
    const encoded = try heap.encodeValue(allocator, ll);
    defer allocator.free(encoded);
    
    const decoded = try heap.decodeValue(allocator, encoded);
    
    try std.testing.expect(decoded == .LatLon);
    try std.testing.expectApproxEqAbs(ll.LatLon.lat, decoded.LatLon.lat, 0.0001);
    try std.testing.expectApproxEqAbs(ll.LatLon.lon, decoded.LatLon.lon, 0.0001);
}

test "VectorF32 encode/decode" {
    const allocator = std.testing.allocator;
    
    const data = [_]f32{ 1.0, 2.0, 3.0 };
    const vec = heap.Value{ .VectorF32 = .{ .dim = 3, .data = &data } };
    const encoded = try heap.encodeValue(allocator, vec);
    defer allocator.free(encoded);
    
    const decoded = try heap.decodeValue(allocator, encoded);
    defer allocator.free(decoded.VectorF32.data);
    
    try std.testing.expect(decoded == .VectorF32);
    try std.testing.expectEqual(@as(u16, 3), decoded.VectorF32.dim);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), decoded.VectorF32.data[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), decoded.VectorF32.data[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), decoded.VectorF32.data[2], 0.0001);
}

test "Patricia trie insert and LPM" {
    const allocator = std.testing.allocator;
    
    var trie = patricia.PatriciaTrie.init(allocator, .v4);
    defer trie.deinit();
    
    const subnet = heap.Subnet{ .addr = .{ .v4 = .{ 192, 168, 0, 0 } }, .prefix_len = 16 };
    try trie.insert(subnet, 1);
    
    const query_ip = heap.IpAddr{ .v4 = .{ 192, 168, 5, 4 } };
    const match = trie.longestPrefixMatch(query_ip);
    
    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(u8, 16), match.?.prefix_len);
}

test "R-tree insert and search" {
    const allocator = std.testing.allocator;
    
    var tree = rtree.RTree.init(allocator, 50);
    defer tree.deinit();
    
    const mbr1 = rtree.MBR{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 };
    const mbr2 = rtree.MBR{ .min_x = 5, .min_y = 5, .max_x = 15, .max_y = 15 };
    
    try tree.insert(mbr1, 1);
    try tree.insert(mbr2, 2);
    
    var results = std.ArrayList(u64).init(allocator);
    defer results.deinit();
    
    const query = rtree.MBR{ .min_x = 7, .min_y = 7, .max_x = 8, .max_y = 8 };
    try tree.search(query, &results);
    
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
}

test "HNSW insert and kNN search" {
    const allocator = std.testing.allocator;
    
    var index = hnsw.Hnsw.init(allocator, 3, 4, 10);
    defer index.deinit();
    
    const v1 = [_]f32{ 1.0, 0.0, 0.0 };
    const v2 = [_]f32{ 0.0, 1.0, 0.0 };
    const v3 = [_]f32{ 0.0, 0.0, 1.0 };
    
    try index.insert(1, &v1);
    try index.insert(2, &v2);
    try index.insert(3, &v3);
    
    const query = [_]f32{ 0.9, 0.1, 0.0 };
    const results = try index.knnSearch(&query, 2, .l2);
    defer allocator.free(results);
    
    try std.testing.expect(results.len > 0);
    try std.testing.expectEqual(@as(u64, 1), results[0].id);
}

test "ip_contains function" {
    const allocator = std.testing.allocator;
    
    const subnet = heap.Subnet{ .addr = .{ .v4 = .{ 192, 168, 0, 0 } }, .prefix_len = 16 };
    const ip = heap.IpAddr{ .v4 = .{ 192, 168, 5, 4 } };
    
    const args = [_]eval_extended.ExtValue{
        .{ .Subnet = subnet },
        .{ .IpAddr = ip },
    };
    
    const result = try eval_extended.ipContains(allocator, &args);
    try std.testing.expectEqual(true, result.Bool);
}

test "haversine distance" {
    const allocator = std.testing.allocator;
    
    const p1 = heap.LatLon{ .lat = 0, .lon = 0 };
    const p2 = heap.LatLon{ .lat = 0, .lon = 1 };
    
    const args = [_]eval_extended.ExtValue{
        .{ .LatLon = p1 },
        .{ .LatLon = p2 },
    };
    
    const result = try eval_extended.distanceHaversine(allocator, &args);
    
    // Should be approximately 111195 meters at the equator
    try std.testing.expect(result.Int > 111000);
    try std.testing.expect(result.Int < 112000);
}

test "vector dot product" {
    const allocator = std.testing.allocator;
    
    const v1 = heap.VectorF32{ .dim = 3, .data = &[_]f32{ 1, 2, 3 } };
    const v2 = heap.VectorF32{ .dim = 3, .data = &[_]f32{ 4, 5, 6 } };
    
    const args = [_]eval_extended.ExtValue{
        .{ .VectorF32 = v1 },
        .{ .VectorF32 = v2 },
    };
    
    const result = try eval_extended.vectorDot(allocator, &args);
    try std.testing.expectEqual(@as(i64, 32), result.Int);
}

test "MAC address bit flags" {
    const mac1 = heap.Mac{ .bytes = .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 } }; // Local
    const mac2 = heap.Mac{ .bytes = .{ 0x01, 0x00, 0x00, 0x00, 0x00, 0x01 } }; // Multicast
    
    const is_local1 = (mac1.bytes[0] & 0x02) != 0;
    const is_multicast1 = (mac1.bytes[0] & 0x01) != 0;
    
    const is_local2 = (mac2.bytes[0] & 0x02) != 0;
    const is_multicast2 = (mac2.bytes[0] & 0x01) != 0;
    
    try std.testing.expectEqual(true, is_local1);
    try std.testing.expectEqual(false, is_multicast1);
    try std.testing.expectEqual(false, is_local2);
    try std.testing.expectEqual(true, is_multicast2);
}

test "Currency minor units" {
    const allocator = std.testing.allocator;
    
    const usd = heap.Currency{ .code = "USD".* };
    const jpy = heap.Currency{ .code = "JPY".* };
    const bhd = heap.Currency{ .code = "BHD".* };
    
    const usd_val = eval_extended.ExtValue{ .Currency = usd };
    const jpy_val = eval_extended.ExtValue{ .Currency = jpy };
    const bhd_val = eval_extended.ExtValue{ .Currency = bhd };
    
    const usd_units = try eval_extended.currencyMinorUnits(allocator, &[_]eval_extended.ExtValue{usd_val});
    const jpy_units = try eval_extended.currencyMinorUnits(allocator, &[_]eval_extended.ExtValue{jpy_val});
    const bhd_units = try eval_extended.currencyMinorUnits(allocator, &[_]eval_extended.ExtValue{bhd_val});
    
    try std.testing.expectEqual(@as(i64, 2), usd_units.Int);
    try std.testing.expectEqual(@as(i64, 0), jpy_units.Int);
    try std.testing.expectEqual(@as(i64, 3), bhd_units.Int);
}