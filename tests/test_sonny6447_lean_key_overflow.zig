// SONNY-6447 item 3: under lean indexing (GEODE_INDEX_MERGE_KEYS_ONLY=1) only
// registered MERGE keys are indexed. The registry was a fixed array of 64
// keys of at most 128 bytes, and `registerMergeIndexKey` dropped a 65th key
// (or a longer one) silently, while its comment said an overflowing key
// "falls back to indexing the key". It did the opposite: the key was never
// indexed, `lookupMergeCandidate` answered `.not_indexable` for it forever,
// and the server's bulk MERGE fast path refused every MERGE on it
// (MergeValueNotIndexable). The registry now grows, so every MERGE key is
// registered and indexed.
//
// CANARY: REQ=REQ-SONNY-6447-LEAN-KEY-OVERFLOW; FEATURE="LeanMergeKeyIndexing"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6447_lean_key_overflow.zig; OWNER=storage; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;

/// The size of the old fixed registry.
const old_capacity: usize = 64;

fn fillerKey(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "sonny6447_filler_{d:0>3}", .{i}) catch unreachable;
}

test "SONNY-6447: lean mode registers and indexes a MERGE key past the 64th" {
    graph_store.setLeanIndexingForTest(true);
    defer graph_store.setLeanIndexingForTest(false);

    var buf: [64]u8 = undefined;
    for (0..old_capacity) |i| graph_store.registerMergeIndexKey(fillerKey(&buf, i));
    for (0..old_capacity) |i| try testing.expect(graph_store.shouldIndexProperty(fillerKey(&buf, i)));

    // The boundary: the 65th and 66th keys.
    graph_store.registerMergeIndexKey("sonny6447_key_65");
    graph_store.registerMergeIndexKey("sonny6447_key_66");
    try testing.expect(graph_store.shouldIndexProperty("sonny6447_key_65"));
    try testing.expect(graph_store.shouldIndexProperty("sonny6447_key_66"));
    // Still only registered keys.
    try testing.expect(!graph_store.shouldIndexProperty("sonny6447_never_registered"));
}

test "SONNY-6447: lean mode registers a MERGE key longer than 128 bytes" {
    graph_store.setLeanIndexingForTest(true);
    defer graph_store.setLeanIndexingForTest(false);

    const long_key = "k" ** 200;
    graph_store.registerMergeIndexKey(long_key);
    try testing.expect(graph_store.shouldIndexProperty(long_key));
}

test "SONNY-6447: a MERGE on the 65th lean key is answered by the index" {
    graph_store.setLeanIndexingForTest(true);
    defer graph_store.setLeanIndexingForTest(false);

    var buf: [64]u8 = undefined;
    for (0..old_capacity) |i| graph_store.registerMergeIndexKey(fillerKey(&buf, i));

    var gs = try graph_store.GraphStore.init(testing.allocator);
    defer gs.deinit();
    try gs.createGraph("g6447");

    // As a MERGE does: register its key, then write the node.
    graph_store.registerMergeIndexKey("sonny6447_merge_key");
    try gs.createNodeWithReservedIdAndGraph(11, &[_][]const u8{"L6447"}, "g6447");
    try gs.setNodeProperty(11, "sonny6447_merge_key", .{ .Int = 7 });

    var id: u64 = 0;
    try testing.expectEqual(graph_store.GraphStore.MergeLookupResult.found, gs.lookupMergeCandidate("g6447", "L6447", "sonny6447_merge_key", .{ .Int = 7 }, &id));
    try testing.expectEqual(@as(u64, 11), id);
    try testing.expectEqual(graph_store.GraphStore.MergeLookupResult.not_found, gs.lookupMergeCandidate("g6447", "L6447", "sonny6447_merge_key", .{ .Int = 8 }, &id));
}
