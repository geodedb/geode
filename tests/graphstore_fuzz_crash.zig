const std = @import("std");
const graph_store = @import("geode").graph_store;

fn randBool(r: *std.rand.DefaultPrng) bool {
    return (r.random().int(u8) & 1) == 1;
}

// Lightweight crash fuzz: random inserts/deletes with snapshot truncation and recovery idempotence.
test "graphstore crash fuzz mini" {
    var prng = std.rand.DefaultPrng.init(0xdeadbeef);
    const R = prng.random();
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    graph_store.setDataDirOverride(allocator, tmp.dir_path);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var ids = std.ArrayList(u64).init(allocator);
    defer ids.deinit(allocator);

    var step: usize = 0;
    while (step < 80) : (step += 1) {
        if (ids.items.len == 0 or randBool(&prng)) {
            const id = try store.createNode(&.{"r"});
            try ids.append(allocator, id);
        } else {
            const idx = R.intRangeLessThan(usize, 0, ids.items.len);
            const id = ids.items[idx];
            store.deleteNode(id);
            _ = ids.swapRemove(idx);
        }
        if (R.int(u8) % 23 == 0) break; // crash point
    }

    try store.saveToFile();
    const saved_nodes = store.getNodeCount();

    // Truncate snapshot to simulate crash (50% of the time).
    if (R.int(u8) & 1 == 1) {
        const file_path = try graph_store.getPersistenceFilePath(allocator);
        defer allocator.free(file_path);
        var f = try std.fs.cwd().openFile(file_path, .{ .mode = .read_write });
        const st = try f.stat();
        try f.truncate(st.size / 2);
        f.close();
    }

    // Recover into new structures twice (idempotence).
    var store2 = try graph_store.GraphStore.init(allocator);
    defer store2.deinit();
    const res = store2.loadFromFile();
    if (res) |_| {} else |err| switch (err) {
        error.ChecksumMismatch, error.InvalidHeader, error.InvalidMagic => {},
        else => return err,
    }

    var store3 = try graph_store.GraphStore.init(allocator);
    defer store3.deinit();
    if (store2.getNodeCount() > 0) {
        try store3.loadFromFile();
        try std.testing.expect(store3.getNodeCount() <= saved_nodes);
    }
}
