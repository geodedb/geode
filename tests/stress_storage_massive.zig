const std = @import("std");
const testing = std.testing;
const graph_store = @import("geode").graph_store;

// Stress Parameters
const MASSIVE_ITEM_COUNT = 200_000;
const DELETE_RATIO = 0.40; // 40% deletion
const RELOAD_RATIO = 0.20; // 20% reload

test "massive graph store stress test" {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(data_dir);

    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();

    try store.reserve(MASSIVE_ITEM_COUNT, 0);

    std.debug.print("\n=== [Stress Test] GraphStore Stability ({d} items) ===\n", .{MASSIVE_ITEM_COUNT});

    // Bulk Load Phase
    std.debug.print("[Phase 1] Bulk Loading {d} items...\n", .{MASSIVE_ITEM_COUNT});
    var timer = try std.time.Timer.start();

    var items = try std.ArrayList(ItemLoc).initCapacity(allocator, MASSIVE_ITEM_COUNT);
    defer items.deinit(allocator);

    var prng = std.rand.DefaultPrng.init(0);
    const random = prng.random();
    const labels = [_][]const u8{ "Item" };

    var i: usize = 0;
    while (i < MASSIVE_ITEM_COUNT) : (i += 1) {
        // Generate pseudo-random payload (64-128 bytes)
        var payload: [128]u8 = undefined;
        const len = 64 + random.uintLessThan(usize, 64);
        random.bytes(payload[0..len]);

        const hash = std.hash.Wyhash.hash(0, payload[0..len]);
        const hash_i64: i64 = @bitCast(hash);

        const node_id = try store.createNode(labels[0..]);
        try store.setNodeProperty(node_id, "hash", .{ .Int = hash_i64 });

        try items.append(allocator, .{
            .node_id = node_id,
            .hash = hash,
        });
    }

    try store.saveToFile();

    const load_time = timer.read();
    std.debug.print(" -> Loaded in {d:.2}s ({d} items/s)\n", .{ @as(f64, @floatFromInt(load_time)) / 1e9, MASSIVE_ITEM_COUNT * 1_000_000_000 / load_time });

    // Fragmentation Phase (Deletes)
    const delete_count = @as(usize, @intFromFloat(MASSIVE_ITEM_COUNT * DELETE_RATIO));
    std.debug.print("[Phase 2] Deleting {d} items...\n", .{delete_count});
    timer.reset();

    var deleted: usize = 0;
    while (deleted < delete_count) {
        const idx = random.uintLessThan(usize, items.items.len);
        if (items.items[idx].deleted) continue;
        store.deleteNode(items.items[idx].node_id);
        items.items[idx].deleted = true;
        deleted += 1;
    }

    try store.saveToFile();

    const delete_time = timer.read();
    std.debug.print(" -> Deleted in {d:.2}s\n", .{@as(f64, @floatFromInt(delete_time)) / 1e9});

    // Reload Phase (insert more nodes)
    const reload_count = @as(usize, @intFromFloat(MASSIVE_ITEM_COUNT * RELOAD_RATIO));
    std.debug.print("[Phase 3] Reloading {d} items...\n", .{reload_count});
    timer.reset();

    i = 0;
    while (i < reload_count) : (i += 1) {
        var payload: [128]u8 = undefined;
        const len = 64 + random.uintLessThan(usize, 64);
        random.bytes(payload[0..len]);
        const hash = std.hash.Wyhash.hash(0, payload[0..len]);
        const hash_i64: i64 = @bitCast(hash);

        const node_id = try store.createNode(labels[0..]);
        try store.setNodeProperty(node_id, "hash", .{ .Int = hash_i64 });
    }

    try store.saveToFile();

    const reload_time = timer.read();
    std.debug.print(" -> Reloaded in {d:.2}s\n", .{@as(f64, @floatFromInt(reload_time)) / 1e9});

    // Integrity Check (reload from disk)
    std.debug.print("[Phase 4] Verifying Integrity of Remaining Items...\n", .{});

    var reloaded = graph_store.GraphStore.init(allocator);
    defer reloaded.deinit();
    try reloaded.loadFromFile();

    var verified: usize = 0;
    for (items.items) |item| {
        if (item.deleted) continue;
        const node = reloaded.getNodePtr(item.node_id) orelse return error.MissingNode;
        _ = node;
        const prop = reloaded.getNodeProperty(item.node_id, "hash") orelse return error.MissingProperty;
        const stored_hash = switch (prop) {
            .Int => |v| @as(u64, @bitCast(v)),
            else => return error.InvalidPropertyType,
        };
        try testing.expectEqual(item.hash, stored_hash);
        verified += 1;
    }

    std.debug.print(" -> Verified {d} items successfully.\n", .{verified});
    std.debug.print("\n=== Stress Test Passed ===\n", .{});
}

const ItemLoc = struct {
    node_id: u64,
    hash: u64,
    deleted: bool = false,
};
