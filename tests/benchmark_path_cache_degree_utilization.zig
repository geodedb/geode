const std = @import("std");
const path_cache = @import("../src/planner/path_cache.zig");

// CANARY: REQ=REQ-GQL-021; FEATURE="PathCache"; ASPECT=PathCacheDegreeUtilization; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_021_PathCacheDegreeUtilization; OWNER=planner; UPDATED=2025-09-23

fn simulateAccess(cache: *path_cache.PathCache, keys: [][]const u8) void {
    var i: usize = 0;
    while (i < keys.len) : (i += 1) {
        if (cache.get(keys[i]) == null) {
            cache.put(keys[i], keys[i]);
        }
    }
}

test "BenchmarkCANARY_REQ_GQL_021_PathCacheDegreeUtilization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();

    var cache = try path_cache.PathCache.init(ally, 256);
    defer cache.deinit();
    try cache.enableDistribution(64);

    var keys_hot = try ally.alloc([]const u8, 1024);
    var keys_cold = try ally.alloc([]const u8, 1024);
    defer ally.free(keys_hot);
    defer ally.free(keys_cold);

    var i: usize = 0;
    while (i < 1024) : (i += 1) {
        keys_hot[i] = try std.fmt.allocPrint(ally, "hot-{d}", .{i});
        keys_cold[i] = try std.fmt.allocPrint(ally, "cold-{d}", .{i});
    }
    defer {
        var j: usize = 0;
        while (j < 1024) : (j += 1) {
            ally.free(keys_hot[j]);
            ally.free(keys_cold[j]);
        }
    }

    simulateAccess(&cache, keys_hot);
    simulateAccess(&cache, keys_hot);
    simulateAccess(&cache, keys_cold);

    const ent = cache.normalizedEntropy();
    try std.testing.expect(ent >= 0.92);
}
