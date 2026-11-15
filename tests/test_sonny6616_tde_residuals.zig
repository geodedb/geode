// SONNY-6616: residuals of at-rest encryption (TDE) left after SONNY-6590.
//
// Exact-index invalidation. A full checkpoint of a graph whose exact
// property index was never built and that has no nodes left invalidates the
// persisted index (`invalidateExactPropertyIndexFile`). It deleted
// `prop_exact.idx` only and left `prop_rev.idx` - the node -> (label,
// property key, value hash) reverse map of data that no longer exists, with
// the property-key names in it (in plaintext without a key). Both go now.
//
// Real StorageAdapter, real files; every key is generated per test.
//
// CANARY: REQ=REQ-SONNY-6616-EXACT-INDEX-INVALIDATE-PAIR; FEATURE="TDEFileLevelEncryption"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6616_tde_residuals.zig; OWNER=security; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const gs = @import("graph_storage");

const StorageAdapter = geode.graph_storage_adapter.StorageAdapter;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn randomKey() [32]u8 {
    var k: [32]u8 = undefined;
    io().random(&k);
    return k;
}

fn exists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io(), path, .{}) catch return false;
    return true;
}

test "SONNY-6616: invalidating a graph's exact index removes prop_rev.idx with prop_exact.idx" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(aa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    for ([_]?[32]u8{ null, randomKey() }) |key| {
        const graph = if (key == null) "plain6616" else "sealed6616";
        const adapter = try StorageAdapter.init(testing.allocator, path, .{ .page_size = 4096, .buffer_pool_pages = 64, .encryption_key = key });
        defer adapter.deinit();
        const id = try adapter.createNode(graph, &.{"L6616"});
        try adapter.setNodeProperty(graph, id, "k6616", .{ .String = "v6616" });
        try adapter.checkpointAll();
        const hex = std.fmt.bytesToHex((try adapter.lookupManagedGraph(graph)).uuid, .lower);
        const exact = try std.fmt.allocPrint(aa, "{s}/{s}/prop_exact.idx", .{ path, &hex });
        const rev = try std.fmt.allocPrint(aa, "{s}/{s}/prop_rev.idx", .{ path, &hex });
        try testing.expect(exists(exact));
        try testing.expect(exists(rev));

        // The production caller is the full checkpoint of an emptied,
        // never-built graph; this is the same function.
        adapter.invalidateExactIndexFileForTesting(graph);
        try testing.expect(!exists(exact));
        if (exists(rev)) {
            std.debug.print("SONNY-6616: {s} survived the invalidation of {s}\n", .{ rev, exact });
            return error.ReverseMapLeftBehind;
        }
    }
}
