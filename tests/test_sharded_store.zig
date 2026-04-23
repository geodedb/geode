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
        if (store.shardCount(s) > 0) populated += 1;
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
