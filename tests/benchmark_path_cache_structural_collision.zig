const std = @import("std");
const structural_key = @import("../src/planner/structural_key.zig");
const planner_root = @import("../src/planner.zig");

// Random structural pattern generator collision benchmark.
// Generates N random queries and derives structural keys; tracks unique ratio.
// CANARY: REQ=REQ-GQL-021; FEATURE="PathCache"; ASPECT=PathCacheStructuralKeyCollisionEnvelope; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_021_PathCacheStructuralKeyDifferentiation; BENCH=BenchmarkCANARY_REQ_GQL_021_PathCacheStructuralKeyCollisionEnvelope; OWNER=planner; UPDATED=2025-09-21

var seed: u64 = 0x9e3779b97f4a7c15;
fn rng() u64 {
    seed = seed *% 6364136223846793005 +% 1;
    return seed;
}

fn randIn(max: u64) u64 {
    return rng() % max;
}

fn makeRandomQuery(alloc: std.mem.Allocator) planner_root.ast.Query {
    const chain_count: usize = 1 + @as(usize, @intCast(randIn(2))); // 1..2 chains
    var chains_store = alloc.alloc(planner_root.ast.Chain, chain_count) catch unreachable;
    var ci: usize = 0;
    while (ci < chain_count) : (ci += 1) {
        const hop_count: usize = 1 + @as(usize, @intCast(randIn(2))); // 1..2 hops
        var hops_store = alloc.alloc(planner_root.ast.Hop, hop_count) catch unreachable;
        var hi: usize = 0;
        while (hi < hop_count) : (hi += 1) {
            // Random label sets (0..2 labels) from small alphabet
            const left_label_cnt: usize = @as(usize, @intCast(randIn(3)));
            var left_labels = alloc.alloc([]const u8, left_label_cnt) catch unreachable;
            var li: usize = 0;
            while (li < left_label_cnt) : (li += 1) left_labels[li] = switch (randIn(3)) {
                0 => "A",
                1 => "B",
                else => "C",
            };
            const right_label_cnt: usize = @as(usize, @intCast(randIn(3)));
            var right_labels = alloc.alloc([]const u8, right_label_cnt) catch unreachable;
            li = 0;
            while (li < right_label_cnt) : (li += 1) right_labels[li] = switch (randIn(3)) {
                0 => "A",
                1 => "B",
                else => "C",
            };
            // Property key sets (0..2 keys) from {p,q,r}
            const left_prop_cnt: usize = @as(usize, @intCast(randIn(3)));
            var left_props: ?[]planner_root.ast.Property = null;
            if (left_prop_cnt > 0) {
                var props_arr = alloc.alloc(planner_root.ast.Property, left_prop_cnt) catch unreachable;
                var pi: usize = 0;
                while (pi < left_prop_cnt) : (pi += 1) {
                    const key = switch (randIn(3)) {
                        0 => "p",
                        1 => "q",
                        else => "r",
                    };
                    const expr_ptr = alloc.create(planner_root.ast.Expr) catch unreachable;
                    expr_ptr.* = .{ .Int = @intCast(randIn(10)) };
                    props_arr[pi] = .{ .key = key, .value = expr_ptr };
                }
                left_props = props_arr;
            }
            const right_prop_cnt: usize = @as(usize, @intCast(randIn(3)));
            var right_props: ?[]planner_root.ast.Property = null;
            if (right_prop_cnt > 0) {
                var props_arr = alloc.alloc(planner_root.ast.Property, right_prop_cnt) catch unreachable;
                var pi2: usize = 0;
                while (pi2 < right_prop_cnt) : (pi2 += 1) {
                    const key = switch (randIn(3)) {
                        0 => "p",
                        1 => "q",
                        else => "r",
                    };
                    const expr_ptr2 = alloc.create(planner_root.ast.Expr) catch unreachable;
                    expr_ptr2.* = .{ .Int = @intCast(randIn(10)) };
                    props_arr[pi2] = .{ .key = key, .value = expr_ptr2 };
                }
                right_props = props_arr;
            }
            const rel_dir = switch (randIn(3)) {
                0 => planner_root.ast.RelDir.right,
                1 => planner_root.ast.RelDir.left,
                else => planner_root.ast.RelDir.undirected,
            };
            const min_len: ?u32 = if ((rng() & 0x1) == 0) null else @as(u32, @intCast(1 + randIn(2)));
            const max_len: ?u32 = if ((rng() & 0x1) == 0) null else @as(u32, @intCast(1 + randIn(3)));
            const rel = planner_root.ast.RelPattern{ .name = null, .types = &.{}, .props = null, .dir = rel_dir, .min_len = min_len, .max_len = max_len };
            const left_node = planner_root.ast.NodePattern{ .name = null, .labels = left_labels, .props = left_props };
            const right_node = planner_root.ast.NodePattern{ .name = null, .labels = right_labels, .props = right_props };
            hops_store[hi] = planner_root.ast.Hop{ .left = left_node, .rel = rel, .right = right_node };
        }
        chains_store[ci] = planner_root.ast.Chain{ .name = null, .hops = hops_store };
    }
    return .{ .optional_match = false, .match = .{ .chains = chains_store }, .where_clause = null, .with_clause = null, .group_by = null, .having = null, .ret = .{ .items = &.{}, .distinct = false }, .order_by = null, .limit = null, .offset = null };
}

test "BenchmarkCANARY_REQ_GQL_021_PathCacheStructuralKeyCollisionEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const N: usize = 1500;
    var keys = try alloc.alloc([]u8, N);
    defer {
        for (keys) |k| if (k.len > 0) alloc.free(k);
        alloc.free(keys);
    }
    var set = std.StringHashMap(void).init(alloc);
    defer set.deinit();
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const q = makeRandomQuery(alloc);
        const key = try structural_key.deriveStructuralKey(alloc, q);
        keys[i] = key; // store to free later
        _ = set.put(key, {}) catch {};
    }
    const unique = set.count();
    const unique_ratio = @as(f64, @floatFromInt(unique)) / @as(f64, @floatFromInt(N));
    // Expect structural key enrichment to yield low collision rate: >=90% unique.
    if (unique_ratio < 0.90) {
        std.debug.print("VARIANCE_FAIL PathCacheStructuralKeyCollisionEnvelope unique_ratio={d:.3}\n", .{unique_ratio});
        return error.CollisionRateTooHigh;
    }
    std.debug.print("VARIANCE_OK PathCacheStructuralKeyCollisionEnvelope unique_ratio={d:.3}\n", .{unique_ratio});
}
