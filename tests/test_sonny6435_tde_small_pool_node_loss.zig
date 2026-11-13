// SONNY-6435 (found by item 2): INTENTIONALLY RED reproduction of a
// graph_storage defect (docs/KNOWN_TEST_ISSUES.md). With an encryption key
// (GEODE_TDE_KEY) and a buffer pool smaller than the store, the storage
// engine loses committed node records: `getNode` of a node written earlier
// returns null (an empty slot) once its page has been evicted and read back.
// The same operation sequence without a key keeps every node.
//
// Operator reach: GEODE_BUFFER_POOL_PAGES with GEODE_BUFFER_POOL_AUTO_SIZE=0
// (graph_store.initGlobalAdapter), or any store larger than the pool.
// The fix belongs in graph_storage (pinned 0.4.10); this step stays out of
// the aggregate until it lands.
const std = @import("std");
const builtin = @import("builtin");
const gs = @import("graph_storage");
const test_scratch = @import("test_scratch.zig");

const testing = std.testing;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Insert `n` nodes, each with a 512-byte property, checkpointing every 256,
/// and read back a random earlier node after every insert. Returns how many
/// of those reads found no node.
fn lostReads(dir: []const u8, key: ?[32]u8, n: usize) !usize {
    try std.Io.Dir.cwd().createDirPath(fsIo(), dir);
    const eng = try gs.ShardedGraphEngine.create(testing.allocator, dir, [_]u8{0x35} ** 16, .{
        .data_dir = dir,
        .encryption_key = key,
        .sync_mode = .deferred,
        .buffer_pool_pages = 8,
        .buffer_pool_auto_size = false,
    });
    defer eng.close() catch {};
    var ids: std.ArrayListUnmanaged(gs.NodeId) = .empty;
    defer ids.deinit(testing.allocator);
    var prng = std.Random.DefaultPrng.init(0x6435);
    const r = prng.random();
    var payload: [512]u8 = undefined;
    var lost: usize = 0;
    for (0..n) |i| {
        r.bytes(&payload);
        const id = try eng.allocNode();
        try eng.putNode(id, gs.test_support.emptyNode(1));
        var rec = (try eng.getNode(id)).?;
        rec.prop_head = try eng.putNodeProperty(id, rec.prop_head, "payload", .{ .string = &payload });
        try eng.putNode(id, rec);
        try ids.append(testing.allocator, id);
        const earlier = ids.items[r.uintLessThan(usize, ids.items.len)];
        if ((try eng.getNode(earlier)) == null) lost += 1;
        if ((i + 1) % 256 == 0) try eng.checkpoint();
    }
    return lost;
}

test "SONNY-6435 graph_storage keeps every committed node with page encryption and a small buffer pool" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var root = try test_scratch.ScratchDir.create("sonny6435-tde-pool");
    defer root.remove();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const plain_lost = try lostReads(try std.fmt.bufPrint(&buf, "{s}/plain", .{root.path()}), null, 2000);
    const tde_lost = try lostReads(try std.fmt.bufPrint(&buf, "{s}/tde", .{root.path()}), [_]u8{0x35} ** 32, 2000);
    std.debug.print("SONNY-6435 small-pool reads that found no node: plain={d} tde={d}\n", .{ plain_lost, tde_lost });
    try testing.expectEqual(@as(usize, 0), plain_lost);
    try testing.expectEqual(@as(usize, 0), tde_lost);
}
