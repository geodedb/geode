const std = @import("std");
const graph_store = @import("geode").graph_store;

// Expanded recovery fuzz: 1000 seeds, random truncation & checksum corruption injection.
// Invariants:
//  - Recovery does not crash on corruption.
//  - Load is idempotent when it succeeds.
test "graphstore crash fuzz expanded 1k" {
    const allocator = std.testing.allocator;
    var seed: u64 = 1;
    while (seed <= 1000) : (seed += 1) {
        var prng = std.rand.DefaultPrng.init(seed);
        const R = prng.random();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        graph_store.setDataDirOverride(allocator, tmp.dir_path);
        defer graph_store.setDataDirOverride(allocator, null);

        var store = try graph_store.GraphStore.init(allocator);
        defer store.deinit();

        var ids = std.ArrayList(u64).init(allocator);
        defer ids.deinit(allocator);

        var op: usize = 0;
        while (op < 120) : (op += 1) {
            if (ids.items.len == 0 or (R.int(u8) % 3) != 0) {
                const id = try store.createNode(&.{"x"});
                try ids.append(allocator, id);
            } else {
                const idx = R.intRangeLessThan(usize, 0, ids.items.len);
                const id = ids.items[idx];
                store.deleteNode(id);
                _ = ids.swapRemove(idx);
            }
            if (R.int(u8) % 41 == 0) break;
        }

        try store.saveToFile();
        const saved_nodes = store.getNodeCount();

        // Random tail truncation or checksum corruption.
        const file_path = try graph_store.getPersistenceFilePath(allocator);
        defer allocator.free(file_path);
        var f = try std.fs.cwd().openFile(file_path, .{ .mode = .read_write });
        const file_size = try f.getEndPos();
        if (file_size > 64) {
            const dice = R.int(u8);
            if (dice < 51) { // ~20% truncation
                const cut = file_size - @as(u64, dice % 32);
                try f.setEndPos(cut);
            } else if (dice < 102) { // ~20% checksum flip
                const off = file_size - 8;
                var buf: [4]u8 = undefined;
                if (try f.readAt(off, &buf) == 4) {
                    buf[0] ^= 0xFF;
                    buf[1] ^= 0xAA;
                    buf[2] ^= 0x55;
                    buf[3] ^= 0x11;
                    _ = try f.writeAt(off, &buf);
                }
            }
        }
        f.close();

        var store2 = try graph_store.GraphStore.init(allocator);
        defer store2.deinit();
        const res = store2.loadFromFile();
        if (res) |_| {
            var store3 = try graph_store.GraphStore.init(allocator);
            defer store3.deinit();
            try store3.loadFromFile();
            try std.testing.expectEqual(store2.getNodeCount(), store3.getNodeCount());
            try std.testing.expect(store3.getNodeCount() <= saved_nodes);
        } else |err| switch (err) {
            error.ChecksumMismatch, error.InvalidHeader, error.InvalidMagic => {},
            else => return err,
        }
    }
}
