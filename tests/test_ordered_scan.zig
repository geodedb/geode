// H3-P2: value-ordered scan + ordered-index registration.
//
// Task 1 — registration: `StorageAdapter.createOrderedIndex` registers a
//   value-ordered secondary index on (label,key) on EVERY one of the 16 engine
//   shards (alongside the always-on exact index), built from a live scan.
//
// These exercise the public adapter surface end-to-end against a real on-disk
// engine in a tmpDir (no system geode instance is touched).

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const gs = @import("graph_storage");

const adapter_mod = geode.graph_storage_adapter;
const StorageAdapter = adapter_mod.StorageAdapter;

fn testConfig() gs.GraphConfig {
    return .{ .page_size = 4096, .buffer_pool_pages = 256 };
}

const Pair = struct { value: i64, node_id: u64 };

// Seed `n` nodes of label `label` with property `key` = a scattered unique
// permutation of [0, n). Returns the (value,node_id) pairs in creation order.
fn seed(
    allocator: std.mem.Allocator,
    adapter: *StorageAdapter,
    graph: []const u8,
    label: []const u8,
    key: []const u8,
    n: usize,
) ![]Pair {
    const pairs = try allocator.alloc(Pair, n);
    errdefer allocator.free(pairs);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const node_id = try adapter.createNode(graph, &[_][]const u8{label});
        // (i*7) % n is a permutation of [0,n) for n=64 (gcd(7,64)==1), so values
        // are unique and NOT in node-id order — a real merge is required.
        const value: i64 = @intCast((i * 7) % n);
        try adapter.setNodeProperty(graph, node_id, key, .{ .Int = value });
        pairs[i] = .{ .value = value, .node_id = node_id };
    }
    return pairs;
}

// ===========================================================================
// Task 1: registration
// ===========================================================================

test "createOrderedIndex registers ordered index on every shard" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    const graph = "g";
    const pairs = try seed(allocator, adapter, graph, "T", "k", 64);
    defer allocator.free(pairs);

    // Sanity: the seeded nodes must span more than one shard, else the merge is
    // not really exercised.
    var seen_shards = std.AutoHashMap(usize, void).init(allocator);
    defer seen_shards.deinit();
    for (pairs) |p| try seen_shards.put(gs.shard_count.shardOfNode(p.node_id), {});
    try testing.expect(seen_shards.count() > 1);

    try adapter.createOrderedIndex(graph, "T", "k");

    const mg = try adapter.getOrCreateGraph(graph);
    const label_id = mg.label_dict.getId("T").?;
    for (mg.engine.shards) |shard| {
        try testing.expect(shard.hasOrderedIndex(label_id, "k"));
    }
}
