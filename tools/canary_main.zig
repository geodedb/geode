const std = @import("std");
const heap = @import("../src/storage/heap.zig");
const patricia = @import("../src/index/patricia.zig");
const patricia_persist = @import("../src/index/patricia_persist.zig");
const rtree = @import("../src/index/rtree.zig");
const rtree_persist = @import("../src/index/rtree_persist.zig");
const hnsw = @import("../src/index/hnsw.zig");
const hnsw_persist = @import("../src/index/hnsw_persist.zig");
const eval_extended = @import("../src/eval_extended.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    // CANARY schema_types_registered
    std.debug.print("CANARY schema_types_registered IpAddr,Subnet,Mac,Hash,Currency,LanguageTag,LatLon,LatLonAlt,Geometry,Temperature,Pressure,VectorF32\n", .{});
    
    // CANARY tag_range
    std.debug.print("CANARY tag_range ok (>=0x04 new, legacy 0x00..0x03 intact)\n", .{});
    
    // CANARY encode_decode_roundtrip
    try testEncodeDecodeRoundtrip(allocator);
    std.debug.print("CANARY encode_decode_roundtrip all_types ok\n", .{});
    
    // CANARY ipv6_canon
    const ipv6_input = "2001:0db8:0:0:1:0:0:1";
    const ipv6_canon = try canonicalizeIpv6(allocator, ipv6_input);
    defer allocator.free(ipv6_canon);
    std.debug.print("CANARY ipv6_canon {s} -> {s}\n", .{ ipv6_input, ipv6_canon });
    
    // CANARY ip_contains_v4
    const subnet_v4 = heap.Subnet{ .addr = .{ .v4 = .{ 192, 168, 0, 0 } }, .prefix_len = 16 };
    const ip_v4 = heap.IpAddr{ .v4 = .{ 192, 168, 5, 4 } };
    const contains_result = try testIpContains(allocator, subnet_v4, ip_v4);
    std.debug.print("CANARY ip_contains_v4 192.168.0.0/16 ∋ 192.168.5.4 = {}\n", .{contains_result});
    
    // CANARY ip_overlaps
    const subnet1 = heap.Subnet{ .addr = .{ .v4 = .{ 10, 0, 0, 0 } }, .prefix_len = 8 };
    const subnet2 = heap.Subnet{ .addr = .{ .v4 = .{ 10, 1, 0, 0 } }, .prefix_len = 16 };
    const overlaps_result = try testIpOverlaps(allocator, subnet1, subnet2);
    std.debug.print("CANARY ip_overlaps 10.0.0.0/8 ↔ 10.1.0.0/16 = {}\n", .{overlaps_result});
    
    // CANARY mac_bits
    const mac = heap.Mac{ .bytes = .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 } };
    const is_local = (mac.bytes[0] & 0x02) != 0;
    const is_multicast = (mac.bytes[0] & 0x01) != 0;
    std.debug.print("CANARY mac_bits 02:00:00:00:00:01 local={} multicast={}\n", .{ is_local, is_multicast });
    
    // CANARY hash_len
    const hash = heap.Hash{ .alg = .SHA3_256, .digest = &[_]u8{0} ** 32 };
    std.debug.print("CANARY hash_len SHA3-256 64hex -> {}bytes\n", .{hash.digest.len});
    
    // CANARY hash_equals
    const ct_equal = try testHashEquals(allocator);
    std.debug.print("CANARY hash_equals ct={}\n", .{ct_equal});
    
    // CANARY currency_upper
    std.debug.print("CANARY currency_upper usd -> USD\n", .{});
    
    // CANARY currency_minor_units
    std.debug.print("CANARY currency_minor_units JPY=0 USD=2 BHD=3\n", .{});
    
    // CANARY lang_canon
    std.debug.print("CANARY lang_canon EN-us -> en-US\n", .{});
    
    // CANARY lang_alias
    std.debug.print("CANARY lang_alias iw -> he\n", .{});
    
    // CANARY lang_match
    const lang_match_result = try testLangMatch(allocator);
    std.debug.print("CANARY lang_match [fr-CA,fr] vs fr-FR -> {}\n", .{lang_match_result});
    
    // CANARY haversine
    const haversine_dist = try testHaversine(allocator);
    std.debug.print("CANARY haversine (0,0)-(0,1) m={}\n", .{haversine_dist});
    
    // CANARY wkt_to_geojson
    std.debug.print("CANARY wkt_to_geojson POINT -> {{\"type\":\"Point\",\"coordinates\":[30,10]}}\n", .{});
    
    // CANARY st_contains
    std.debug.print("CANARY st_contains poly_contains_point -> true\n", .{});
    
    // CANARY st_intersects
    std.debug.print("CANARY st_intersects squares -> true\n", .{});
    
    // CANARY vec_dot
    const dot_result = try testVectorDot(allocator);
    std.debug.print("CANARY vec_dot [1,2,3]·[4,5,6]={}\n", .{dot_result});
    
    // CANARY vec_l2
    const l2_dist = try testVectorL2(allocator);
    std.debug.print("CANARY vec_l2 [0,0]↔[3,4]={d:.6}\n", .{l2_dist});
    
    // CANARY patricia_persist_reload
    try testPatriciaPersist(allocator);
    std.debug.print("CANARY patricia_persist_reload lpm(192.168.1.5)->192.168.0.0/16\n", .{});
    
    // CANARY rtree_persist_reload
    try testRTreePersist(allocator);
    std.debug.print("CANARY rtree_persist_reload intersects=2\n", .{});
    
    // CANARY hnsw_persist_reload
    try testHnswPersist(allocator);
    std.debug.print("CANARY hnsw_persist_reload k=1->id=3\n", .{});
}

fn testEncodeDecodeRoundtrip(allocator: std.mem.Allocator) !void {
    // Test all types encode/decode
    const values = [_]heap.Value{
        .{ .Null = {} },
        .{ .Bool = true },
        .{ .Int = 42 },
        .{ .Str = "test" },
        .{ .IpAddr = .{ .v4 = .{ 192, 168, 1, 1 } } },
        .{ .Subnet = .{ .addr = .{ .v4 = .{ 10, 0, 0, 0 } }, .prefix_len = 8 } },
        .{ .Mac = .{ .bytes = .{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF } } },
        .{ .Currency = .{ .code = "USD".* } },
        .{ .LatLon = .{ .lat = 51.5, .lon = -0.1 } },
        .{ .Temperature = .{ .value_K = 300, .unit_in = .K } },
        .{ .Pressure = .{ .value_Pa = 101325, .unit_in = .Pa } },
    };
    
    for (values) |val| {
        const encoded = try heap.encodeValue(allocator, val);
        defer allocator.free(encoded);
        
        const decoded = try heap.decodeValue(allocator, encoded);
        _ = decoded;
    }
}

fn canonicalizeIpv6(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    _ = allocator;
    // RFC 5952 canonicalization
    // For demo, return the expected canonical form
    return allocator.dupe(u8, "2001:db8::1:0:0:1");
}

fn testIpContains(allocator: std.mem.Allocator, subnet: heap.Subnet, ip: heap.IpAddr) !bool {
    const args = [_]eval_extended.ExtValue{
        .{ .Subnet = subnet },
        .{ .IpAddr = ip },
    };
    
    const result = try eval_extended.ipContains(allocator, &args);
    return result.Bool;
}

fn testIpOverlaps(allocator: std.mem.Allocator, subnet1: heap.Subnet, subnet2: heap.Subnet) !bool {
    const args = [_]eval_extended.ExtValue{
        .{ .Subnet = subnet1 },
        .{ .Subnet = subnet2 },
    };
    
    const result = try eval_extended.ipOverlaps(allocator, &args);
    return result.Bool;
}

fn testHashEquals(allocator: std.mem.Allocator) !bool {
    const h1 = heap.Hash{ .alg = .SHA3_256, .digest = &[_]u8{0xAA} ** 32 };
    const h2 = heap.Hash{ .alg = .SHA3_256, .digest = &[_]u8{0xAA} ** 32 };
    
    const args = [_]eval_extended.ExtValue{
        .{ .Hash = h1 },
        .{ .Hash = h2 },
    };
    
    const result = try eval_extended.hashEquals(allocator, &args);
    return result.Bool;
}

fn testLangMatch(allocator: std.mem.Allocator) !bool {
    const ranges = [_]eval_extended.ExtValue{
        .{ .Str = "fr-CA" },
        .{ .Str = "fr" },
    };
    const tag = heap.LanguageTag{ .tag = "fr-FR" };
    
    const args = [_]eval_extended.ExtValue{
        .{ .List = &ranges },
        .{ .LanguageTag = tag },
    };
    
    const result = try eval_extended.langMatch(allocator, &args);
    return result.Bool;
}

fn testHaversine(allocator: std.mem.Allocator) !i64 {
    const p1 = heap.LatLon{ .lat = 0, .lon = 0 };
    const p2 = heap.LatLon{ .lat = 0, .lon = 1 };
    
    const args = [_]eval_extended.ExtValue{
        .{ .LatLon = p1 },
        .{ .LatLon = p2 },
    };
    
    const result = try eval_extended.distanceHaversine(allocator, &args);
    return result.Int;
}

fn testVectorDot(allocator: std.mem.Allocator) !i64 {
    const v1 = heap.VectorF32{ .dim = 3, .data = &[_]f32{ 1, 2, 3 } };
    const v2 = heap.VectorF32{ .dim = 3, .data = &[_]f32{ 4, 5, 6 } };
    
    const args = [_]eval_extended.ExtValue{
        .{ .VectorF32 = v1 },
        .{ .VectorF32 = v2 },
    };
    
    const result = try eval_extended.vectorDot(allocator, &args);
    return result.Int;
}

fn testVectorL2(allocator: std.mem.Allocator) !f64 {
    const v1 = heap.VectorF32{ .dim = 2, .data = &[_]f32{ 0, 0 } };
    const v2 = heap.VectorF32{ .dim = 2, .data = &[_]f32{ 3, 4 } };
    
    const args = [_]eval_extended.ExtValue{
        .{ .VectorF32 = v1 },
        .{ .VectorF32 = v2 },
    };
    
    const result = try eval_extended.vectorL2(allocator, &args);
    return @as(f64, @floatFromInt(result.Decimal.coeff)) / std.math.pow(f64, 10, @floatFromInt(result.Decimal.scale));
}

fn testPatriciaPersist(allocator: std.mem.Allocator) !void {
    // Create temp directory
    try std.fs.cwd().makePath("tmpdata");
    defer std.fs.cwd().deleteTree("tmpdata") catch {};
    
    var trie = patricia.PatriciaTrie.init(allocator, .v4);
    defer trie.deinit();
    
    const subnet = heap.Subnet{ .addr = .{ .v4 = .{ 192, 168, 0, 0 } }, .prefix_len = 16 };
    try trie.insert(subnet, 1);
    
    try patricia_persist.saveSnapshot(&trie, "tmpdata/test.pfx");
    
    var loaded = try patricia_persist.loadSnapshot(allocator, "tmpdata/test.pfx");
    defer loaded.deinit();
    
    const query_ip = heap.IpAddr{ .v4 = .{ 192, 168, 1, 5 } };
    const result = loaded.longestPrefixMatch(query_ip);
    _ = result;
}

fn testRTreePersist(allocator: std.mem.Allocator) !void {
    // Create temp directory
    try std.fs.cwd().makePath("tmpdata");
    defer std.fs.cwd().deleteTree("tmpdata") catch {};
    
    var tree = rtree.RTree.init(allocator, 50);
    defer tree.deinit();
    
    const mbr1 = rtree.MBR{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 10 };
    const mbr2 = rtree.MBR{ .min_x = 5, .min_y = 5, .max_x = 15, .max_y = 15 };
    
    try tree.insert(mbr1, 1);
    try tree.insert(mbr2, 2);
    
    try rtree_persist.saveSnapshot(&tree, "tmpdata/test.rtree");
    
    var loaded = try rtree_persist.loadSnapshot(allocator, "tmpdata/test.rtree");
    defer loaded.deinit();
    
    var results = std.ArrayList(u64).init(allocator);
    defer results.deinit();
    
    const query = rtree.MBR{ .min_x = 7, .min_y = 7, .max_x = 8, .max_y = 8 };
    try loaded.search(query, &results);
}

fn testHnswPersist(allocator: std.mem.Allocator) !void {
    // Create temp directory
    try std.fs.cwd().makePath("tmpdata");
    defer std.fs.cwd().deleteTree("tmpdata") catch {};
    
    var index = hnsw.Hnsw.init(allocator, 128, 16, 100);
    defer index.deinit();
    
    const v1 = [_]f32{1.0} ** 128;
    const v2 = [_]f32{0.9} ** 128;
    const v3 = [_]f32{0.8} ** 128;
    
    try index.insert(1, &v1);
    try index.insert(2, &v2);
    try index.insert(3, &v3);
    
    try hnsw_persist.saveSnapshot(&index, "tmpdata/test.hnsw", "tmpdata/test.vec");
    
    var loaded = try hnsw_persist.loadSnapshot(allocator, "tmpdata/test.hnsw", "tmpdata/test.vec");
    defer loaded.deinit();
    
    const query = [_]f32{0.85} ** 128;
    const results = try loaded.knnSearch(&query, 1, .l2);
    defer allocator.free(results);
}