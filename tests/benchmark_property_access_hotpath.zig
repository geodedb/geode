const std = @import("std");

// CANARY: REQ=REQ-GQL-017; FEATURE="Property Access Hot Path"; ASPECT=Engine; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_017_PropertyAccessHotPath; OWNER=engine; UPDATED=2025-09-20

fn propertyLookup(map: *std.StringHashMap(u64), key: []const u8) u64 {
    if (map.get(key)) |v| return v else return 0;
}

fn setup(allocator: std.mem.Allocator, n: usize) !std.StringHashMap(u64) {
    var m = std.StringHashMap(u64).init(allocator);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const k = try std.fmt.allocPrint(allocator, "k{}", .{i});
        defer allocator.free(k);
        try m.put(k, @intCast(i));
    }
    return m;
}

test "BenchmarkCANARY_REQ_GQL_017_PropertyAccessHotPath" {
    const allocator = std.testing.allocator;
    var map = try setup(allocator, 10_000);
    defer map.deinit();

    var timer = try std.time.Timer.start();
    var sum: u64 = 0;
    var i: usize = 0;
    while (i < 1_000_000) : (i += 1) {
        const idx = i % 10_000;
        var buf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "k{d}", .{idx}) catch unreachable;
        sum += propertyLookup(&map, key);
    }
    const elapsed = timer.read();
    std.debug.print("PropertyAccessHotPath ns={} sum={}\n", .{ elapsed, sum });
}
