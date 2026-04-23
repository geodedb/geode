const std = @import("std");
const testing = std.testing;
const sharded = @import("geode").sharded_store;

test "ShardedStore: put/get round-trip across all shards" {
    var store = try sharded.ShardedStore(u64, u32).init(testing.allocator);
    defer store.deinit();

    // Put enough keys that at least one lands in every shard by
    // virtue of the mixing function.
    var i: u64 = 0;
    while (i < 1024) : (i += 1) {
        try store.put(i, @as(u32, @intCast(i * 3)));
    }
    i = 0;
    while (i < 1024) : (i += 1) {
        try testing.expectEqual(@as(u32, @intCast(i * 3)), store.get(i).?);
    }

    // Every shard got at least one key.
    var populated: usize = 0;
    for (0..sharded.SHARD_COUNT) |s| {
        if (store.shardLen(s) > 0) populated += 1;
    }
    try testing.expect(populated == sharded.SHARD_COUNT);
}

test "ShardedStore: shardIndex is stable for the same key" {
    try testing.expectEqual(sharded.shardIndex(42), sharded.shardIndex(42));
    try testing.expectEqual(sharded.shardIndex(0), sharded.shardIndex(0));
}

test "ShardedStore: remove returns the prior value" {
    var store = try sharded.ShardedStore(u64, u32).init(testing.allocator);
    defer store.deinit();
    try store.put(7, 99);
    const removed = store.remove(7);
    try testing.expectEqual(@as(?u32, 99), removed);
    try testing.expect(store.get(7) == null);
}

test "ShardedStore: total count sums the shards" {
    var store = try sharded.ShardedStore(u64, u32).init(testing.allocator);
    defer store.deinit();
    try store.put(1, 1);
    try store.put(2, 2);
    try store.put(3, 3);
    try testing.expectEqual(@as(usize, 3), store.count());
}

test "ShardedStore: fetchRemove returns the full entry" {
    var store = try sharded.ShardedStore(u64, u32).init(testing.allocator);
    defer store.deinit();
    try store.put(11, 22);
    const kv = store.fetchRemove(11).?;
    try testing.expectEqual(@as(u64, 11), kv.key);
    try testing.expectEqual(@as(u32, 22), kv.value);
    try testing.expect(store.fetchRemove(11) == null);
}

test "ShardedStore: getOrPut gives the right slot" {
    var store = try sharded.ShardedStore(u64, u32).init(testing.allocator);
    defer store.deinit();

    const first = try store.getOrPut(7);
    try testing.expect(!first.found_existing);
    first.value_ptr.* = 100;

    const second = try store.getOrPut(7);
    try testing.expect(second.found_existing);
    try testing.expectEqual(@as(u32, 100), second.value_ptr.*);
    second.value_ptr.* = 200;

    try testing.expectEqual(@as(u32, 200), store.get(7).?);
}

test "ShardedStore: ensureTotalCapacity spreads capacity across shards" {
    var store = try sharded.ShardedStore(u64, u32).init(testing.allocator);
    defer store.deinit();
    try store.ensureTotalCapacity(1024);
    // Capacity per shard is at least 1024 / SHARD_COUNT = 64, so
    // inserting 64 into one shard should not rehash under AutoHashMap
    // semantics.  Insert and confirm correctness.
    var i: u64 = 0;
    while (i < 64) : (i += 1) {
        try store.put(i * @as(u64, @intCast(sharded.SHARD_COUNT)), @as(u32, @intCast(i)));
    }
    try testing.expectEqual(@as(usize, 64), store.count());
}

test "ShardedStore: clearRetainingCapacity empties every shard" {
    var store = try sharded.ShardedStore(u64, u32).init(testing.allocator);
    defer store.deinit();
    var i: u64 = 0;
    while (i < 100) : (i += 1) try store.put(i, @as(u32, @intCast(i)));
    try testing.expectEqual(@as(usize, 100), store.count());
    store.clearRetainingCapacity();
    try testing.expectEqual(@as(usize, 0), store.count());
    for (0..sharded.SHARD_COUNT) |s| try testing.expectEqual(@as(usize, 0), store.shardLen(s));
}

test "ShardedStore: keyIterator visits every key exactly once" {
    var store = try sharded.ShardedStore(u64, u32).init(testing.allocator);
    defer store.deinit();

    var seen = std.AutoHashMap(u64, void).init(testing.allocator);
    defer seen.deinit();

    var i: u64 = 1;
    while (i <= 200) : (i += 1) try store.put(i, @as(u32, @intCast(i)));

    var it = store.keyIterator();
    while (it.next()) |k| {
        try testing.expect(!seen.contains(k.*));
        try seen.put(k.*, {});
    }
    try testing.expectEqual(@as(usize, 200), seen.count());
}

test "ShardedStore: iterator visits every entry exactly once" {
    var store = try sharded.ShardedStore(u64, u32).init(testing.allocator);
    defer store.deinit();

    var i: u64 = 1;
    while (i <= 50) : (i += 1) try store.put(i, @as(u32, @intCast(i * 10)));

    var sum: u64 = 0;
    var visited: usize = 0;
    var it = store.iterator();
    while (it.next()) |entry| {
        sum += entry.value_ptr.*;
        visited += 1;
    }
    try testing.expectEqual(@as(usize, 50), visited);
    // Σ(10*k for k=1..50) = 10 * (50*51/2) = 12750
    try testing.expectEqual(@as(u64, 12750), sum);
}
